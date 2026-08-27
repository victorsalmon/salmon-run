# ─── Structured error collector ──────────────────────────────────────────
$script:iterationErrors = @()

function Write-OrchestratorError {
    param(
        [string]$Op,
        [string]$Message,
        [string]$Stack = "",
        [int]$Iteration = -1
    )
    $entry = @{
        op        = $Op
        message   = $Message
        stack     = $Stack
        iteration = $Iteration
        timestamp = (Get-Date -Format 'o')
    }
    $script:iterationErrors += $entry
    Write-OrchestratorLog "ERROR_COLLECTED op=$Op iteration=$Iteration message='$($Message -replace "'","''")'" -Level WARN
}

function Write-IterationErrorSummary {
    if ($script:iterationErrors.Count -eq 0) { return }
    $summary = $script:iterationErrors | ConvertTo-Json -Compress -Depth 5
    Write-OrchestratorLog "ITERATION_ERROR_SUMMARY errors=$summary" -Level ERROR
    $script:iterationErrors = @()
}

# ─── Exit code constants (with fallback defaults for independent sourcing) ─
if (-not $script:ExitCodeFileLocked) { $script:ExitCodeFileLocked = 10 }
if (-not $script:ExitCodeNoWork) { $script:ExitCodeNoWork = 11 }
if (-not $script:ExitCodeGitLock) { $script:ExitCodeGitLock = 12 }
if (-not $script:ExitCodePushFailed) { $script:ExitCodePushFailed = 13 }

# ─── File retry budget — prevents infinite cycling of failed files ────────
$script:FileRetryBudgetPath = $null
$script:MaxFileRetries = 3

function Get-FileRetryBudgetPath {
    if (-not $script:FileRetryBudgetPath) {
        $d = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:FileRetryBudgetPath = Join-Path $d "Tasks" "Logs" "file-retry-budget.json"
    }
    return $script:FileRetryBudgetPath
}

