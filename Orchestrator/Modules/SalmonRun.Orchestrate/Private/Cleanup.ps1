<#
.SYNOPSIS
    Stale file cleanup, iteration environment management, status display, and preflight checks.
.DESCRIPTION
    Error-swallowing convention (2026-08-04 alignment): -ErrorAction SilentlyContinue is used
    only for cleanup/probe operations where absence is a valid state (removing possibly-absent
    files, Get-Process liveness checks, reading optional logs). State-changing failures are
    logged via Write-OrchestratorLog; empty catch blocks are never used.
#>

function Clear-StaleOrchestratorFiles {
    param(
        [string]$RepoDir,
        [int]$InstanceId,
        [int]$SubprocessTimeoutMinutes
    )
    if (-not $RepoDir) { return @() }
    $logDir = Join-Path $RepoDir "Tasks/Logs"
    $archiveDir = Join-Path $RepoDir "Tasks/Complete/PID"
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
        $hasFatal     = $logText -match 'ORCHESTRATOR_FATAL_CRASH|fatal-crash'
        $isParentWrapper = $logText -match 'MUTEX_ACQUIRED' -and $logText -match 'LOCAL_EXECUTOR_READY' -and $logText -notmatch 'ORCHESTRATOR_START'
        $fatalKinds   = @('crashed', 'fatal-crash')
        $cleanKinds   = @('clean', 'stopped', 'drain-timeout', 'max-iterations', 'stalled', 'idle-timeout', 'detach-wrapper')

        if ($isParentWrapper -and -not $hasExit) {
            $isError = $false
        } elseif ($hasFatal -or ($exitKind -in $fatalKinds)) {
            $isError = $true
        } elseif ($hasExit -and ($exitKind -in $cleanKinds)) {
            $isError = $false
        } elseif ($hasExit) {
            $isError = $false
        } else {
            $isError = $true
        }
        if ($isError) { $errorCount++ }

        $crashLines   = @($logTail | Select-String -Pattern '\bERROR\b|\bCRASH\b|\bFAIL\b|exception\b|Exception\b' -ErrorAction SilentlyContinue)

        $finding = [PSCustomObject]@{
            PID        = $procPid
            LogFile    = $f.Name
            ExitKind   = $exitKind
            HasExit    = $hasExit
            HasError   = $isError
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
            $chkPid = Convert-PidSafe -Value $existingPid
            if (-not $chkPid -or -not (Get-Process -Id $chkPid -ErrorAction SilentlyContinue)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Legacy fallback: clean old single-pid file
    $legacyPidLock = Join-Path $logDir ".orchestrator-pid"
    if (Test-Path $legacyPidLock) {
        $existingPid = try { (Get-Content $legacyPidLock -Raw -ErrorAction Stop).Trim() } catch { $null }
        if ($existingPid) {
            $chkPid = Convert-PidSafe -Value $existingPid
            if (-not $chkPid -or -not (Get-Process -Id $chkPid -ErrorAction SilentlyContinue)) {
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
        (Join-Path $RepoDir "Tasks/stop.code"),
        (Join-Path $RepoDir "Tasks/stop.review"),
        (Join-Path $RepoDir "Tasks/stop.audit"),
        (Join-Path $RepoDir "Tasks/stop")
    )
    foreach ($sf in $taskStopFiles) {
        if (Test-Path $sf) {
            Remove-Item $sf -Force -ErrorAction SilentlyContinue
            Write-OrchestratorLog "STALE_STOP_SIGNAL_CLEANED path=$sf"
        }
    }

    $agentDir = Join-Path $logDir "agents"
    if (Test-Path $agentDir) {
        try {
            $result = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120 -RemoveLogs
            if ($result.RemovedCount -gt 0) {
                Write-OrchestratorLog "STALE_AGENT_CLEANUP count=$($result.RemovedCount) files=$($result.RemovedFiles -join ';')"
            }
        } catch {
            Write-OrchestratorLog "STALE_AGENT_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN
        }
        $cutoff = (Get-Date).AddDays(-7)
        foreach ($ext in @('.exit', '.stdout', '.stderr', '.log')) {
            Get-ChildItem "$agentDir\*$ext" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem "$agentDir\*-data" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -or (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clean crash evidence older than 7 days
    $crashDir = Join-Path $logDir "crashes"
    if (Test-Path $crashDir) {
        Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Flat-file Working/ cleanup
    $workingDir = Join-Path $RepoDir "Tasks/Working"
    if (Test-Path $workingDir) {
        Get-ChildItem "$workingDir\*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
            $flatFile = $_.FullName
            $reviewDir = Join-Path $RepoDir "Tasks/Review"
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

        $reportDir = Join-Path $RepoDir "Tasks/Complete"
        $null = New-Item -ItemType Directory -Path $reportDir -Force
        $reportName = "stale-orchestrator-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Set-Content -Path (Join-Path $reportDir $reportName) -Value $investigationText -Encoding utf8

        $dateStr = Get-Date -Format "yyyy.MM.dd"
        $planName = "$dateStr-fix-stale-orchestrator-cleanup.md"
        $planDir = Join-Path $RepoDir "Tasks/Code"
        $planPath = Join-Path $planDir $planName

        # Don't regenerate if already in Code/, Review/, Complete/, or already completed in git
        $existingInCode = Test-Path $planPath
        $existingInReview = Test-Path (Join-Path $RepoDir "Tasks/Review/$planName")
        $existingInComplete = @(Get-ChildItem "$RepoDir/Tasks/Complete/**/$planName" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        $completedInGit = git -C $RepoDir log --oneline --all -- "Tasks/*/$planName" 2>$null | Select-Object -First 1
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
   - **File**: `<Orchestrator/Orchestration/LocalOrchestrator.ps1>`
   - Add `Clear-StaleOrchestratorFiles` that scans and archives stale logs
   - Clean up stale .pid, .heartbeat, .mode artifacts
   - Investigate crash patterns and log findings

2. **Integrate cleanup into startup flow**
   - **File**: `<Orchestrator/Orchestration/LocalOrchestrator.ps1>`
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
    param([string]$RepoDir)
    $staleWorkingFiles = Get-ChildItem "$RepoDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    foreach ($f in $staleWorkingFiles) {
        $fileAgent = if ((Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }
        if (-not $fileAgent) { continue }

        # Parent stream/lane guard: never stamp a file as stale if the lane/stream
        # that owns its directory is still alive (per-task Agent: may be a short-lived
        # sub-identifier with no PID of its own).
        $parentDir = $f.DirectoryName
        $parentAgentId = $null
        foreach ($parentJson in @((Join-Path $parentDir "stream.json"), (Join-Path $parentDir "lane.json"))) {
            if (Test-Path $parentJson) {
                try { $parentAgentId = (Get-Content $parentJson -Raw | ConvertFrom-Json -ErrorAction Stop).Id } catch { Write-OrchestratorLog "PARENT_JSON_PARSE_FAILED file='$parentJson' error='$($_.Exception.Message)'" -Level WARN }
                if ($parentAgentId) { break }
            }
        }
        if ($parentAgentId) {
            try {
                $parentAlive = Test-AgentAlive -AgentId $parentAgentId
                $parentProcessAlive = $false
                if ($parentAlive) {
                    if ($null -ne $parentAlive.ProcessAlive) { $parentProcessAlive = [bool]$parentAlive.ProcessAlive }
                    elseif ($null -ne $parentAlive.Alive) { $parentProcessAlive = [bool]$parentAlive.Alive }
                }
                if ($parentProcessAlive) {
                    Write-OrchestratorLog "INTER_ITERATION_HOLD file='$($f.Name)' parent=$parentAgentId reason=parent_lane_alive"
                    continue
                }
            } catch { Write-OrchestratorLog "PARENT_LANE_ALIVE_CHECK_FAILED file='$($f.Name)' parent=$parentAgentId error='$($_.Exception.Message)'" -Level WARN }
        }

        try {
            $alive = Test-AgentAlive -AgentId $fileAgent
            if ($alive.Stale) {
                Write-Host "  ⚠ Stale file detected mid-run: $($f.Name) (agent $fileAgent)" -ForegroundColor Yellow
                Resolve-OrphanStatus -File $f -Agent $fileAgent -RepoDir $RepoDir -RescueKind "RESCUE_STALE"
                Write-OrchestratorLog "INTER_ITERATION_RESCUE agent=$fileAgent file=$($f.Name)"
            }
        } catch {
            Write-OrchestratorLog "INTER_ITERATION_RESCUE_ERROR agent=$fileAgent file=$($f.Name) error=$($_.Exception.Message)" -Level WARN
        }
    }
    # Auto-rescue Failed/ queue — move ready/released files back to Code/Review
    try { Rescue-FailedQueue -RepoDir $RepoDir } catch {
        Write-OrchestratorLog "FAILED_QUEUE_RESCUE_ERROR error='$($_.Exception.Message)'" -Level WARN
    }
}

function Invoke-PeriodicCleanup {
    param([int]$Iteration, [string]$RepoDir)
    if ($script:usedNamespaces) {
        try { Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces } catch { Write-OrchestratorLog "USEDNS_CLEANUP_FAILED iteration=$Iteration error='$($_.Exception.Message)'" -Level WARN }
    }
    if ($Iteration % 5 -eq 0) {
        try { Clear-StaleRetryBudgetEntries -RepoDir $RepoDir } catch { Write-OrchestratorLog "RETRY_BUDGET_GC_PERIODIC_FAILED iteration=$Iteration error='$($_.Exception.Message)'" -Level WARN }
        try {
            Get-ChildItem "$RepoDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -cmatch '^(coder|reviewer)-\d+-\d+|REVIEWER_' } |
                Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } catch { Write-OrchestratorLog "EMPTY_WORKING_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }
        try { Clear-StaleAgentFiles -RemoveLogs } catch { Write-OrchestratorLog "STALE_AGENT_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }
        try { Resolve-Quarantine -RepoDir $RepoDir } catch { Write-OrchestratorLog "QUARANTINE_RESOLVE_FAILED error='$($_.Exception.Message)'" -Level WARN }
        try {
            Get-ChildItem "$RepoDir/Tasks/Logs/agents/*.stdout" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem "$RepoDir/Tasks/Logs/agents/*.stderr" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { Write-OrchestratorLog "STALE_LOGS_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }
        try {
            $crashDir = Join-Path (Join-Path $RepoDir "Tasks/Logs") "crashes"
            if (Test-Path $crashDir) {
                Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-OrchestratorLog "CRASH_DIR_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }
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
    $failedInfo = if ($Counts.Failed -gt 0) { "  Failed:$($Counts.Failed)" } else { "" }
    $blockedInfo = if ($Counts.Blocked -gt 0) { "  Blocked:$($Counts.Blocked)" } else { "" }
    $streamInfo = if ($Counts.ActiveStreams -gt 0) { " Streams:$($Counts.ActiveStreams)" } else { "" }
    Write-Host "`n[Loop $Iteration]  Code:$($Counts.RootCoder)  Review:$($Counts.Review)$handoffInfo$blockedInfo  Working:$($Counts.Working)$failedInfo$streamInfo  Elapsed:${elapsedSec}s" -ForegroundColor Cyan

    if ($script:activeStreams -and $script:activeStreams.Count -gt 0) {
        foreach ($ns in $script:activeStreams.Keys) {
            $s = $script:activeStreams[$ns]
            $start = if ($s.StartTime -is [datetime]) { $s.StartTime } elseif ($s.StartTime) { [datetime]$s.StartTime } else { Get-Date }
            $sElapsed = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
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
    $configuredPath = [string]$env:OPENCODE_CLI_PATH
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        if (-not (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
            throw "Configured OPENCODE_CLI_PATH does not resolve to a file: '$configuredPath'"
        }
        if ($configuredPath -match '(?i)[\\/]WindowsApps[\\/]') {
            throw 'Packaged WindowsApps OpenCode path is not supported for child-process launch; set OPENCODE_CLI_PATH to a standalone CLI wrapper.'
        }
        return $configuredPath
    }

    # Resolve launchable shims from PATH before any package-internal binary.
    # The global npm package binary is not a safe detached child-process target
    # on this Windows host and can fail with access denied.
    $opencodeCmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
    if (-not $opencodeCmd) { $opencodeCmd = Get-Command opencode.ps1 -ErrorAction SilentlyContinue }
    if (-not $opencodeCmd) {
        $opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
    }
    if (-not $opencodeCmd) {
        $opencodeCmd = Get-Command opencode.exe -ErrorAction SilentlyContinue
    }
    if (-not $opencodeCmd) {
        $commonPaths = @(
            "$env:APPDATA\npm\opencode.ps1",
            "$env:APPDATA\npm\opencode",
            "$env:LOCALAPPDATA\opencode\opencode.ps1",
            "$env:LOCALAPPDATA\opencode\opencode.exe",
            "$env:LOCALAPPDATA\opencode\opencode.cmd",
            "$env:APPDATA\npm\opencode.cmd",
            "$env:ProgramFiles\nodejs\opencode.cmd",
            "$env:USERPROFILE\.opencode\bin\opencode.ps1",
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

function Invoke-OpenCodeSpawnCommand {
    param([string]$OpenCodeScriptPath, [string]$Command, [string]$Model = '', [string]$Variant = '')
    $cliArgs = @('run', '--auto', '--command', $Command)
    if ($Model) { $cliArgs += @('--model', $Model) }
    if ($Variant) { $cliArgs += @('--variant', $Variant) }
    if ([System.IO.Path]::GetExtension($OpenCodeScriptPath) -ieq '.exe') {
        # The npm installation directory is executable from PowerShell's call
        # operator but can reject Start-Process under the user's ACL. Launch
        # through pwsh so redirected worker stdout/stderr remains reliable.
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $quoted = @($cliArgs | ForEach-Object { "'$(($_ -replace "'", "''"))'" }) -join ' '
        $args = @('-NoProfile', '-NoLogo', '-Command', "& '$($OpenCodeScriptPath -replace "'", "''")' $quoted")
        $filePath = $pwsh
    }
    else {
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $args = @('-NoProfile', '-File', $OpenCodeScriptPath) + $cliArgs
        $filePath = $pwsh
    }
    return @{
        FilePath = $filePath
        ArgumentList = $args
    }
}
