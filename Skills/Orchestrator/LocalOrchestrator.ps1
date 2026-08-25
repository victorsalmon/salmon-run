<#
.SYNOPSIS
    Thin wrapper around the SalmonRun.Orchestrate module for backward compatibility.
    Actual logic moved to Start-Orchestrator in Orchestrator/Modules/SalmonRun.Orchestrate/.

.DESCRIPTION
    On startup, Clear-StaleOrchestratorFiles performs a stale-process sweep scoped to
    repo-owned orchestrator processes only: a pwsh.exe process is killed only when its
    executable lives under Program Files AND its command line contains this repo root
    plus an orchestrator entry-point pattern (LocalOrchestrator|Start-Orchestrator|watchdog).
    An optional -ProcessCutoffDate threshold may be supplied; by default no date cutoff
    applies. Every killed PID is logged with its command line before graceful stop, with
    Stop-Process -Force used only as a fallback. No unrelated pwsh sessions are touched.
#>

param(
    [ValidateSet("opencode", "devin", "deepseek", "codex")]
    [string]$Harness = $env:OC_HARNESS,
    [string]$Provider = $env:OC_PROVIDER,
    [string]$Model = $env:OC_MODEL,
    [string]$Effort = $env:OC_EFFORT,
    [ValidateSet("local", "local-platform", "platform", "devin", "dsh")]
    [string]$Executor = "local",
    [int]$CodeParallelCount = 9,
    [int]$ReviewerParallelCount = 3,
    [int]$MaxRuntimeMinutes,
    [int]$PollIntervalSeconds,
    [int]$IdleTimeoutMinutes,
    [int]$MaxIterations,
    [int]$InstanceId,
    [int]$SubprocessTimeoutMinutes,
    [int]$ModuleCount = 1,
    [switch]$NoAuditPrompt,
    [switch]$Detach,
    [switch]$Resume,
    [string]$SpawnMode = "Subprocess"
)

function Clear-StaleOrchestratorFiles {
    param(
        [string]$RepoDir,
        [int]$InstanceId,
        [int]$SubprocessTimeoutMinutes,
        [int]$HeartbeatStaleThresholdSeconds = 120,
        [Nullable[datetime]]$ProcessCutoffDate = $null
    )
    if (-not $RepoDir) { return @() }

    $logDir = Join-Path $RepoDir "Tasks/Logs"
    $archiveDir = Join-Path $RepoDir "Tasks/Complete/PID"
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

        $reportDir = Join-Path $RepoDir "Tasks/Complete"
        $null = New-Item -ItemType Directory -Path $reportDir -Force
        $reportName = "stale-orchestrator-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Set-Content -Path (Join-Path $reportDir $reportName) -Value $investigationText -Encoding utf8

        $dateStr = Get-Date -Format "yyyy.MM.dd"
        $planName = "$dateStr-fix-stale-orchestrator-cleanup.md"
        $planDir = Join-Path $RepoDir "Tasks/Code"
        $planPath = Join-Path $planDir $planName

        $existingInCode = Test-Path $planPath
        $existingInReview = Test-Path (Join-Path $RepoDir "Tasks/Review/$planName")
        $existingInComplete = @(Get-ChildItem "$RepoDir/Tasks/Complete/**/$planName" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        $completedInGit = $null
        try { $completedInGit = git -C $RepoDir log --oneline --all -- "Tasks/*/$planName" 2>$null | Select-Object -First 1 } catch { Write-Host ("[STARTUP] git log query failed for ${planName}: $_") -ForegroundColor Red }

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
            Write-Host "  Investigation report: Tasks/Complete/$reportName" -ForegroundColor DarkGray
            Write-Host "  Generated coder session plan: Tasks/Code/$planName" -ForegroundColor Yellow
        }
    } elseif ($findings.Count -gt 0) {
        Write-Host "  Archived $($findings.Count) stale orchestrator(s) without errors" -ForegroundColor DarkGray
    }

    # Kill stale repo-owned orchestrator pwsh processes still running pre-fix code in memory.
    # Scope (defensive — never kills unrelated sessions):
    #   - Process must be pwsh.exe installed under Program Files (not a copied/portable interpreter)
    #   - Command line must contain this repo root ($RepoDir) AND match the orchestrator
    #     entry-point patterns (LocalOrchestrator|Start-Orchestrator|watchdog)
    #   - Optional -ProcessCutoffDate threshold (default: no date cutoff — the scope check suffices)
    # Every killed PID is logged with its command line before termination; graceful stop first,
    # Stop-Process -Force only as a fallback.
    try {
        $scopePattern = 'LocalOrchestrator|Start-Orchestrator|watchdog'
        $oldPws = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.ExecutablePath -match '\\pwsh\.exe$' -and
                $_.ExecutablePath -match 'Program Files' -and
                $_.CommandLine -match [regex]::Escape($RepoDir) -and
                $_.CommandLine -match $scopePattern -and
                (-not $ProcessCutoffDate -or $_.CreationDate -lt $ProcessCutoffDate)
            }
        foreach ($p in $oldPws) {
            $started = $p.CreationDate.ToString('o')
            $cmdLine = (($p.CommandLine -replace '\s+', ' ').Trim())
            Write-Host "[STARTUP] Killing stale repo-owned orchestrator pwsh PID $($p.ProcessId) started $started" -ForegroundColor Yellow
            Write-Host "[STARTUP]   cmd: $cmdLine" -ForegroundColor Yellow
            Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            if (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Host "[STARTUP] Stale orchestrator process sweep failed: $_" -ForegroundColor DarkGray
    }

    return $findings
}