function Get-FileRetryBudget {
    $path = Get-FileRetryBudgetPath
    if (-not (Test-Path $path)) { return @{} }
    try { return (Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return @{} }
}

$script:RetryBudgetLockPath = $null
function Get-RetryBudgetLockPath {
    if (-not $script:RetryBudgetLockPath) {
        $d = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:RetryBudgetLockPath = Join-Path $d "Tasks" "Locks" "file-retry-budget.lock"
    }
    return $script:RetryBudgetLockPath
}

function Invoke-AtomicRetryBudgetWrite {
    param([scriptblock]$ScriptBlock)
    $lockPath = Get-RetryBudgetLockPath
    $lockDir = Split-Path $lockPath -Parent
    $null = New-Item -ItemType Directory -Path $lockDir -Force
    $deadline = (Get-Date).AddSeconds(15)
    $lockAcquired = $false
    while (-not $lockAcquired -and (Get-Date) -lt $deadline) {
        try {
            $null = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None).Dispose()
            $lockAcquired = $true
        } catch {
            Start-Sleep -Milliseconds 200
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
            $budget.$FileName.retries++
            $budget.$FileName.lastAttempt = (Get-Date -Format 'o')
            $budget.$FileName.lastExitCode = $ExitCode
            $budget.$FileName.lastStream = $StreamId
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
    param([string]$FilePath, [string]$InterclawDir, [string]$Reason)
    $quarantineDir = Join-Path $InterclawDir "Tasks" "Failed"
    $null = New-Item -ItemType Directory -Path $quarantineDir -Force
    $dest = Join-Path $quarantineDir (Split-Path $FilePath -Leaf)
    Move-Item -LiteralPath $FilePath -Destination $dest -Force -ErrorAction SilentlyContinue
    Write-OrchestratorLog "FILE_QUARANTINED file=$(Split-Path $FilePath -Leaf) reason=$Reason dest=$dest"
}

$script:MaxRetryBudgetAgeHours = 48

function Clear-StaleRetryBudgetEntries {
    param([string]$InterclawDir, [int]$MaxAgeHours = $script:MaxRetryBudgetAgeHours)
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

# ─── Exit code handler functions ──────────────────────────────────────────

function Handle-ExitCode10 {
    param($ProcId, $Iteration, $Namespace = "unknown")
    Write-Host "  ⚠ $ProcId file-locked (exit $script:ExitCodeFileLocked) — will retry" -ForegroundColor Yellow
    Write-OrchestratorLog "SUBPROCESS_COLLISION pid=$ProcId iteration=$Iteration type=file_locked"
}

function Handle-ExitCode11 {
    param($ProcId, $Iteration, $Namespace = "unknown")
    Write-Host "  ⚠ $ProcId no-work (exit $script:ExitCodeNoWork) — role saturated" -ForegroundColor Yellow
    Write-OrchestratorLog "SUBPROCESS_COLLISION pid=$ProcId iteration=$Iteration type=no_work"
}

function Handle-ExitCode12 {
    param($ProcId, $Iteration, $Namespace = "unknown")
    Write-Host "  ⚠ $ProcId git-lock (exit $script:ExitCodeGitLock) — will retry with backoff" -ForegroundColor Yellow
    Write-OrchestratorLog "SUBPROCESS_COLLISION pid=$ProcId iteration=$Iteration type=git_lock"
}

function Handle-ExitCode13 {
    param($ProcId, $Iteration, $Namespace = "unknown")
    Write-Host "  ⚠ $ProcId push-failed (exit $script:ExitCodePushFailed) — will retry on next iteration" -ForegroundColor Yellow
    Write-OrchestratorLog "SUBPROCESS_COLLISION pid=$ProcId iteration=$Iteration type=push_failed"
}

function Handle-ExitCode0 {
    param($ProcId, $AgentId, $InterclawDir)
    Write-Host "  ✓ $ProcId completed (exit code 0)" -ForegroundColor Green
    try {
        $validation = Test-AgentCompletion -AgentId $agentId -OrchestratorDir $InterclawDir
        if (-not $validation.Commit) {
            Write-Host "    ⚠ No COMMIT_CREATED marker in $agentId log — possible incomplete commit" -ForegroundColor Yellow
            Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=COMMIT_CREATED"
        }
        if (-not $validation.Push) {
            Write-Host "    ⚠ No PUSH_RESULT marker in $agentId log — possible incomplete push" -ForegroundColor Yellow
            Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=PUSH_RESULT"
        }
        if (-not $validation.Tests) {
            Write-Host "    ⚠ No TEST_RESULT marker in $agentId log — tests may have been skipped" -ForegroundColor Yellow
            Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=TEST_RESULT"
        }
    } catch {
        Write-OrchestratorLog "VALIDATION_ERROR pid=$ProcId error=$($_.Exception.Message)" -Level WARN
    }
}

function Handle-ExitCodeDefault {
    param($ProcId, $ExitCode, $PidToAgent, $RetryCounts, $MaxSubprocessRetries, $InterclawDir, $Namespace = "unknown", $AgentOutcomes)
    Write-Host "  ⚠ $ProcId exited with code $ExitCode — capturing diagnostics" -ForegroundColor Red
    Write-OrchestratorLog "SUBPROCESS_ERROR pid=$ProcId exit_code=$ExitCode" -Level ERROR
    return Invoke-CrashRecovery -ExitCode $ExitCode -PidToAgent $PidToAgent -ProcId $ProcId -RetryCounts $RetryCounts -MaxSubprocessRetries $MaxSubprocessRetries -InterclawDir $InterclawDir -AgentOutcomes $AgentOutcomes
}

$script:LabelMap = @{
    0                                  = "completed"
    $script:ExitCodeFileLocked         = "collision-file-locked"
    $script:ExitCodeNoWork             = "collision-no-work"
    $script:ExitCodeGitLock            = "collision-git-lock"
    $script:ExitCodePushFailed         = "collision-push-failed"
}

function Get-OutcomeLabel {
    param([int]$ExitCode)
    if ($script:LabelMap.ContainsKey($ExitCode)) { return $script:LabelMap[$ExitCode] }
    return "crashed"
}

function Invoke-HandleExitCode {
    param(
        [int]$ExitCode,
        [int]$ProcId,
        [hashtable]$PidToAgent,
        [hashtable]$RetryCounts,
        [int]$MaxSubprocessRetries,
        [string]$InterclawDir,
        [int]$Iteration,
        [object]$Slot,
        [int]$DurationSeconds,
        [hashtable]$AgentOutcomes
    )
    $agentId = if ($PidToAgent -and $PidToAgent.ContainsKey($ProcId)) { $PidToAgent[$ProcId] } else { "unknown" }
    $fileName = if ($Slot) { $Slot.File } else { "?" }
    $roleLabel = if ($Slot) { $Slot.Role } else { "?" }
    $durationStr = if ($DurationSeconds -ge 0) { "${DurationSeconds}s" } else { "?" }
    $namespace = if ($Slot -and $Slot.File) { ($Slot.File -replace '^\d{4}\.\d{2}\.\d{2}-([^-]+(?:-[^-]+)*?)-\d+.*', '$1') } else { "unknown" }

    $statusIcon = switch ($ExitCode) {
        $script:ExitCodeFileLocked { "🔒" }
        $script:ExitCodeNoWork     { "⏭" }
        $script:ExitCodeGitLock    { "🔧" }
        $script:ExitCodePushFailed { "📤" }
        0                           { "✓" }
        default                    { "✗" }
    }

    $statusLabel = switch ($ExitCode) {
        $script:ExitCodeFileLocked { "file-locked" }
        $script:ExitCodeNoWork     { "no-work" }
        $script:ExitCodeGitLock    { "git-lock" }
        $script:ExitCodePushFailed { "push-failed" }
        0                           { "completed" }
        default                    { "crashed" }
    }

    # Single-line per-agent outcome: agent, file, duration, result
    $color = if ($ExitCode -eq 0) { "Green" } elseif ($ExitCode -in @($script:ExitCodeFileLocked,$script:ExitCodeNoWork,$script:ExitCodeGitLock,$script:ExitCodePushFailed)) { "Yellow" } else { "Red" }
    Write-Host "  $statusIcon $agentId  $fileName  (${durationStr})  — $statusLabel" -ForegroundColor $color

    switch ($ExitCode) {
        $script:ExitCodeFileLocked {
            Write-OrchestratorLog "SUBPROCESS_COLLISION agent=$agentId file=$fileName pid=$ProcId iteration=$Iteration type=file_locked duration=$DurationSeconds"
        }
        $script:ExitCodeNoWork {
            Write-OrchestratorLog "SUBPROCESS_COLLISION agent=$agentId file=$fileName pid=$ProcId iteration=$Iteration type=no_work duration=$DurationSeconds"
        }
        $script:ExitCodeGitLock {
            Write-OrchestratorLog "SUBPROCESS_COLLISION agent=$agentId file=$fileName pid=$ProcId iteration=$Iteration type=git_lock duration=$DurationSeconds"
        }
        $script:ExitCodePushFailed {
            Write-OrchestratorLog "SUBPROCESS_COLLISION agent=$agentId file=$fileName pid=$ProcId iteration=$Iteration type=push_failed duration=$DurationSeconds"
        }
        0 {
            Write-OrchestratorLog "SUBPROCESS_COMPLETED agent=$agentId file=$fileName role=$roleLabel pid=$ProcId duration=${DurationSeconds}s exit=$ExitCode"
            try {
                $validation = Test-AgentCompletion -AgentId $agentId -OrchestratorDir $InterclawDir
                if (-not $validation.Commit) {
                    Write-Host "      ⚠ No COMMIT_CREATED marker in $agentId log — possible incomplete commit" -ForegroundColor Yellow
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=COMMIT_CREATED"
                }
                if (-not $validation.Push) {
                    Write-Host "      ⚠ No PUSH_RESULT marker in $agentId log — possible incomplete push" -ForegroundColor Yellow
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=PUSH_RESULT"
                }
                if (-not $validation.Tests) {
                    Write-Host "      ⚠ No TEST_RESULT marker in $agentId log — tests may have been skipped" -ForegroundColor Yellow
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=TEST_RESULT"
                }
            } catch {
                Write-OrchestratorLog "VALIDATION_ERROR pid=$ProcId error=$($_.Exception.Message)" -Level WARN
            }
        }
        default {
            Write-OrchestratorLog "SUBPROCESS_ERROR agent=$agentId file=$fileName pid=$ProcId exit_code=$ExitCode duration=$DurationSeconds" -Level ERROR
            $RetryCounts = Invoke-CrashRecovery -ExitCode $ExitCode -PidToAgent $PidToAgent -ProcId $ProcId -RetryCounts $RetryCounts -MaxSubprocessRetries $MaxSubprocessRetries -InterclawDir $InterclawDir -AgentOutcomes $AgentOutcomes
        }
    }
}

function Invoke-ProcessOutcomes {
    param(
        [System.Collections.Generic.List[System.Diagnostics.Process]]$Processes,
        [array]$SlotAssignments,
        [hashtable]$PidToAgent,
        [hashtable]$ProcStartTimes,
        [hashtable]$ProcToSlot,
        [hashtable]$RetryCounts,
        [int]$MaxSubprocessRetries,
        [string]$InterclawDir,
        [int]$Iteration,
        [hashtable]$AgentOutcomes
    )
    $fileLockedCount = 0
    $noWorkCount     = 0
    $gitLockCount    = 0
    $totalProcessed  = 0
    $totalCrashed    = 0

    foreach ($proc in $Processes) {
        $exitCode = -1
        try { $exitCode = $proc.ExitCode } catch { $exitCode = -1 }

        $outcomeLabel = Get-OutcomeLabel -ExitCode $exitCode

        # Compute wall-clock duration from spawn to exit
        $durationSeconds = -1
        if ($ProcStartTimes -and $ProcStartTimes.ContainsKey($proc.Id)) {
            $durationSeconds = [math]::Round(((Get-Date) - $ProcStartTimes[$proc.Id]).TotalSeconds, 0)
        }

        $slot = $null
        if ($ProcToSlot -and $ProcToSlot.ContainsKey($proc.Id)) {
            $slot = $ProcToSlot[$proc.Id]
        }
        if (-not $slot -and $SlotAssignments -and $exitCode -ge 0) {
            $slot = $SlotAssignments | Where-Object { $_.AgentId -eq $PidToAgent[$proc.Id] } | Select-Object -First 1
        }

        if ($slot) {
            $AgentOutcomes[$slot.AgentId] = @{
                File            = $slot.File
                Role            = $slot.Role
                Exit            = $exitCode
                Status          = $outcomeLabel
                DurationSeconds = $durationSeconds
            }
        }

        $RetryCounts = Invoke-HandleExitCode -ExitCode $exitCode -ProcId $proc.Id -PidToAgent $PidToAgent -RetryCounts $RetryCounts -MaxSubprocessRetries $MaxSubprocessRetries -InterclawDir $InterclawDir -Iteration $Iteration -Slot $slot -DurationSeconds $durationSeconds -AgentOutcomes $AgentOutcomes

        switch ($exitCode) {
            $script:ExitCodeFileLocked { $fileLockedCount++ }
            $script:ExitCodeNoWork     { $noWorkCount++ }
            $script:ExitCodeGitLock    { $gitLockCount++ }
            0                           { $totalProcessed++ }
            default                    { $totalCrashed++ }
        }
    }

    return @{
        FileLockedCount = $fileLockedCount
        NoWorkCount     = $noWorkCount
        GitLockCount    = $gitLockCount
        TotalProcessed  = $totalProcessed
        TotalCrashed    = $totalCrashed
        AgentOutcomes   = $AgentOutcomes
        RetryCounts     = $RetryCounts
    }
}

function Invoke-CrashRecovery {
    param(
        [int]$ExitCode,
        [hashtable]$PidToAgent,
        [int]$ProcId,
        [hashtable]$RetryCounts,
        [int]$MaxSubprocessRetries,
        [string]$InterclawDir
    )
    $crashDir = Join-Path $InterclawDir "Tasks/Failed/$($PidToAgent[$ProcId])-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $null = New-Item -ItemType Directory -Path $crashDir -Force
    $agentDir = Join-Path $InterclawDir "Tasks/Logs/agents"
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).stdout") $crashDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).stderr") $crashDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).log") $crashDir -ErrorAction SilentlyContinue
    Write-OrchestratorLog "CRASH_DIAGNOSTICS agent=$($PidToAgent[$ProcId]) exit=$ExitCode dir=$crashDir" -Level ERROR

    $retryCount = if ($RetryCounts.ContainsKey($PidToAgent[$ProcId])) { $RetryCounts[$PidToAgent[$ProcId]] } else { 0 }
    $retryCount++
    $RetryCounts[$PidToAgent[$ProcId]] = $retryCount

    if ($retryCount -le $MaxSubprocessRetries) {
        Write-Host "  ⚠ $($PidToAgent[$ProcId]) crashed (exit $ExitCode) — retry $retryCount/$MaxSubprocessRetries" -ForegroundColor Yellow
        Write-OrchestratorLog "SUBPROCESS_RETRY agent=$($PidToAgent[$ProcId]) attempt=$retryCount exit=$ExitCode"
        Start-Sleep -Seconds (2 * $retryCount)
    } else {
        Write-Host "  ⚠ $($PidToAgent[$ProcId]) failed after $MaxSubprocessRetries retries — rescuing" -ForegroundColor Red
        Write-OrchestratorLog "SUBPROCESS_FAILED agent=$($PidToAgent[$ProcId]) exit=$ExitCode" -Level ERROR
        $workingFile = Get-ChildItem "$InterclawDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
            Where-Object { ($_gc = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -and ($_gc -match 'Agent: (\w+-\d+-\d+)') -and $Matches[1] -eq $PidToAgent[$ProcId] } |
            Select-Object -First 1
        if ($workingFile) { Handle-OrphanStatus -File $workingFile -Agent $PidToAgent[$ProcId] -InterclawDir $InterclawDir }
    }
    return $RetryCounts
}

function Write-AgentOutcomeTable {
    param([hashtable]$AgentOutcomes)
    if ($AgentOutcomes.Count -gt 0) {
        Write-Host "`n╔══ Agent Summary ═══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║  Agent                    File               Duration   Result              ║" -ForegroundColor Cyan
        Write-Host "║  ─────────────────────────────────────────────────────────────────────────── ║" -ForegroundColor DarkGray
        foreach ($aid in ($AgentOutcomes.Keys | Sort-Object)) {
            $o = $AgentOutcomes[$aid]
            $durationStr = if ($o.DurationSeconds -ge 0) { "${o.DurationSeconds}s".PadLeft(8) } else { "       -" }
            $statusIcon = switch ($o.Status) {
                "completed"           { "✓ done" }
                "timed-out"           { "⏱ timeout" }
                "crashed"             { "✗ crash" }
                "collision-file-locked" { "🔒 locked" }
                "collision-no-work"   { "⏭ no-work" }
                "collision-git-lock"  { "🔧 gitlock" }
                "collision-push-failed" { "📤 pushfail" }
                default               { "? $($o.Status)" }
            }
            $line = "║  $($aid.PadRight(22)) $($o.File.PadRight(20))  ${durationStr}  $statusIcon" + "                              ".PadRight(84).Substring(0,84) + " ║"
            Write-Host $line -ForegroundColor DarkGray
            Write-OrchestratorLog "AGENT_OUTCOME agent=$aid file=$($o.File) role=$($o.Role) exit=$($o.Exit) status=$($o.Status) duration=$($o.DurationSeconds)"
        }
        Write-Host "╚═══════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    }
}

function Clear-StaleOrchestratorFiles {
    param(
        [string]$InterclawDir,
        [int]$InstanceId,
        [int]$SubprocessTimeoutMinutes
    )
    if (-not $InterclawDir) { return @() }
    $logDir = Join-Path $InterclawDir "Tasks/Logs"
    $archiveDir = Join-Path $InterclawDir "Tasks/Complete/PID"
    $findings = [System.Collections.Generic.List[object]]::new()
    $errorCount = 0

    $logs = Get-ChildItem "$logDir\orchestrator-*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-structured.log' -and $_.Name -notlike '*-fallback.log' }

    foreach ($f in $logs) {
        $pidStr = $f.BaseName -replace 'orchestrator-', ''
        $procPid = 0
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        if (Get-Process -Id $procPid -ErrorAction SilentlyContinue) { continue }

        $logTail = Get-Content $f.FullName -Tail 20 -ErrorAction SilentlyContinue
        $logText = $logTail | Out-String
        $exitKind     = if ($logText -match 'exit_kind=(\w+)') { $Matches[1] } else { 'unknown' }
        $hasExit      = $logText -match 'ORCHESTRATOR_EXIT'
        $hasErrorLine = $logText -match '"level":"(ERROR|WARN)"' -or $logText -match '\bERROR\b|\bCRASH\b|\bFAIL\b'
        $crashLines   = @($logTail | Select-String -Pattern '\bERROR\b|\bCRASH\b|\bFAIL\b|exception\b|Exception\b' -ErrorAction SilentlyContinue)

        $isError = -not $hasExit -or $hasErrorLine
        if ($isError) { $errorCount++ }

        $finding = [PSCustomObject]@{
            PID        = $procPid
            LogFile    = $f.Name
            ExitKind   = $exitKind
            HasExit    = $hasExit
            HasError   = $hasErrorLine
            CrashLines = if ($crashLines.Count -gt 0) { ($crashLines | ForEach-Object { $_.Line.Trim() }) -join ' | ' } else { '' }
            LastWrite  = $f.LastWriteTime
            IsError    = $isError
        }
        $findings.Add($finding)

        $null = New-Item -ItemType Directory -Path $archiveDir -Force
        $archivePath = Join-Path $archiveDir $f.Name
        try { Move-Item -LiteralPath $f.FullName -Destination $archivePath -Force -ErrorAction Stop } catch {
            Write-OrchestratorLog "STALE_ARCHIVE_FAILED file=$($f.Name) error=$($_.Exception.Message)" -Level WARN
        }
    }

    # Clean up all instance-qualified PID files where the process is dead
    Get-ChildItem "$logDir\.orchestrator-*-pid" -ErrorAction SilentlyContinue | ForEach-Object {
        $existingPid = try { (Get-Content $_.FullName -Raw -ErrorAction Stop).Trim() } catch { $null }
        if ($existingPid) {
            if (-not (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Legacy fallback: clean old single-pid file
    $legacyPidLock = Join-Path $logDir ".orchestrator-pid"
    if (Test-Path $legacyPidLock) {
        $existingPid = try { (Get-Content $legacyPidLock -Raw -ErrorAction Stop).Trim() } catch { $null }
        if ($existingPid) {
            if (-not (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
                Remove-Item $legacyPidLock -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $heartbeatFile = Join-Path $logDir ".orchestrator-heartbeat"
    if (Test-Path $heartbeatFile) {
        $content = Get-Content $heartbeatFile -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $lastTime = $content.Trim() -as [datetime]
            if ($lastTime -and (([datetime]::UtcNow) - $lastTime.ToUniversalTime()).TotalMinutes -ge 1) {
                Remove-Item $heartbeatFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Clean stale orchestrator-active signal (left by prior crashed orchestrator)
    $orchActivePath = Join-Path $logDir ".orchestrator-active"
    if (Test-Path $orchActivePath) {
        $ocContent = Get-Content $orchActivePath -Raw -ErrorAction SilentlyContinue
        $ocPid = if ($ocContent) { ($ocContent.Trim() -split "`n")[0].Trim() -as [int] } else { $null }
        if (-not $ocPid -or -not (Get-Process -Id $ocPid -ErrorAction SilentlyContinue)) {
            Remove-Item $orchActivePath -Force -ErrorAction SilentlyContinue
            Write-OrchestratorLog "STALE_ORCHESTRATOR_ACTIVE_CLEANED pid=$ocPid"
        }
    }

    # Clean stale agent-level stop signals (left by prior crashed orchestrators)
    $taskStopFiles = @(
        (Join-Path $InterclawDir "Tasks/stop.code"),
        (Join-Path $InterclawDir "Tasks/stop.review"),
        (Join-Path $InterclawDir "Tasks/stop.audit"),
        (Join-Path $InterclawDir "Tasks/stop")
    )
    foreach ($sf in $taskStopFiles) {
        if (Test-Path $sf) {
            Remove-Item $sf -Force -ErrorAction SilentlyContinue
            Write-OrchestratorLog "STALE_STOP_SIGNAL_CLEANED path=$sf"
        }
    }

    $agentDir = Join-Path $logDir "agents"
    if (Test-Path $agentDir) {
        # Sweep all agent PID files (orchestrator, coder, reviewer) where process is dead
        Get-ChildItem "$agentDir\*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
            $pidStr = $_.BaseName -replace '^orch-|^orchestrator-', ''
            $procPid = 0
            if ([int]::TryParse($pidStr, [ref]$procPid) -and -not (Get-Process -Id $procPid -ErrorAction SilentlyContinue)) {
                $base = $_.BaseName
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $agentDir "$base.heartbeat") -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $agentDir "$base.mode") -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "STALE_AGENT_CLEANUP agent=$base pid=$procPid"
            }
        }
        # Remove old agent artifacts (exit code, stdout, stderr, log) older than 7 days
        $cutoff = (Get-Date).AddDays(-7)
        foreach ($ext in @('.exit', '.stdout', '.stderr', '.log')) {
            Get-ChildItem "$agentDir\*$ext" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        # Remove stale agent data directories (empty or older than 7 days)
        Get-ChildItem "$agentDir\*-data" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -or (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Flat-file Working/ cleanup: move stray .md files not in per-agent subdirectories to Review/
    $workingDir = Join-Path $InterclawDir "Tasks/Working"
    if (Test-Path $workingDir) {
        Get-ChildItem "$workingDir\*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
            $flatFile = $_.FullName
            $reviewDir = Join-Path $InterclawDir "Tasks/Review"
            $null = New-Item -ItemType Directory -Path $reviewDir -Force
            $dest = Join-Path $reviewDir $_.Name
            Write-OrchestratorLog "WORKING_FLAT_RESCUE file=$($_.Name) moving to Review/"
            Move-Item -LiteralPath $flatFile -Destination $dest -Force -ErrorAction SilentlyContinue
        }
    }

    if ($errorCount -gt 0) {
        Write-Host "  🔍 Found $errorCount stale orchestrator(s) with errors — investigating..." -ForegroundColor Yellow
        Write-OrchestratorLog "STALE_INVESTIGATION total=$($findings.Count) errors=$errorCount"

        $investigation = [System.Text.StringBuilder]::new()
        $null = $investigation.AppendLine("Stale orchestrator investigation:")
        $null = $investigation.AppendLine("Found $($findings.Count) stale orchestrator log(s), $errorCount with errors.`n")
        $null = $investigation.AppendLine("Breakdown:")
        foreach ($ef in $findings | Where-Object { $_.IsError }) {
            if (-not $ef.HasExit) {
                $null = $investigation.AppendLine("- PID $($ef.PID): Crashed without ORCHESTRATOR_EXIT marker (last write: $($ef.LastWrite)). Possible: killed, OOM, PowerShell crash.")
            } else {
                $null = $investigation.AppendLine("- PID $($ef.PID): Exited with exit_kind=$($ef.ExitKind), error lines: $($ef.CrashLines)")
            }
        }
        $null = $investigation.AppendLine("`nRoot cause analysis:")
        $crashCount = @($findings | Where-Object { -not $_.HasExit }).Count
        if ($crashCount -gt 0) {
            $null = $investigation.AppendLine("- $crashCount orchestrator(s) crashed without clean exit. Likely causes:")
            $null = $investigation.AppendLine("  1. Process killed (OOM, user, system)")
            $null = $investigation.AppendLine("  2. PowerShell runtime crash during dispatch")
            $null = $investigation.AppendLine("  3. Job Object lifecycle race")
        }

        $allCrashLines = @($findings | Where-Object { $_.CrashLines } | ForEach-Object { $_.CrashLines })
        if ($allCrashLines.Count -gt 1) {
            $grouped = $allCrashLines | Group-Object | Sort-Object Count -Descending
            $null = $investigation.AppendLine("`nRecurring patterns:")
            foreach ($g in $grouped | Select-Object -First 5) {
                $null = $investigation.AppendLine("- '$($g.Name)' appeared $($g.Count) time(s)")
            }
        }

        $investigationText = $investigation.ToString()
        Write-OrchestratorLog "STALE_INVESTIGATION_RESULT result='$($investigationText -replace "'","''")'"

        $reportDir = Join-Path $InterclawDir "Tasks/Complete"
        $null = New-Item -ItemType Directory -Path $reportDir -Force
        $reportName = "stale-orchestrator-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Set-Content -Path (Join-Path $reportDir $reportName) -Value $investigationText -Encoding utf8

        $dateStr = Get-Date -Format "yyyy.MM.dd"
        $planName = "$dateStr-fix-stale-orchestrator-cleanup.md"
        $planDir = Join-Path $InterclawDir "Tasks/Code"
        $planPath = Join-Path $planDir $planName

        # Don't regenerate if already in Code/, Review/, Complete/, or already completed in git
        $existingInCode = Test-Path $planPath
        $existingInReview = Test-Path (Join-Path $InterclawDir "Tasks/Review/$planName")
        $existingInComplete = @(Get-ChildItem "$InterclawDir/Tasks/Complete/**/$planName" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        $completedInGit = git -C $InterclawDir log --oneline --all -- "Tasks/*/$planName" 2>$null | Select-Object -First 1
        if ($existingInCode -or $existingInReview -or $existingInComplete -or $completedInGit) {
            $reason = if ($existingInCode) { 'exists-in-code' } elseif ($existingInReview) { 'exists-in-review' } elseif ($existingInComplete) { 'exists-in-complete' } else { 'already-completed' }
            Write-OrchestratorLog "STALE_PLAN_SKIPPED plan=$planName reason=$reason"
            Write-Host "  ℹ Skipping stale plan generation — $planName already $(if($existingInCode -or $existingInReview){'in queue'}else{'completed'})" -ForegroundColor DarkGray
        } else {
        $null = New-Item -ItemType Directory -Path $planDir -Force
        $planContent = @"
# Session Plan: Fix Stale Orchestrator Cleanup

**Date**: $dateStr
**Status**: ready

## Problem
$($findings.Count) stale orchestrator log(s) found in Tasks/Logs/, $errorCount with errors.

### Investigation Summary
$investigationText

## Tasks

1. **Implement startup stale-cleanup in LocalOrchestrator.ps1**
   - **File**: `<Skills/Orchestration/LocalOrchestrator.ps1>`
   - Add `Clear-StaleOrchestratorFiles` that scans and archives stale logs
   - Clean up stale .pid, .heartbeat, .mode artifacts
   - Investigate crash patterns and log findings

2. **Integrate cleanup into startup flow**
   - **File**: `<Skills/Orchestration/LocalOrchestrator.ps1>`
   - Call after Working/ sweep, before main loop
   - Route error findings to session plan generation

3. **Test cleanup on subsequent runs**
   - Verify stale logs are archived under Tasks/Complete/PID/
   - Confirm no false positives for running orchestrators
   - Validate investigation report + plan generation
"@
        Set-Content -Path $planPath -Value $planContent -Encoding utf8
        Write-Host "  📋 Investigation report: Tasks/Complete/$reportName" -ForegroundColor DarkGray
        Write-Host "  📋 Generated coder session plan: Tasks/Code/$planName" -ForegroundColor Yellow
        Write-OrchestratorLog "STALE_PLAN_CREATED plan=$planName errors=$errorCount"
        }
    } elseif ($findings.Count -gt 0) {
        Write-OrchestratorLog "STALE_CLEANUP archived=$($findings.Count) errors=0"
    }

    return $findings
}


function Get-DynamicCapacity {
    <#
    .SYNOPSIS
        Allocates capacity using a shared pool of $CodeParallelCount total streams,
        with a minimum guarantee for each role to prevent starvation.
        Total concurrent streams never exceed $CodeParallelCount.
    .PARAMETER CodeParallelCount
        Max total stream slots (shared between coders and reviewers).
    .PARAMETER ReviewerParallelCount
        Max reviewer-specific slots (secondary cap).
    .PARAMETER CoderWorkload
        Number of pending coder tasks.
    .PARAMETER ReviewerWorkload
        Number of pending reviewer tasks.
    .PARAMETER ActiveCoder
        Number of currently active coder streams.
    .PARAMETER ActiveReviewer
        Number of currently active reviewer streams.
    #>
    param(
        [int]$CodeParallelCount,
        [int]$ReviewerParallelCount,
        [int]$CoderWorkload,
        [int]$ReviewerWorkload,
        [int]$ActiveCoder = 0,
        [int]$ActiveReviewer = 0
    )

    $minCoderGuarantee = 1
    $minReviewerGuarantee = 1
    $totalActive = $ActiveCoder + $ActiveReviewer
    $availableSlots = [math]::Max(0, $CodeParallelCount - $totalActive)

    if ($CoderWorkload -le 0 -and $ReviewerWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = 0; CapacityReviewer = 0 }
    }

    if ($CoderWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = 0; CapacityReviewer = [math]::Min($availableSlots, $ReviewerParallelCount - $ActiveReviewer) }
    }

    if ($ReviewerWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = $availableSlots; CapacityReviewer = 0 }
    }

    # Both roles have work: fulfill minimum guarantees first
    $needCoder = [math]::Max(0, $minCoderGuarantee - $ActiveCoder)
    $needReviewer = [math]::Max(0, $minReviewerGuarantee - $ActiveReviewer)

    $coderCapacity = [math]::Min($needCoder, $availableSlots)
    $remaining = $availableSlots - $coderCapacity
    $reviewerCapacity = [math]::Min($needReviewer, $remaining)
    $remaining -= $reviewerCapacity

    # Split remaining slots proportionally by workload
    if ($remaining -gt 0) {
        $totalWork = $CoderWorkload + $ReviewerWorkload
        $extraCoder = [math]::Round($remaining * $CoderWorkload / $totalWork)
        $extraCoder = [math]::Max(0, [math]::Min($extraCoder, $remaining))
        $coderCapacity += $extraCoder
        $reviewerCapacity += ($remaining - $extraCoder)
    }

    $reviewerCapacity = [math]::Min($reviewerCapacity, $ReviewerParallelCount - $ActiveReviewer)

    if ($availableSlots -eq 0 -and $totalActive -gt 0) {
        $zombieStreams = 0
        if ($script:activeStreams) {
            foreach ($__ns in $script:activeStreams.Keys) {
                $__s = $script:activeStreams[$__ns]
                if ($__s.Process -and $__s.Process.HasExited) { $zombieStreams++ }
                elseif (-not $__s.Process) { $zombieStreams++ }
            }
        }
        if ($zombieStreams -gt 0) {
            Write-OrchestratorLog "DYNAMIC_CAPACITY_ZOMBIE zombieStreams=$zombieStreams availableSlots=$availableSlots forcing_one"
            $availableSlots = [math]::Min(1, $zombieStreams)
        }
    }

    return [PSCustomObject]@{
        CapacityCoder    = [math]::Max(0, $coderCapacity)
        CapacityReviewer = [math]::Max(0, $reviewerCapacity)
    }
}

function Get-ActiveStreamsCount {
    <#
    .SYNOPSIS
        Returns the count of currently active streams.
    .PARAMETER ActiveStreams
        The script:activeStreams hashtable.
    #>
    param([hashtable]$ActiveStreams)
    return @($ActiveStreams.Keys).Count
}

function Get-QueuedNamespacesCount {
    <#
    .SYNOPSIS
        Returns the count of files not yet assigned to any stream.
    .PARAMETER CodeDir
        Path to Tasks/Code/.
    .PARAMETER ReviewDir
        Path to Tasks/Review/.
    .PARAMETER UsedNamespaces
        The script:usedNamespaces hashtable tracking already-assigned files.
    #>
    param([string]$CodeDir, [string]$ReviewDir, [hashtable]$UsedNamespaces)
    $all = @(Get-ChildItem "$CodeDir/*.md" -ErrorAction SilentlyContinue) +
           @(Get-ChildItem "$ReviewDir/*.md" -ErrorAction SilentlyContinue)
    $unused = $all | Where-Object { -not $UsedNamespaces.ContainsKey($_.Name) }
    return $unused.Count
}

function Prepend-StreamLog {
    <#
    .SYNOPSIS
        DEPRECATED — Prepends a log entry to stream.log
    .DESCRIPTION
        Agents no longer write stream.log. The Lock Header on the session plan
        file is the canonical per-file log. This function is retained for
        backward compatibility with orphaned stream directories from prior
        orchestrator runs. New code should not call this.
    #>
    param([string]$StreamDir, [string]$Entry)
    $log = Join-Path $StreamDir "stream.log"
    $existing = if (Test-Path $log) { Get-Content $log -Raw -ErrorAction SilentlyContinue } else { "" }
    "$Entry`n$existing" | Set-Content $log -Encoding utf8 -NoNewline
}

# ─── Main loop helper functions ───────────────────────────────────────────

function Test-IsFatalError {
    param(
        $Counts,
        $CgResult,
        [string]$StreamDir,
        [hashtable]$ActiveStreams,
        [string]$PidLockFile
    )
    if (-not $Counts) { return $true }
    if (-not $cgResult) { return $true }
    if ($PidLockFile -and -not (Test-Path $PidLockFile)) { return $true }
    if ($StreamDir) {
        $streamJson = Join-Path $StreamDir "stream.json"
        if (Test-Path $streamJson) {
            $hasMdFiles = (Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue).Count -gt 0
            $hasComplete = Test-Path (Join-Path $StreamDir ".complete")
            if (-not $hasMdFiles -and -not $hasComplete) { return $true }
        }
    }
    return $false
}

function Test-StreamAgentAlive {
    <#
    .SYNOPSIS
        Returns $true when the stream/lane agent's heartbeat is fresh (< 5 min old).
    .DESCRIPTION
        A fresh heartbeat means the stream agent process is alive and mid-work.
        The reconciliation paths MUST NOT treat such a stream as completed or
        empty, and MUST NOT move its files out from under it. The heartbeat file
        content (UTC ISO timestamp, as written by agents) is authoritative; the
        file's LastWriteTime is a fallback when the content cannot be parsed.
    #>
    param([string]$StreamId, [string]$InterclawDir)
    if ([string]::IsNullOrWhiteSpace($StreamId)) { return $false }
    $hb = Join-Path $InterclawDir "Tasks/Logs/agents/$StreamId.heartbeat"
    if (-not (Test-Path $hb)) { return $false }
    try {
        $hbTime = $null
        $hbContent = (Get-Content $hb -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($hbContent)) {
            try {
                $hbTime = [datetime]::Parse($hbContent, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } catch { $hbTime = $null }
        }
        if ($null -eq $hbTime) { $hbTime = (Get-Item $hb).LastWriteTime.ToUniversalTime() }
        $ageMinutes = ([datetime]::UtcNow - $hbTime).TotalMinutes
        return $ageMinutes -lt 5
    } catch {
        return $false
    }
}

function Invoke-ReadFilesystemState {
    param([string]$InterclawDir)
    $workingDir = Join-Path $InterclawDir "Tasks/Working"
    # Scan both stream-* and lane-* directories — persistent lanes can also
    # hold in-progress or completed streams that need reconciliation.
    $streamDirs = @(Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue) +
                  @(Get-ChildItem "$workingDir/lane-*" -Directory -ErrorAction SilentlyContinue)
    $recovered = @{ activeStreams = @{}; busyNamespaces = @{}; orphanStreams = @{} }
    foreach ($sd in $streamDirs) {
        $streamJson = Join-Path $sd.FullName "stream.json"
        if (-not (Test-Path $streamJson)) {
            $hasFiles = (Get-ChildItem "$($sd.FullName)/*" -File -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $hasFiles) {
                Remove-Item -LiteralPath $sd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) removed_empty_zombie_dir"
                continue
            }
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) missing_stream_json" -Level WARN
            continue
        }
        try {
            $meta = Get-Content $streamJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) invalid_stream_json" -Level WARN
            continue
        }
        $hasComplete = Test-Path (Join-Path $sd.FullName ".complete")
        $hasPlanFiles = (Get-ChildItem "$($sd.FullName)/*.md" -ErrorAction SilentlyContinue).Count -gt 0
        $nsKey = "$($meta.Namespace)|$($meta.Role)"
        if ($hasComplete -or -not $hasPlanFiles) {
            # Liveness guard: a stream whose agent heartbeat is fresh is mid-work —
            # a concurrent move or an early .complete write is NOT a completion signal.
            $agentAlive = Test-StreamAgentAlive -StreamId $meta.Id -InterclawDir $InterclawDir
            if ($agentAlive) {
                Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) ns=$nsKey skipped_live_agent complete=$hasComplete planFiles=$hasPlanFiles"
                continue
            }
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) ns=$nsKey completed_or_empty complete=$hasComplete planFiles=$hasPlanFiles"
            continue
        }
        $recovered.activeStreams[$nsKey] = @{
            Id        = $meta.Id
            Path      = $sd.FullName
            Namespace = $meta.Namespace
            Role      = $meta.Role
            Created   = $meta.Created
        }
    }
    if ($recovered.activeStreams.Count -gt 0) {
        Write-OrchestratorLog "FILESYSTEM_STATE recovered=$($recovered.activeStreams.Count) streams"
    }
    return $recovered
}

function Invoke-ReconcileState {
    param(
        [string]$InterclawDir,
        [hashtable]$ActiveStreams,
        [hashtable]$BusyNamespaces,
        [hashtable]$UsedNamespaces
    )
    $discrepancies = [System.Collections.Generic.List[string]]::new()
    $workingDir = Join-Path $InterclawDir "Tasks/Working"
    # Scan both stream-* and lane-* directories for reconciliation
    $streamDirs = @(Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue) +
                  @(Get-ChildItem "$workingDir/lane-*" -Directory -ErrorAction SilentlyContinue)
    $fsStreams = @{}
    foreach ($sd in $streamDirs) {
        $streamJson = Join-Path $sd.FullName "stream.json"
        if (Test-Path $streamJson) {
            try {
                $meta = Get-Content $streamJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $nsKey = "$($meta.Namespace)|$($meta.Role)"
                $fsStreams[$nsKey] = @{ Path = $sd.FullName; Namespace = $meta.Namespace; Role = $meta.Role }
            } catch {}
        }
    }
    foreach ($ns in $ActiveStreams.Keys) {
        if (-not $fsStreams.ContainsKey($ns)) {
            $discrepancies.Add("stream '$ns' tracked in memory but stream.json missing on disk")
        }
    }
    foreach ($ns in $fsStreams.Keys) {
        if (-not $ActiveStreams.ContainsKey($ns)) {
            $discrepancies.Add("stream '$ns' has stream.json on disk but not tracked in memory")
        }
    }
    $reviewFiles = Get-ChildItem "$InterclawDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue
    foreach ($rf in $reviewFiles) {
        if ($UsedNamespaces -and $UsedNamespaces.ContainsKey($rf.Name)) {
            $discrepancies.Add("file '$($rf.Name)' in Review/ still in usedNamespaces")
        }
    }
    if ($discrepancies.Count -gt 0) {
        foreach ($d in $discrepancies) {
            Write-OrchestratorLog "STATE_DISCREPANCY detail='$d'" -Level WARN
        }
    }
    return $discrepancies
}

function Clear-IterationEnvironment {
    param([int]$Iteration)
    Write-OrchestratorLog "ENV_CLEAN iteration=$Iteration clearing stale variables"
    @('OC_RESERVATION_FILE', 'OC_RESERVATION_ROLE', 'OC_RESERVATION_AGENT_ID') | ForEach-Object {
        Remove-Item "Env:$_" -ErrorAction SilentlyContinue
    }
    if ($env:OC_RESERVATION_FILE) {
        Write-OrchestratorLog "ENV_LEAK iteration=$Iteration variable=OC_RESERVATION_FILE value=$env:OC_RESERVATION_FILE" -Level WARN
    }
}

function Invoke-InterIterationStaleSweep {
    param([string]$InterclawDir)
    $staleWorkingFiles = Get-ChildItem "$InterclawDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    foreach ($f in $staleWorkingFiles) {
        $fileAgent = if ((Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }
        if (-not $fileAgent) { continue }
        try {
            $alive = Test-AgentAlive -AgentId $fileAgent
            if ($alive.Stale) {
                Write-Host "  🔍 Stale file detected mid-run: $($f.Name) (agent $fileAgent)" -ForegroundColor Yellow
                Handle-OrphanStatus -File $f -Agent $fileAgent -InterclawDir $InterclawDir -RescueKind "RESCUE_STALE"
                Write-OrchestratorLog "INTER_ITERATION_RESCUE agent=$fileAgent file=$($f.Name)"
            }
        } catch {
            Write-OrchestratorLog "INTER_ITERATION_RESCUE_ERROR agent=$fileAgent file=$($f.Name) error=$($_.Exception.Message)" -Level WARN
        }
    }
}

function Invoke-PeriodicCleanup {
    param([int]$Iteration, [string]$InterclawDir)
    if ($Iteration % 5 -eq 0) {
        try { Clear-StaleRetryBudgetEntries -InterclawDir $InterclawDir } catch { Write-OrchestratorLog "RETRY_BUDGET_GC_PERIODIC_FAILED iteration=$Iteration error='$($_.Exception.Message)'" -Level WARN }
        # Remove empty agent subdirs before PID cleanup loses provenance
        try {
            Get-ChildItem "$InterclawDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -cmatch '^(coder|reviewer)-\d+-\d+|REVIEWER_' } |
                Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
        try { Clear-StaleAgentFiles -RemoveLogs } catch { }
        try {
            Get-ChildItem "$InterclawDir/Tasks/Logs/agents/*.stdout" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem "$InterclawDir/Tasks/Logs/agents/*.stderr" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-IterationStatus {
    param(
        [PSCustomObject]$Counts,
        [int]$Iteration,
        [int]$MaxIterations,
        [int]$TotalProcessed,
        [int]$TotalCrashed,
        [datetime]$SessionStart
    )
    $elapsedSec = [math]::Round(((Get-Date) - $SessionStart).TotalSeconds)

    # One-line queue summary
    $handoffInfo = if ($Counts.Handoff -gt 0) { "  Handoff:$($Counts.Handoff)" } else { "" }
    $blockedInfo = if ($Counts.Blocked -gt 0) { "  Blocked:$($Counts.Blocked)" } else { "" }
    $streamInfo = if ($Counts.ActiveStreams -gt 0) { " Streams:$($Counts.ActiveStreams)" } else { "" }
    Write-Host "`n[Loop $Iteration/$MaxIterations]  Code:$($Counts.RootCoder)  Review:$($Counts.Review)$handoffInfo$blockedInfo  Working:$($Counts.Working)$streamInfo  Elapsed:${elapsedSec}s" -ForegroundColor Cyan

    # Show running streams with their namespace and role
    if ($script:activeStreams -and $script:activeStreams.Count -gt 0) {
        foreach ($ns in $script:activeStreams.Keys) {
            $s = $script:activeStreams[$ns]
            $sElapsed = [math]::Round(((Get-Date) - $s.StartTime).TotalMinutes, 1)
            $statusIcon = if ($s.Status -eq "running") { "▶" } else { "●" }
            Write-Host "  $statusIcon $($s.Id) ($($s.Role)) [$ns] — ${sElapsed}m" -ForegroundColor DarkGray
        }
    }

    if ($Iteration % 5 -eq 0) {
        Write-Host "  📊 Processed: $TotalProcessed | Crashed: $TotalCrashed | Queues: Code $($Counts.CoderWorkload) / Review $($Counts.ReviewerWorkload) / Handoff $($Counts.Handoff) / Working $($Counts.Working) / Blocked $($Counts.Blocked)" -ForegroundColor Cyan
        Write-OrchestratorLog "AUTO_SUMMARY processed=$TotalProcessed crashed=$TotalCrashed coder_rem=$($Counts.CoderWorkload) reviewer_rem=$($Counts.ReviewerWorkload) handoff=$($Counts.Handoff) blocked=$($Counts.Blocked) streams=$($Counts.ActiveStreams) elapsed=${elapsedSec}s"
    }

    Write-OrchestratorLog "QUEUE_STATE iteration=$Iteration coder=$($Counts.RootCoder) locked_coder=$($Counts.LockedCoder) review=$($Counts.Review) locked_reviewer=$($Counts.LockedReviewer) handoff=$($Counts.Handoff) working=$($Counts.Working) streams=$($Counts.ActiveStreams)"
}

function Invoke-StallDetection {
    param(
        [PSCustomObject]$Counts,
        [PSCustomObject]$PreviousCounts,
        [int]$StallCount,
        [int]$MaxStall,
        [int]$Iteration,
        [int]$InstanceId = 1
    )
    if (-not $PreviousCounts) { return @{ Stalled = $false; NewStallCount = 0 } }

    $sameCoder   = $Counts.RootCoder  -eq $PreviousCounts.RootCoder
    $sameReview  = $Counts.Review     -eq $PreviousCounts.Review
    $sameWorking = $Counts.Working    -eq $PreviousCounts.Working

    if ($sameCoder -and $sameReview -and $sameWorking) {
        # Don't count stall if active stream subprocesses are still running
        $aliveStreams = 0
        if ($script:activeStreams) {
            foreach ($ns in $script:activeStreams.Keys) {
                $stream = $script:activeStreams[$ns]
                if ($stream.Process -and -not $stream.Process.HasExited) { $aliveStreams++ }
            }
        }
        if ($aliveStreams -gt 0) {
            Write-OrchestratorLog "STALL_DEFERRED iteration=$Iteration aliveStreams=$aliveStreams stallCount=$StallCount"
            return @{ Stalled = $false; NewStallCount = $StallCount }
        }
        $newStallCount = $StallCount + 1
        Write-Host "  ⚠ No queue progress detected ($newStallCount/$MaxStall)" -ForegroundColor Yellow
        Write-OrchestratorLog "STALL iteration=$Iteration count=$newStallCount max=$MaxStall"
        if ($newStallCount -ge $MaxStall) {
            Write-Host "  ⚠ Stall limit reached — stopping" -ForegroundColor Red
            Write-OrchestratorLog "STALL_LIMIT iteration=$Iteration" -Level ERROR
            Write-OrchestratorLog "STALL_REMEDIATION action=stopping"
            return @{ Stalled = $false; NewStallCount = $newStallCount; StallLimitReached = $true }
        }
        return @{ Stalled = $true; NewStallCount = $newStallCount }
    }
    return @{ Stalled = $false; NewStallCount = 0 }
}

function Test-OpenCodeAvailable {
    $opencodeCmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
    if (-not $opencodeCmd) {
        $opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
    }
    if (-not $opencodeCmd) {
        $opencodeCmd = Get-Command opencode.exe -ErrorAction SilentlyContinue
    }
    if (-not $opencodeCmd) {
        $commonPaths = @(
            "$env:LOCALAPPDATA\opencode\opencode.cmd",
            "$env:LOCALAPPDATA\opencode\opencode.exe",
            "$env:APPDATA\npm\opencode.cmd",
            "$env:APPDATA\npm\opencode",
            "$env:ProgramFiles\nodejs\opencode.cmd",
            "$env:USERPROFILE\.opencode\bin\opencode.cmd",
            "$env:USERPROFILE\.opencode\bin\opencode"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $opencodeCmd = Get-Command $p -ErrorAction SilentlyContinue
                if ($opencodeCmd) { break }
            }
        }
    }
    if (-not $opencodeCmd) {
        Write-Host "  ⚠ opencode not found in PATH — install: npm install -g @opencode-ai/opencode" -ForegroundColor Red
        Write-Host "  Tried: PATH lookup and common install locations (npm, LocalAppData, ProgramFiles, ~/.opencode)" -ForegroundColor DarkGray
        exit 1
    }
    return $opencodeCmd.Source
}

function Invoke-ModelPreflightCheck {
    param([string]$OpenCodePath)
    try {
        $result = & $OpenCodePath eval --timeout 15 "1+1" 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { return $true }
        Write-OrchestratorLog "MODEL_PREFLIGHT_FAILED exit=$exitCode output='$result'" -Level WARN
    } catch {
        Write-OrchestratorLog "MODEL_PREFLIGHT_ERROR error='$($_.Exception.Message)'" -Level WARN
    }
    return $false
}
