<#
.SYNOPSIS
    Exit code handling, crash recovery, orphan rescue, and agent outcome tracking.
#>

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

# ─── Exit code constants ─────────────────────────────────────────────────
if (-not $script:ExitCodeFileLocked) { $script:ExitCodeFileLocked = 10 }
if (-not $script:ExitCodeNoWork) { $script:ExitCodeNoWork = 11 }
if (-not $script:ExitCodeGitLock) { $script:ExitCodeGitLock = 12 }
if (-not $script:ExitCodePushFailed) { $script:ExitCodePushFailed = 13 }
if (-not $script:ExitCodeSkipped) { $script:ExitCodeSkipped = 14 }

# ─── Exit code handler functions ──────────────────────────────────────────
# Per-exit-code handler functions removed; Invoke-HandleExitCode handles outcomes inline.

$script:LabelMap = @{
    0                                  = "completed"
    $script:ExitCodeFileLocked         = "collision-file-locked"
    $script:ExitCodeNoWork             = "collision-no-work"
    $script:ExitCodeGitLock            = "collision-git-lock"
    $script:ExitCodePushFailed         = "collision-push-failed"
    $script:ExitCodeSkipped            = "skipped"
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
        [string]$RepoDir,
        [int]$Iteration,
        [object]$Slot,
        [int]$DurationSeconds,
        [hashtable]$AgentOutcomes
    )
    $agentId = if ($PidToAgent -and $PidToAgent.ContainsKey($ProcId)) { $PidToAgent[$ProcId] } else { "unknown" }
    $fileName = if ($Slot) { $Slot.File } else { "?" }
    $roleLabel = if ($Slot) { $Slot.Role } else { "?" }
    $durationStr = if ($DurationSeconds -ge 0) { "${DurationSeconds}s" } else { "?" }

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
        $script:ExitCodeSkipped    { "skipped" }
        0                           { "completed" }
        default                    { "crashed" }
    }

    # Single-line per-agent outcome: agent, file, duration, result
    Write-Output "  $statusIcon $agentId  $fileName  (${durationStr})  — $statusLabel"

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
            Write-OrchestratorLog "SUBPROCESS_COLLISION agent=$agentId file=$fileName pid=$procId iteration=$Iteration type=push_failed duration=$DurationSeconds"
        }
        $script:ExitCodeSkipped {
            Write-OrchestratorLog "SUBPROCESS_SKIPPED agent=$agentId file=$fileName pid=$procId iteration=$Iteration type=skipped duration=$DurationSeconds"
        }
        0 {
            Write-OrchestratorLog "SUBPROCESS_COMPLETED agent=$agentId file=$fileName role=$roleLabel pid=$ProcId duration=${DurationSeconds}s exit=$ExitCode"
            try {
                $validation = Test-AgentCompletion -AgentId $agentId -OrchestratorDir $RepoDir
                if (-not $validation.Commit) {
                    Write-Output "      ⚠ No COMMIT_CREATED marker in $agentId log — possible incomplete commit"
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=COMMIT_CREATED"
                }
                if (-not $validation.Push) {
                    Write-Output "      ⚠ No PUSH_RESULT marker in $agentId log — possible incomplete push"
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=PUSH_RESULT"
                }
                if (-not $validation.Tests) {
                    Write-Output "      ⚠ No TEST_RESULT marker in $agentId log — tests may have been skipped"
                    Write-OrchestratorLog "VALIDATION_WARN agent=$agentId marker=TEST_RESULT"
                }
            } catch {
                Write-OrchestratorLog "VALIDATION_ERROR pid=$ProcId error=$($_.Exception.Message)" -Level WARN
            }
        }
        default {
            Write-OrchestratorLog "SUBPROCESS_ERROR agent=$agentId file=$fileName pid=$ProcId exit_code=$ExitCode duration=$DurationSeconds" -Level ERROR
            $RetryCounts = Invoke-CrashRecovery -ExitCode $ExitCode -PidToAgent $PidToAgent -ProcId $ProcId -RetryCounts $RetryCounts -MaxSubprocessRetries $MaxSubprocessRetries -RepoDir $RepoDir -AgentOutcomes $AgentOutcomes
        }
    }
}

