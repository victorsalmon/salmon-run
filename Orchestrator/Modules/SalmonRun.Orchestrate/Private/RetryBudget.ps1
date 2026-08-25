<#
.SYNOPSIS
    File retry budget — prevents infinite cycling of failed files.
#>

$script:FileRetryBudgetPath = $null
$script:MaxFileRetries = 3

function Get-FileRetryBudgetPath {
    if (-not $script:FileRetryBudgetPath) {
        $d = $script:RepoRoot
        $script:FileRetryBudgetPath = Join-Path $d "Tasks" "Logs" "file-retry-budget.json"
    }
    return $script:FileRetryBudgetPath
}

function Get-FileRetryBudget {
    $path = Get-FileRetryBudgetPath
    if (-not (Test-Path $path)) { return @{} }
    try { return (Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch {
        Write-OrchestratorLog "RETRY_BUDGET_CORRUPT path='$path' - resetting to empty" -Level WARN
        $backup = "$path.corrupt.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        try { Copy-Item $path $backup -Force } catch { Write-OrchestratorLog "RETRY_BUDGET_BACKUP_FAILED path='$path' error='$($_.Exception.Message)'" -Level WARN }
        try { @{} | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8 -NoNewline -Force } catch { Write-OrchestratorLog "RETRY_BUDGET_RESET_FAILED path='$path' error='$($_.Exception.Message)'" -Level WARN }
        return @{}
    }
}

$script:RetryBudgetLockPath = $null
function Get-RetryBudgetLockPath {
    if (-not $script:RetryBudgetLockPath) {
        $d = $script:RepoRoot
        $script:RetryBudgetLockPath = Join-Path $d "Tasks" "Locks" "file-retry-budget.lock"
    }
    return $script:RetryBudgetLockPath
}

function Get-BackoffDelay {
    param([int]$Attempt, [int]$BaseMs = 100, [int]$CapMs = 30000)
    $delayMs = [math]::Min($CapMs, [math]::Pow(2, $Attempt - 1) * $BaseMs)
    $jitter = Get-Random -Minimum -$($delayMs * 0.25) -Maximum ($delayMs * 0.25)
    return [math]::Max(50, [int]($delayMs + $jitter))
}

function Invoke-AtomicRetryBudgetWrite {
    param([scriptblock]$ScriptBlock)
    $lockPath = Get-RetryBudgetLockPath
    $lockDir = Split-Path $lockPath -Parent
    $null = New-Item -ItemType Directory -Path $lockDir -Force
    # Clean stale lock file (older than 30 seconds — crash residue)
    if (Test-Path $lockPath) {
        try {
            $lockAge = (Get-Date) - (Get-Item $lockPath).CreationTime
            if ($lockAge.TotalSeconds -gt 30) {
                Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "RETRY_BUDGET_LOCK_CLEANED_STALE age=$([math]::Round($lockAge.TotalSeconds))s" -Level WARN
            }
        } catch {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    $deadline = (Get-Date).AddSeconds(15)
    $lockAcquired = $false
    $attempt = 0
    while (-not $lockAcquired -and (Get-Date) -lt $deadline) {
        $attempt++
        try {
            $null = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None).Dispose()
            $lockAcquired = $true
        } catch {
            if ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds (Get-BackoffDelay -Attempt $attempt)
            }
        }
    }
    if (-not $lockAcquired) {
        Write-OrchestratorLog "RETRY_BUDGET_LOCK_TIMEOUT" -Level WARN
        return $null
    }
    try {
        return & $ScriptBlock
    } finally {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-FileRetryCount {
    param([string]$FileName)
    $budget = Get-FileRetryBudget
    if ($budget.PSObject.Properties.Name -contains $FileName) { return $budget.$FileName.retries }
    return 0
}

function Increment-FileRetry {
    param([string]$FileName, [string]$StreamId, [int]$ExitCode)
    $path = Get-FileRetryBudgetPath
    $result = Invoke-AtomicRetryBudgetWrite -ScriptBlock {
        $budget = Get-FileRetryBudget
        if ($budget.PSObject.Properties.Name -contains $FileName) {
            $entry = $budget.$FileName
            $entry | Add-Member -NotePropertyName retries -NotePropertyValue ($entry.retries + 1) -Force
            $entry | Add-Member -NotePropertyName lastAttempt -NotePropertyValue (Get-Date -Format 'o') -Force
            $entry | Add-Member -NotePropertyName lastExitCode -NotePropertyValue $ExitCode -Force
            $entry | Add-Member -NotePropertyName lastStream -NotePropertyValue $StreamId -Force
        } else {
            $budget | Add-Member -NotePropertyName $FileName -NotePropertyValue @{
                retries = 1; firstSeen = (Get-Date -Format 'o'); lastAttempt = (Get-Date -Format 'o')
                lastExitCode = $ExitCode; lastStream = $StreamId
            }
        }
        $budget | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8 -NoNewline
        return $budget.$FileName.retries
    }
    if ($null -eq $result) { return (Get-FileRetryCount -FileName $FileName) }
    return $result
}

function Reset-FileRetry {
    param([string]$FileName)
    $null = Invoke-AtomicRetryBudgetWrite -ScriptBlock {
        $path = Get-FileRetryBudgetPath
        $budget = Get-FileRetryBudget
        if ($budget.PSObject.Properties.Name -contains $FileName) {
            $budget.PSObject.Properties.Remove($FileName)
            $budget | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8 -NoNewline
        }
    }
}

function Test-FileExceededRetryBudget {
    param([string]$FileName)
    $budget = Get-FileRetryBudget
    if ($budget.PSObject.Properties.Name -contains $FileName) {
        return $budget.$FileName.retries -ge $script:MaxFileRetries
    }
    return $false
}

function Invoke-QuarantineFile {
    param([string]$FilePath, [string]$RepoDir, [string]$Reason)
    # Guard 1: do not quarantine a released plan (tempo-quarantine-loop fix).
    # A concurrent sweep may race the releasing agent and call quarantine on a
    # file whose lock header shows Status: released. Skip quarantining in that
    # case — the file is completed work, not failed work. We check for ANY
    # Released: timestamp (not just < 30 min) because completed work should
    # never be quarantined regardless of age.
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $isReleased = ($content -match '(?m)^- Status:\s*released\b' -or $content -match '(?m)^\*\*Status\*\*:\s*released\b' -or $content -match '(?m)^Status:\s*released\b')
            $hasReleasedTimestamp = $content -match '(?m)^- Released:\s*.+'
            $isProgress100 = $content -match '(?m)^- Progress:\s*100%'

            if ($isReleased -or $hasReleasedTimestamp -or $isProgress100) {
                $releasedAgeMin = $null
                $releasedMatch = [regex]::Match($content, '(?m)^- Released:\s*(.+?)[\r\n]', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                if ($releasedMatch.Success) {
                    $releasedTime = $releasedMatch.Groups[1].Value.Trim() -as [datetime]
                    if ($releasedTime) { $releasedAgeMin = [math]::Round(((Get-Date) - $releasedTime).TotalMinutes, 1) }
                }
                Write-OrchestratorLog "QUARANTINE_SKIP_RELEASED file=$(Split-Path $FilePath -Leaf) reason=$Reason released=$isReleased hasTs=$hasReleasedTimestamp progress100=$isProgress100 age_min=$releasedAgeMin" -Level WARN
                return
            }
            # Guard 2: do not quarantine a file already at max retry attempts.
            # If the file already has Attempts: 3 (or >= MaxFileRetries), it has
            # already been quarantined and re-dispatched enough times. Re-quarantining
            # it just creates a loop. Let it stay where it is.
            $attemptsMatch = [regex]::Match($content, '(?m)^\*\*Attempts\*\*:\s*(\d+)')
            if ($attemptsMatch.Success) {
                $attempts = [int]$attemptsMatch.Groups[1].Value
                if ($attempts -ge $script:MaxFileRetries) {
                    Write-OrchestratorLog "QUARANTINE_SKIP_MAX_ATTEMPTS file=$(Split-Path $FilePath -Leaf) reason=$Reason attempts=$attempts max=$($script:MaxFileRetries)" -Level WARN
                    return
                }
            }
        }
    } catch {
        Write-OrchestratorLog "QUARANTINE_GUARD_CHECK_FAILED file=$(Split-Path $FilePath -Leaf) error='$($_.Exception.Message)'" -Level WARN
    }
    $quarantineDir = Join-Path $RepoDir "Tasks" "Failed"
    $null = New-Item -ItemType Directory -Path $quarantineDir -Force
    $dest = Join-Path $quarantineDir (Split-Path $FilePath -Leaf)
    Move-Item -LiteralPath $FilePath -Destination $dest -Force -ErrorAction SilentlyContinue
    Write-OrchestratorLog "FILE_QUARANTINED file=$(Split-Path $FilePath -Leaf) reason=$Reason dest=$dest"
}

$script:MaxRetryBudgetAgeHours = 48

function Resolve-Quarantine {
    <#
    .SYNOPSIS
        Scans Tasks/Failed/ for .quarantine files older than 1 hour.
        Re-evaluates: if the original file no longer exists in Tasks/Code/,
        moves the quarantined file back to Tasks/Code/ and resets its retry count.
    #>
    param([string]$RepoDir)
    $failedDir = Join-Path $RepoDir "Tasks/Failed"
    if (-not (Test-Path $failedDir)) { return 0 }
    $cutoff = (Get-Date).AddHours(-1)
    $restored = 0
    Get-ChildItem "$failedDir/*.quarantine" -ErrorAction SilentlyContinue | ForEach-Object {
        $quarantineFile = $_.FullName
        if ($_.LastWriteTime -gt $cutoff) { return }
        $originalName = $_.BaseName
        $codePath = Join-Path $RepoDir "Tasks/Code/$originalName"
        if (-not (Test-Path $codePath)) {
            Move-Item -LiteralPath $quarantineFile -Destination $codePath -Force -ErrorAction SilentlyContinue
            Reset-FileRetry -FileName $originalName
            $restored++
            Write-OrchestratorLog "QUARANTINE_RESTORED file=$originalName" -Level INFO
        } else {
            Remove-Item $quarantineFile -Force -ErrorAction SilentlyContinue
            Write-OrchestratorLog "QUARANTINE_REMOVED file=$originalName reason=already-in-code" -Level INFO
        }
    }
    return $restored
}

function Clear-StaleRetryBudgetEntries {
    param([string]$RepoDir, [int]$MaxAgeHours = $script:MaxRetryBudgetAgeHours)
    $path = Get-FileRetryBudgetPath
    if (-not (Test-Path $path)) {
        Write-OrchestratorLog "RETRY_BUDGET_GC_SKIP reason=file-missing"
        return
    }
    $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
    $result = Invoke-AtomicRetryBudgetWrite -ScriptBlock {
        $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { Write-OrchestratorLog "RETRY_BUDGET_GC_SKIP reason=empty-file"; return @{ removed = 0 } }
        $budget = $null
        try { $budget = $raw | ConvertFrom-Json -ErrorAction Stop } catch {
            $backup = "$path.corrupt"
            $raw | Out-File -FilePath $backup -Encoding utf8 -Force
            Write-OrchestratorLog "RETRY_BUDGET_GC_CORRUPT backup='$backup' error='$($_.Exception.Message)'"
            @{} | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8 -NoNewline
            return @{ removed = -1; corrupt = $true }
        }
        $removed = 0
        $toRemove = @()
        foreach ($prop in $budget.PSObject.Properties) {
            $entry = $prop.Value
            $lastAttempt = if ($entry.lastAttempt -as [datetime]) { $entry.lastAttempt -as [datetime] } else { $null }
            if ($lastAttempt -and ($lastAttempt -lt $cutoff)) { $toRemove += $prop.Name }
        }
        foreach ($name in $toRemove) {
            $budget.PSObject.Properties.Remove($name)
            $removed++
        }
        if ($removed -gt 0) {
            $budget | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8 -NoNewline
        }
        return @{ removed = $removed }
    }
    $count = if ($result -and $result.removed) { $result.removed } else { 0 }
    $corrupt = $result -and $result.corrupt
    if ($count -gt 0 -or $corrupt) {
        Write-OrchestratorLog "RETRY_BUDGET_GC_COMPLETE removed=$count corrupt=$corrupt maxAgeHours=$MaxAgeHours"
    }
}

function Get-StreamCrashClassification {
    param([string]$StreamId, [string]$RepoDir, [int]$ExitCode)
    $result = @{ class = 'unknown'; transient = $false; canRetry = $false }
    $stderrPath = Join-Path $RepoDir "Tasks/Logs/agents/$($StreamId).stderr"
    $stdoutPath = Join-Path $RepoDir "Tasks/Logs/agents/$($StreamId).stdout"
    $tail = ''
    if (Test-Path $stderrPath) { $tail += (Get-Content $stderrPath -Tail 20 -ErrorAction SilentlyContinue | Out-String) }
    if (Test-Path $stdoutPath) { $tail += (Get-Content $stdoutPath -Tail 20 -ErrorAction SilentlyContinue | Out-String) }

    $lowerTail = $tail.ToLower()
    if ($lowerTail -match 'rate limit|quota exceeded|usage limit|insufficient quota|429') {
        $result.class = 'rate-limit'
        $result.transient = $true
        $result.canRetry = $true
    } elseif ($lowerTail -match 'model.*unavailable|no such model|not supported|provider.*unavailable|ai_apicallerror') {
        $result.class = 'model-error'
        $result.transient = $true
        $result.canRetry = $true
    } elseif ($lowerTail -match 'user rejected permission|permission requested|auto-rejecting') {
        $result.class = 'permission-denied'
        $result.transient = $false
        $result.canRetry = $false
    } elseif ($tail -match 'dep unresolved|connascence_block|upstream dep not resolved|missing dependency|dependson.*not found|missing.*schema') {
        $result.class = 'missing-dependency'
        $result.transient = $false
        $result.canRetry = $false
    } elseif ($ExitCode -eq -1073741819 -or $lowerTail -match 'access violation|segfault|stack overflow') {
        $result.class = 'subagent-crash'
        $result.transient = $false
        $result.canRetry = $false
    } else {
        $result.class = 'general-failure'
        $result.transient = $false
        $result.canRetry = $true
    }
    return $result
}
