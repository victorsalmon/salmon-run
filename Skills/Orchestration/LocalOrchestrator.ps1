<#
.SYNOPSIS
    Thin wrapper around the SalmonRun.Orchestrate module for backward compatibility.
    Actual logic moved to Start-Orchestrator in Skills/Docker/Modules/SalmonRun.Orchestrate/.
#>

param(
    [string]$Executor = "local",
    [int]$CodeParallelCount = 9,
    [int]$ReviewerParallelCount = 3,
    [int]$MaxRuntimeMinutes,
    [int]$PollIntervalSeconds,
    [int]$IdleTimeoutMinutes,
    [int]$MaxIterations,
    [int]$InstanceId,
    [int]$SubprocessTimeoutMinutes,
    [int]$ModuleCount = 0,
    [switch]$NoAuditPrompt,
    [switch]$Detach,
    [switch]$Resume,
    [string]$SpawnMode = "Subprocess"
)

function Clear-StaleOrchestratorFiles {
    param(
        [string]$InterclawDir,
        [int]$InstanceId,
        [int]$SubprocessTimeoutMinutes,
        [int]$HeartbeatStaleThresholdSeconds = 120
    )
    if (-not $InterclawDir) { return @() }

    $logDir = Join-Path $InterclawDir "Tasks/Logs"
    $archiveDir = Join-Path $InterclawDir "Tasks/Complete/PID"
    $findings = [System.Collections.Generic.List[object]]::new()
    $errorCount = 0

    # Archive stale orchestrator logs and gather findings
    $logs = Get-ChildItem "$logDir\orchestrator-*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-structured.log' -and $_.Name -notlike '*-fallback.log' }

    foreach ($f in $logs) {
        if ($f.Name -notmatch '^orchestrator-(\d+)\.log$') { continue }
        $procPid = [int]$Matches[1]
        if ($procPid -eq $PID -or (Get-Process -Id $procPid -ErrorAction SilentlyContinue)) { continue }

        $logTail = Get-Content $f.FullName -Tail 20 -ErrorAction SilentlyContinue
        $logText = $logTail | Out-String

        $exitKind = if ($logText -match 'exit_kind=(\w+)') { $Matches[1] } else { 'unknown' }
        $hasExit = $logText -match 'ORCHESTRATOR_EXIT'
        $hasFatal = $logText -match 'ORCHESTRATOR_FATAL_CRASH|fatal-crash'
        $isParentWrapper = $logText -match 'MUTEX_ACQUIRED' -and $logText -match 'LOCAL_EXECUTOR_READY' -and $logText -notmatch 'ORCHESTRATOR_START'
        $fatalKinds = @('crashed', 'fatal-crash')
        $cleanKinds = @('clean', 'stopped', 'drain-timeout', 'max-iterations', 'stalled', 'idle-timeout', 'detach-wrapper')

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

        $crashLines = @($logTail | Select-String -Pattern '\bERROR\b|\bCRASH\b|\bFAIL\b|exception\b|Exception\b' -ErrorAction SilentlyContinue)
        $crashText = if ($crashLines.Count -gt 0) { ($crashLines | ForEach-Object { $_.Line.Trim() }) -join ' | ' } else { '' }

        $finding = [PSCustomObject]@{
            PID        = $procPid
            LogFile    = $f.Name
            ExitKind   = $exitKind
            HasExit    = $hasExit
            HasError   = $isError
            CrashLines = $crashText
            LastWrite  = $f.LastWriteTime
            IsError    = $isError
        }
        $findings.Add($finding)

        $null = New-Item -ItemType Directory -Path $archiveDir -Force
        $archivePath = Join-Path $archiveDir $f.Name
        for ($moveAttempt = 1; $moveAttempt -le 3; $moveAttempt++) {
            try {
                Move-Item -LiteralPath $f.FullName -Destination $archivePath -Force -ErrorAction Stop
                break
            } catch {
                if ($moveAttempt -lt 3) {
                    Write-Host "[STARTUP] Retry $moveAttempt/3 archiving $($f.Name): $_" -ForegroundColor DarkGray
                    Start-Sleep -Seconds $moveAttempt
                } else {
                    Write-Host "[STARTUP] Failed to archive stale orchestrator log: $($f.Name)" -ForegroundColor Red
                }
            }
        }
    }

    # Clean stale agent artifacts (PID/heartbeat/mode/stdout/stderr/log)
    $agentDir = Join-Path $logDir "agents"
    if (Test-Path $agentDir) {
        foreach ($pidFile in Get-ChildItem -Path $agentDir -Filter "*.pid" -ErrorAction SilentlyContinue) {
            $agentId = $pidFile.BaseName
            $pidStr = (Get-Content $pidFile.FullName -Raw -ErrorAction SilentlyContinue).Trim()
            $procId = 0
            $alive = [int]::TryParse($pidStr, [ref]$procId) -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)

            $hbPath = Join-Path $agentDir "$agentId.heartbeat"
            $hbStale = $false
            if (Test-Path $hbPath) {
                $hbContent = (Get-Content $hbPath -Raw -ErrorAction SilentlyContinue).Trim()
                if ([string]::IsNullOrWhiteSpace($hbContent)) {
                    $hbStale = $true
                } else {
                    try {
                        $hbTime = [datetime]::Parse($hbContent, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $hbStale = ([datetime]::UtcNow - $hbTime.ToUniversalTime()).TotalSeconds -gt $HeartbeatStaleThresholdSeconds
                    } catch {
                        $hbStale = $true
                    }
                }
            } else {
                $hbStale = $true
            }

            if (-not $alive -and $hbStale) {
                $agentArchive = Join-Path $archiveDir $agentId
                $null = New-Item -ItemType Directory -Path $agentArchive -Force
                foreach ($ext in @('.pid','.heartbeat','.mode','.stdout','.stderr','.log')) {
                    $src = Join-Path $agentDir "$agentId$ext"
                    for ($ma = 1; $ma -le 2; $ma++) {
                        try {
                            Move-Item -Path $src -Destination $agentArchive -Force -ErrorAction Stop
                            break
                        } catch [System.Management.Automation.ItemNotFoundException] {
                            # Optional artifact absent (e.g. no .mode) — nothing to archive
                            break
                        } catch {
                            if ($ma -eq 2) {
                                Write-Host ("[STARTUP] Failed to archive $($agentId)${ext}: $_") -ForegroundColor Red
                            } else {
                                Start-Sleep -Seconds 1
                            }
                        }
                    }
                }
                Write-Host "[STARTUP] Archived stale agent artifacts: $agentId" -ForegroundColor Yellow
            }
        }

        # Orphan heartbeat files without a matching PID
        foreach ($hbFile in Get-ChildItem -Path $agentDir -Filter "*.heartbeat" -ErrorAction SilentlyContinue) {
            $agentId = $hbFile.BaseName
            $pidPath = Join-Path $agentDir "$agentId.pid"
            try { $null = Get-Item -LiteralPath $pidPath -ErrorAction Stop; $pidExists = $true } catch { $pidExists = $false }
            if (-not $pidExists) {
                $agentArchive = Join-Path $archiveDir $agentId
                $null = New-Item -ItemType Directory -Path $agentArchive -Force
                Move-Item -Path $hbFile.FullName -Destination $agentArchive -Force -ErrorAction SilentlyContinue
                Write-Host "[STARTUP] Archived orphan heartbeat: $agentId" -ForegroundColor Yellow
            }
        }
    }

    # Generate investigation report and session plan when stale logs contain errors
    if ($errorCount -gt 0) {
        Write-Host "  Found $errorCount stale orchestrator(s) with errors - investigating..." -ForegroundColor Yellow

        $investigation = [System.Text.StringBuilder]::new()
        [void]$investigation.AppendLine("Stale orchestrator investigation:")
        [void]$investigation.AppendLine("Found $($findings.Count) stale orchestrator log(s), $errorCount with errors.`n")
        [void]$investigation.AppendLine("Breakdown:")
        foreach ($ef in $findings | Where-Object { $_.IsError }) {
            if (-not $ef.HasExit) {
                [void]$investigation.AppendLine("- PID $($ef.PID): Crashed without ORCHESTRATOR_EXIT marker (last write: $($ef.LastWrite)). Possible: killed, OOM, PowerShell crash.")
            } else {
                [void]$investigation.AppendLine("- PID $($ef.PID): Exited with exit_kind=$($ef.ExitKind), error lines: $($ef.CrashLines)")
            }
        }
        [void]$investigation.AppendLine("`nRoot cause analysis:")
        $crashCount = @($findings | Where-Object { -not $_.HasExit }).Count
        if ($crashCount -gt 0) {
            [void]$investigation.AppendLine("- $crashCount orchestrator(s) crashed without clean exit. Likely causes:")
            [void]$investigation.AppendLine("  1. Process killed (OOM, user, system)")
            [void]$investigation.AppendLine("  2. PowerShell runtime crash during dispatch")
            [void]$investigation.AppendLine("  3. Job Object lifecycle race")
        }

        $allCrashLines = @($findings | Where-Object { $_.CrashLines } | ForEach-Object { $_.CrashLines })
        if ($allCrashLines.Count -gt 1) {
            $grouped = $allCrashLines | Group-Object | Sort-Object Count -Descending
            [void]$investigation.AppendLine("`nRecurring patterns:")
            foreach ($g in $grouped | Select-Object -First 5) {
                [void]$investigation.AppendLine("- '$($g.Name)' appeared $($g.Count) time(s)")
            }
        }

        $investigationText = $investigation.ToString()

        $reportDir = Join-Path $InterclawDir "Tasks/Complete"
        $null = New-Item -ItemType Directory -Path $reportDir -Force
        $reportName = "stale-orchestrator-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Set-Content -Path (Join-Path $reportDir $reportName) -Value $investigationText -Encoding utf8

        $dateStr = Get-Date -Format "yyyy.MM.dd"
        $planName = "$dateStr-fix-stale-orchestrator-cleanup.md"
        $planDir = Join-Path $InterclawDir "Tasks/Code"
        $planPath = Join-Path $planDir $planName

        $existingInCode = Test-Path $planPath
        $existingInReview = Test-Path (Join-Path $InterclawDir "Tasks/Review/$planName")
        $existingInComplete = @(Get-ChildItem "$InterclawDir/Tasks/Complete/**/$planName" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        $completedInGit = $null
        try { $completedInGit = git -C $InterclawDir log --oneline --all -- "Tasks/*/$planName" 2>$null | Select-Object -First 1 } catch { Write-Host ("[STARTUP] git log query failed for ${planName}: $_") -ForegroundColor Red }

        if ($existingInCode -or $existingInReview -or $existingInComplete -or $completedInGit) {
            Write-Host "  Skipping stale plan generation - $planName already in queue or completed" -ForegroundColor DarkGray
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
            Write-Host "  Investigation report: Tasks/Complete/$reportName" -ForegroundColor DarkGray
            Write-Host "  Generated coder session plan: Tasks/Code/$planName" -ForegroundColor Yellow
        }
    } elseif ($findings.Count -gt 0) {
        Write-Host "  Archived $($findings.Count) stale orchestrator(s) without errors" -ForegroundColor DarkGray
    }

    # Kill pre-2026-08-02 watchdog/orchestrator pwsh processes still running pre-fix code in memory
    $fixCutoff = [datetime]::new(2026, 8, 2, 0, 0, 0, [System.DateTimeKind]::Utc)
    try {
        $oldPws = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CreationDate -lt $fixCutoff -and $_.CommandLine -match 'LocalOrchestrator|Start-Orchestrator|watchdog' }
        foreach ($p in $oldPws) {
            $started = $p.CreationDate.ToString('o')
            Write-Host "[STARTUP] Killing pre-fix pwsh PID $($p.ProcessId) started $started" -ForegroundColor Yellow
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[STARTUP] Pre-fix process sweep failed: $_" -ForegroundColor DarkGray
    }

    return $findings
}

# Startup stale-cleanup before module load
$repoRoot = Split-Path -Parent $PSScriptRoot
Clear-StaleOrchestratorFiles -InterclawDir $repoRoot -InstanceId $InstanceId -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes

# Guard: any task files written to the wrong repo must be relocated before dispatch
& (Join-Path (Split-Path -Parent $PSScriptRoot) "Documentation\Scripts\Invoke-RelocateStrayTaskFiles.ps1")

# Startup trap — catches unhandled exceptions during init and writes diagnostic file
trap {
    $interclawRoot = Split-Path -Parent $PSScriptRoot
    $initErrFile = Join-Path $interclawRoot "Tasks/Logs/.orchestrator-init-error"
    $null = New-Item -ItemType Directory -Path (Split-Path $initErrFile -Parent) -Force
    "$(Get-Date -Format 'o'): Unhandled exception in orchestrator startup`n$($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File $initErrFile -Encoding utf8
    Write-Host "[FATAL] Orchestrator startup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Ensure ORCHESTRATOR module path is in PSModulePath so .psd1 RequiredModules resolve
$ORCHESTRATORModulePath = Resolve-Path (Join-Path $PSScriptRoot "..\Docker\Modules")
if ($ORCHESTRATORModulePath -and $env:PSModulePath -notlike "*$ORCHESTRATORModulePath*") {
    $env:PSModulePath = "$ORCHESTRATORModulePath;$env:PSModulePath"
}

# Load the module using .psd1 to get FunctionsToExport applied correctly
$modulePath = Join-Path $PSScriptRoot "..\Docker\Modules\SalmonRun.Orchestrate\SalmonRun.Orchestrate.psd1"
$modulePath = Resolve-Path $modulePath -ErrorAction Stop
if (-not (Test-Path $modulePath)) {
    Write-Error "Module not found at expected path: $modulePath"
    Write-Error "Expected location relative to script: $PSScriptRoot\..\Docker\Modules\SalmonRun.Orchestrate\SalmonRun.Orchestrate.psd1"
    exit 1
}
Import-Module $modulePath -Force -ErrorAction Stop

# Forward executor via file-based mechanism for robust detection across module boundary
$repoRoot = Split-Path -Parent $PSScriptRoot
$executorFile = Join-Path $repoRoot "Tasks/Logs/.orchestrator-executor-$PID"
$null = New-Item -ItemType Directory -Path (Split-Path $executorFile -Parent) -Force
$Executor | Out-File $executorFile -Encoding utf8 -NoNewline
Start-Orchestrator @PSBoundParameters