function Invoke-ProcessOutcome {
    param(
        [System.Collections.Generic.List[System.Diagnostics.Process]]$Processes,
        [array]$SlotAssignments,
        [hashtable]$PidToAgent,
        [hashtable]$ProcStartTimes,
        [hashtable]$ProcToSlot,
        [hashtable]$RetryCounts,
        [int]$MaxSubprocessRetries,
        [string]$RepoDir,
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

        $RetryCounts = Invoke-HandleExitCode -ExitCode $exitCode -ProcId $proc.Id -PidToAgent $PidToAgent -RetryCounts $RetryCounts -MaxSubprocessRetries $MaxSubprocessRetries -RepoDir $RepoDir -Iteration $Iteration -Slot $slot -DurationSeconds $durationSeconds -AgentOutcomes $AgentOutcomes

        switch ($exitCode) {
        $script:ExitCodeFileLocked { $fileLockedCount++ }
        $script:ExitCodeNoWork     { $noWorkCount++ }
        $script:ExitCodeGitLock    { $gitLockCount++ }
        $script:ExitCodeSkipped    { $totalProcessed++ }
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
        [string]$RepoDir
    )
    $crashDir = Join-Path $RepoDir "Tasks/Failed/$($PidToAgent[$ProcId])-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $null = New-Item -ItemType Directory -Path $crashDir -Force
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).stdout") $crashDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).stderr") $crashDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $agentDir "$($PidToAgent[$ProcId]).log") $crashDir -ErrorAction SilentlyContinue
    Write-OrchestratorLog "CRASH_DIAGNOSTICS agent=$($PidToAgent[$ProcId]) exit=$ExitCode dir=$crashDir" -Level ERROR

    $retryCount = if ($RetryCounts.ContainsKey($PidToAgent[$ProcId])) { $RetryCounts[$PidToAgent[$ProcId]] } else { 0 }
    $retryCount++
    $RetryCounts[$PidToAgent[$ProcId]] = $retryCount

    if ($retryCount -le $MaxSubprocessRetries) {
        Write-Output "  ⚠ $($PidToAgent[$ProcId]) crashed (exit $ExitCode) — retry $retryCount/$MaxSubprocessRetries"
        $retryDelay = Get-BackoffDelay -Attempt $retryCount -Schedule @(2, 4, 8, 16) -JitterFraction 0.25
        Write-OrchestratorLog "SUBPROCESS_RETRY agent=$($PidToAgent[$ProcId]) attempt=$retryCount delay=${retryDelay}s exit=$ExitCode"
        Start-Sleep -Seconds $retryDelay
    } else {
        Write-Output "  ⚠ $($PidToAgent[$ProcId]) failed after $MaxSubprocessRetries retries — rescuing"
        Write-OrchestratorLog "SUBPROCESS_FAILED agent=$($PidToAgent[$ProcId]) exit=$ExitCode" -Level ERROR
        $workingFile = Get-ChildItem "$RepoDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
            Where-Object { ($_gc = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -and ($_gc -match 'Agent: (\w+-\d+-\d+)') -and $Matches[1] -eq $PidToAgent[$ProcId] } |
            Select-Object -First 1
        if ($workingFile) { Resolve-OrphanStatus -File $workingFile -Agent $PidToAgent[$ProcId] -RepoDir $RepoDir }
    }
    return $RetryCounts
}

function Write-AgentOutcomeTable {
    param([hashtable]$AgentOutcomes)
    if ($AgentOutcomes.Count -gt 0) {
        Write-Output "`n╔══ Agent Summary ═══════════════════════════════════════════════════════╗"
        Write-Output "║  Agent                    File               Duration   Result              ║"
        Write-Output "║  ─────────────────────────────────────────────────────────────────────────── ║"
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
            Write-Output $line
            Write-OrchestratorLog "AGENT_OUTCOME agent=$aid file=$($o.File) role=$($o.Role) exit=$($o.Exit) status=$($o.Status) duration=$($o.DurationSeconds)"
        }
        Write-Output "╚═══════════════════════════════════════════════════════════════════════════════════════╝"
    }
}

# ─── Orphan rescue helpers (from LocalOrchestrator-Worker.ps1) ────────────