# Startup stale-cleanup before module load
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Clear-StaleOrchestratorFiles -RepoDir $repoRoot -InstanceId $InstanceId -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes

# Guard: any task files written to the wrong repo must be relocated before dispatch
$skillsRoot = Join-Path $repoRoot "Skills"
if (-not (Test-Path $skillsRoot)) { $skillsRoot = Join-Path (Split-Path $repoRoot -Parent) "Skills" }
& (Join-Path $skillsRoot "Documentation/Scripts/Invoke-RelocateStrayTaskFiles.ps1")

# Startup trap — catches unhandled exceptions during init and writes diagnostic file
trap {
    $interclawRoot = $repoRoot
    $initErrFile = Join-Path $interclawRoot "Tasks/Logs/.orchestrator-init-error"
    $null = New-Item -ItemType Directory -Path (Split-Path $initErrFile -Parent) -Force
    "$(Get-Date -Format 'o'): Unhandled exception in orchestrator startup`n$($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File $initErrFile -Encoding utf8
    Write-Host "[FATAL] Orchestrator startup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Ensure ORCHESTRATOR module path is in PSModulePath so .psd1 RequiredModules resolve
$ORCHESTRATORModulePath = Resolve-Path (Join-Path $PSScriptRoot "..\Modules")
if ($ORCHESTRATORModulePath -and $env:PSModulePath -notlike "*$ORCHESTRATORModulePath*") {
    $env:PSModulePath = "$ORCHESTRATORModulePath;$env:PSModulePath"
}
$DockerModulePath = Resolve-Path (Join-Path $repoRoot "Orchestrator\Modules")
if ($DockerModulePath -and $env:PSModulePath -notlike "*$DockerModulePath*") {
    $env:PSModulePath = "$DockerModulePath;$env:PSModulePath"
}

# Load the module using .psd1 to get FunctionsToExport applied correctly
$modulePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\SalmonRun.Orchestrate.psd1"
$modulePath = Resolve-Path $modulePath -ErrorAction Stop
if (-not (Test-Path $modulePath)) {
    Write-Error "Module not found at expected path: $modulePath"
    Write-Error "Expected location relative to script: $PSScriptRoot\..\Docker\Modules\SalmonRun.Orchestrate\SalmonRun.Orchestrate.psd1"
    exit 1
}
Import-Module $modulePath -Force -ErrorAction Stop

# Forward executor via file-based mechanism for robust detection across module boundary
$repoRoot = $repoRoot # already resolved at startup
$executorFile = Join-Path $repoRoot "Tasks/Logs/.orchestrator-executor-$PID"
$null = New-Item -ItemType Directory -Path (Split-Path $executorFile -Parent) -Force
$Executor | Out-File $executorFile -Encoding utf8 -NoNewline
Start-Orchestrator @PSBoundParameters