function Get-WorkingSnapshot {
    param([string]$WorkingDir)
    $result = @{}
    foreach ($agentDir in (Get-ChildItem "$WorkingDir\*" -Directory -ErrorAction SilentlyContinue)) {
        $agentId = $agentDir.Name
        foreach ($f in (Get-ChildItem "$($agentDir.FullName)\*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })) {
            $result[$f.Name] = @{ Agent = $agentId }
        }
    }
    return $result
}

function Test-AgentCompletion {
    param([string]$AgentId, [string]$OrchestratorDir)
    $agentDir = Join-Path $OrchestratorDir "Tasks/Logs/agents"
    $logFile    = Join-Path $agentDir "$AgentId.log"
    $stdoutFile = Join-Path $agentDir "$AgentId.stdout"
    $stderrFile = Join-Path $agentDir "$AgentId.stderr"

    $result = @{ Tests = $false; Commit = $false; Push = $false }
    $sources = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $logFile)    { $sources.Add($logFile) }
    if (Test-Path $stdoutFile) { $sources.Add($stdoutFile) }
    if (Test-Path $stderrFile) { $sources.Add($stderrFile) }

    foreach ($src in $sources) {
        $content = Get-Content $src -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'TEST_RESULT')    { $result.Tests  = $true }
        if ($content -match 'COMMIT_CREATED')  { $result.Commit = $true }
        if ($content -match 'PUSH_RESULT')     { $result.Push   = $true }
    }

    return $result
}

function Resolve-OrphanStatus {
    param([System.IO.FileInfo]$File, [string]$Agent, [string]$RepoDir, [string]$RescueKind = "RESCUE")
    $content = Get-Content $File.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return }

    $now = [datetime]::UtcNow.ToString('o')

    # Live-agent guard: never stamp Released: on a file whose worker process is
    # still alive (hard-timeout and stale-sweep rescues must not release a busy
    # agent's lock). Mirrors Handle-OrphanStatus in LocalOrchestrator-Worker.ps1.
    $agentProcessAlive = $false
    if ($Agent) {
        try {
            $aliveInfo = Test-AgentAlive -AgentId $Agent
            if ($aliveInfo) {
                if ($null -ne $aliveInfo.ProcessAlive) { $agentProcessAlive = [bool]$aliveInfo.ProcessAlive }
                elseif ($null -ne $aliveInfo.Alive) { $agentProcessAlive = [bool]$aliveInfo.Alive }
            }
        } catch {
            Write-OrchestratorLog "ORPHAN_AGENT_ALIVE_PROBE_FAILED agent=$Agent error='$($_.Exception.Message)'" -Level WARN
        }
    }
    if ($agentProcessAlive -and $content -match '(?m)^(-\s*Status:\s*)locked$') {
        Write-OrchestratorLog "LANE_HOLD file='$($File.Name)' reason=locked_live_agent agent=$Agent kind=$RescueKind"
        return
    }

    # Parent stream/lane guard: a plan may list a per-task Agent: (e.g. code-<pid>)
    # that is not the long-running lane/stream process. The lane's own process is
    # the real liveness signal for files that live inside it.
    $parentDir = $File.DirectoryName
    $parentAgentId = $null
    foreach ($parentJson in @((Join-Path $parentDir "stream.json"), (Join-Path $parentDir "lane.json"))) {
        if (Test-Path $parentJson) {
            try { $parentAgentId = (Get-Content $parentJson -Raw | ConvertFrom-Json -ErrorAction Stop).Id } catch {
                Write-OrchestratorLog "ORPHAN_PARENT_JSON_READ_FAILED file=$parentJson error='$($_.Exception.Message)'" -Level WARN
            }
            if ($parentAgentId) { break }
        }
    }
    $parentProcessAlive = $false
    if ($parentAgentId) {
        try {
            $parentAlive = Test-AgentAlive -AgentId $parentAgentId
            if ($parentAlive) {
                if ($null -ne $parentAlive.ProcessAlive) { $parentProcessAlive = [bool]$parentAlive.ProcessAlive }
                elseif ($null -ne $parentAlive.Alive) { $parentProcessAlive = [bool]$parentAlive.Alive }
            }
        } catch {
            Write-OrchestratorLog "ORPHAN_PARENT_ALIVE_PROBE_FAILED parent=$parentAgentId agent=$Agent error='$($_.Exception.Message)'" -Level WARN
        }
    }
    if ($parentProcessAlive) {
        Write-OrchestratorLog "LANE_HOLD file='$($File.Name)' reason=parent_lane_alive agent=$Agent parent=$parentAgentId kind=$RescueKind"
        return
    }

    if ($content -match '(?m)^(-\s*Status:\s*)locked$') {
        # Canonicalize the release stamp through New-LockHeader.ps1 instead of
        # regex hand-compose, which mojibakes UTF-8 and single-lines CRLF files.
        $body = $content -replace '(?ms)^\*\*Lock\*\*.*?\n---\s*\n', ''
        if ($body -eq $content) {
            $body = $content -replace '(?ms)^\*\*Lock\*\*\n.*?(?=\n[A-Z#]|\n\*\*[A-Z])', ''
        }

        $NewLockHeaderPath = Join-Path $RepoDir "Skills/Workflows/Cowork/Scripts/New-LockHeader.ps1"
        if (-not (Test-Path $NewLockHeaderPath)) {
            $NewLockHeaderPath = Resolve-Path (Join-Path $script:RepoRoot "Skills\Workflows\Cowork\Scripts\New-LockHeader.ps1") | Select-Object -ExpandProperty Path
        }

        $exitCode = 0
        & $NewLockHeaderPath $Agent "released" -OutputPath $File.FullName -ExistingContent $body -ReleaseTimestamp $now
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 3) {
            Write-OrchestratorLog "ORPHAN_RESCUE_TRUNCATION_RESTORED file='$($File.Name)' agent=$Agent kind=$RescueKind" -Level WARN
            return
        }
        if ($exitCode -ne 0) {
            Write-OrchestratorLog "ORPHAN_RESCUE_LOCK_FAILED file='$($File.Name)' agent=$Agent kind=$RescueKind exit=$exitCode" -Level ERROR
            return
        }

        # New-LockHeader.ps1 does not emit RescueReason; preserve the audit trail.
        $releasedContent = Get-Content $File.FullName -Raw -ErrorAction Stop
        $releasedContent = $releasedContent -replace '(?m)(^(-\s*Released:\s*)[^\r\n]+)$', "`$1`n- RescueReason: $RescueKind"
        $releasedContent | Set-Content -Path $File.FullName -Encoding utf8 -NoNewline

        $dest = Join-Path "$RepoDir/Tasks/Review" $File.Name
        Move-Item -LiteralPath $File.FullName -Destination $dest -Force
        Write-OrchestratorLog "FILE_MOVED file='$($File.Name)' from=$(Split-Path $parentDir -Leaf)/ to=Review/ reason=$RescueKind"
        Write-Output "[$RescueKind] instance=$InstanceId agent=$Agent file=$($File.Name) action=released"
        Write-OrchestratorLog "$RescueKind agent=$Agent file=$($File.Name) action=released"
        Write-Output "  ↪ Released orphaned lock on $($File.Name) → Review/"
    } elseif ($content -match '(?m)^(-\s*Status:\s*)released$') {
        $dest = Join-Path "$RepoDir/Tasks/Review" $File.Name
        Move-Item -LiteralPath $File.FullName -Destination $dest -Force
        Write-OrchestratorLog "FILE_MOVED file='$($File.Name)' from=$(Split-Path $parentDir -Leaf)/ to=Review/ reason=$RescueKind-released"
        Write-Output "  ↪ Moved stalled released file: $($File.Name) → Review/"
    }
    # Safe discard: dictionary Remove returns bool; absence is not an error here.
    if ($script:usedNamespaces) { $script:usedNamespaces.Remove($File.Name) | Out-Null }
}

function Restore-OrphanedLock {
    param([string]$RepoDir, [string[]]$SpawnedAgentIds)
    $orphanedFiles = Get-ChildItem "$RepoDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    # Hard timeout rescue: files in Working/ longer than 30 min get rescued
    # ONLY when the owning agent is actually dead. A live stream (PID alive +
    # fresh heartbeat) is never reclaimed regardless of file age — a stale file
    # timestamp means the agent is busy (long test suite), not dead. This
    # mirrors the liveness gate in the second loop below so a long-running but
    # healthy lane cannot be yanked back to Code/.
    $now = Get-Date
    $timeoutThresholdMins = 30
    foreach ($file in $orphanedFiles) {
        $ageMins = ($now - $file.LastWriteTime).TotalMinutes
        if ($ageMins -ge $timeoutThresholdMins) {
            $fileAgent = if ((Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }

            # Liveness gate: verify the owning agent is dead before a hard-timeout
            # rescue. A live process is the ground-truth signal (Test-AgentAlive
            # returns Stale=$false for a live PID even with a stale heartbeat).
            $agentDead = $false
            if ($fileAgent) {
                try {
                    $aliveInfo = Test-AgentAlive -AgentId $fileAgent
                    $agentDead = ($null -eq $aliveInfo) -or $aliveInfo.Stale
                } catch {
                    Write-OrchestratorLog "AGENT_ALIVE_CHECK_FAILED agent=$fileAgent error='$($_.Exception.Message)'" -Level WARN
                    $agentDead = $false
                }
            }
            if (-not $agentDead -and $fileAgent) {
                # Raw PID fallback — a live PID file means the agent is not dead,
                # even if Test-AgentAlive could not produce a definitive verdict.
                $agentPidFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$fileAgent.pid"
                if (Test-Path $agentPidFile -ErrorAction SilentlyContinue) {
                    $agentPidNum = Convert-PidSafe -Value (Get-Content $agentPidFile -Raw -ErrorAction SilentlyContinue)
                    if ($agentPidNum -and (Get-Process -Id $agentPidNum -ErrorAction SilentlyContinue)) {
                        $agentDead = $false
                    }
                }
            }
            if ($fileAgent -and -not $agentDead) {
                Write-OrchestratorLog "RESCUE_HARD_TIMEOUT_SKIPPED agent=$fileAgent file=$($file.Name) age=$([math]::Round($ageMins,1))min reason='live stream (PID alive / fresh heartbeat)'"
                continue
            }

            Write-OrchestratorLog "RESCUE_HARD_TIMEOUT agent=$fileAgent file=$($file.Name) age=$([math]::Round($ageMins,1))min threshold=${timeoutThresholdMins}min"
            Resolve-OrphanStatus -File $file -Agent $fileAgent -RepoDir $RepoDir -RescueKind "RESCUE_HARD_TIMEOUT"
        }
    }

    foreach ($file in $orphanedFiles) {
        $fileAgent = if ((Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }
        if (-not $fileAgent) { continue }

        $aliveInfo = $null
        try { $aliveInfo = Test-AgentAlive -AgentId $fileAgent } catch { Write-OrchestratorLog "AGENT_ALIVE_CHECK_FAILED agent=$fileAgent error='$($_.Exception.Message)'" -Level WARN }

        if ($aliveInfo -and $aliveInfo.Stale) {
            Resolve-OrphanStatus -File $file -Agent $fileAgent -RepoDir $RepoDir -RescueKind "RESCUE_STALE"
            continue
        }

        # Raw PID fallback — check PID file directly when Test-AgentAlive unavailable
        $pidAlive = $null
        $agentPidFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$fileAgent.pid"
        if (Test-Path $agentPidFile -ErrorAction SilentlyContinue) {
            $agentPidStr = Get-Content $agentPidFile -Raw -ErrorAction SilentlyContinue
            $agentPidNum = Convert-PidSafe -Value $agentPidStr
            if ($agentPidNum) {
                if (Get-Process -Id $agentPidNum -ErrorAction SilentlyContinue) {
                    $pidAlive = $true
                }
            }
        }
        if ($pidAlive -eq $false) {
            Write-OrchestratorLog "RESCUE_PID_FALLBACK agent=$fileAgent file=$($file.Name) pidAlive=false"
            Resolve-OrphanStatus -File $file -Agent $fileAgent -RepoDir $RepoDir -RescueKind "RESCUE_PID"
            continue
        }

        if ($SpawnedAgentIds -and $fileAgent -notin $SpawnedAgentIds) {
            Write-Output "[RESCUE] instance=$InstanceId skipping file=$($file.Name) agent=$fileAgent (not spawned by this orchestrator, PID alive)"
            Write-OrchestratorLog "RESCUE_SKIP agent=$fileAgent file=$($file.Name) pidAlive=$pidAlive"
            continue
        }

        Resolve-OrphanStatus -File $file -Agent $fileAgent -RepoDir $RepoDir
    }

    $resvPath = Join-Path "$RepoDir/Tasks" "Logs/.reservations.json"
    if (Test-Path $resvPath) { Remove-Item $resvPath -Force -ErrorAction SilentlyContinue }

    # Clean empty agent subdirectories
    Get-ChildItem "$RepoDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^(code|coder|reviewer)-\d+-\d+|REVIEWER_' } |
        Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Clean stale file locks from Tasks/Locks/
    $lockDir = Join-Path $RepoDir "Tasks" "Locks"
    if (Test-Path $lockDir) {
        Get-ChildItem "$lockDir\*.lock" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        $staleLockDir = Join-Path $RepoDir "Tasks" "Locks"
        Get-ChildItem "$staleLockDir\*.lock.lock" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

