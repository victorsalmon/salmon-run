<#
.SYNOPSIS
    Unattended refactor pipeline: Complete Audit -> Orchestrate -> Deploy -> Catchall.
.DESCRIPTION
    Runs 4 phases sequentially via inner RunFix calls, with a catchall loop
    that rescues quarantined files, fixes root causes, and re-runs up to 5
    iterations. Each phase runs as a foreground subprocess — no detached
    watchdog, no detach chain, no complex state management.
    The pipeline itself is designed to be a RunFix target.
.PARAMETER MaxRuntimeMinutes
    Per-phase timeout in minutes. Default 480 (8 hours per phase).
.PARAMETER DryRun
    Validate prerequisites and log what would happen, then exit.
.PARAMETER ResumeFromPhase
    Skip phases 1 through N-1. Default 1 (start from Phase 1).
.PARAMETER MaxCatchallIterations
    Maximum catchall fix-and-re-run iterations. Default 5.
#>

param(
    [int]$MaxRuntimeMinutes = 480,
    [switch]$DryRun,
    [int]$ResumeFromPhase = 1,
    [int]$MaxCatchallIterations = 5,
    [switch]$Detach
)

# --- Paths ---
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path "$scriptRoot/../../.."
Set-Location $repoRoot
[System.IO.Directory]::SetCurrentDirectory($repoRoot)

$logDir = "Tasks/Logs"
$null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path "Tasks/Logs/Audit/architectural" -Force -ErrorAction SilentlyContinue

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDir "refactor-pipeline-$timestamp.log"
$pidFilePath = Join-Path $logDir ".refactor-pipeline.pid"
$null = New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force -ErrorAction SilentlyContinue

# --- Logging ---
function Write-PipelineLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Shared: run opencode command with output capture and polling ---
function Invoke-OpencodeCommand {
    param([string]$CommandName, [string]$PhaseLabel, [string]$OutFile, [string[]]$ExtraArgs = @())
    Write-PipelineLog "PHASE $PhaseLabel START: $CommandName $($ExtraArgs -join ' ')"

    try {
        $ocExe = (Get-Command 'opencode.cmd' -ErrorAction SilentlyContinue).Source
        if (-not $ocExe) { $ocExe = (Get-Command 'opencode' -ErrorAction SilentlyContinue).Source }
        if (-not $ocExe) { throw "opencode CLI not found in PATH" }

        $errFile = "$OutFile.stderr"
        $argsList = @('run', '--command', $CommandName) + $ExtraArgs
        $proc = Start-Process -NoNewWindow -FilePath $ocExe `
            -ArgumentList $argsList `
            -PassThru `
            -RedirectStandardOutput $OutFile -RedirectStandardError $errFile

        $phaseStart = Get-Date
        $lastCheckpoint = [DateTime]::MinValue
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 60
            $elapsed = [math]::Floor(((Get-Date) - $phaseStart).TotalMinutes)
            if (([DateTime]::Now - $lastCheckpoint).TotalMinutes -ge 5) {
                $tail = Get-Content $OutFile -Tail 3 -ErrorAction SilentlyContinue
                if ($tail) {
                    $summary = ($tail -join ' | ').Substring(0, [Math]::Min(200, ($tail -join ' | ').Length))
                    Write-PipelineLog "PHASE ${PhaseLabel}: ${elapsed}m elapsed, last: $summary"
                } else {
                    Write-PipelineLog "PHASE ${PhaseLabel}: ${elapsed}m elapsed (no output yet)"
                }
                $lastCheckpoint = [DateTime]::Now
            }
            if ($elapsed -gt $MaxRuntimeMinutes) {
                Write-PipelineLog "PHASE $PhaseLabel TIMEOUT after ${elapsed} min"
                $proc.Kill()
                break
            }
        }
        $proc.WaitForExit()

        if (Test-Path $errFile) {
            Add-Content -Path $OutFile -Value (Get-Content $errFile -Raw) -Encoding UTF8
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        $status = "exit-$($proc.ExitCode)"
        Write-PipelineLog "PHASE $PhaseLabel END: $status"
        if ($proc.ExitCode -ne 0) {
            $tail = Get-Content $OutFile -Tail 5 -ErrorAction SilentlyContinue
            if ($tail) { $tail | ForEach-Object { Write-PipelineLog "  LAST: $_" } }
        }
    } catch {
        $status = "exception: $_"
        Write-PipelineLog "PHASE $PhaseLabel EXCEPTION: $_"
    }
    Write-PipelineLog "PHASE $PhaseLabel STATUS: $status"
    return $status
}

function Test-PhaseSuccess {
    param([string]$Status)
    return ($Status -match '^exit-0$')
}

# --- Prerequisites ---
function Test-Prerequisites {
    $ok = $true
    Write-PipelineLog "CHECK: opencode CLI"
    $oc = Get-Command 'opencode.cmd' -ErrorAction SilentlyContinue
    if (-not $oc) { $oc = Get-Command 'opencode' -ErrorAction SilentlyContinue }
    if (-not $oc) { Write-PipelineLog "  FAIL: opencode CLI not found in PATH"; $ok = $false }
    else { Write-PipelineLog "  OK: opencode at $($oc.Source)" }

    Write-PipelineLog "CHECK: pwsh"
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) { Write-PipelineLog "  FAIL: pwsh.exe not found"; $ok = $false }
    else { Write-PipelineLog "  OK: pwsh at $($pwsh.Source)" }

    Write-PipelineLog "CHECK: repo root"
    if (-not (Test-Path "opencode.json")) {
        Write-PipelineLog "  FAIL: opencode.json not found in repo root ($repoRoot)"
        $ok = $false
    } else { Write-PipelineLog "  OK: repo root at $repoRoot" }

    Write-PipelineLog "CHECK: command templates"
    $templates = @('audit-complete', 'runfix', 'refactor-pipeline')
    $config = Get-Content "opencode.json" -Raw | ConvertFrom-Json
    foreach ($t in $templates) {
        if ($config.command.$t) { Write-PipelineLog "  OK: $t command template" }
        else { Write-PipelineLog "  FAIL: $t command template missing"; $ok = $false }
    }

    Write-PipelineLog "CHECK: RunFix goals files"
    $goalsFiles = @(
        "Skills/Workflows/RunFix/runfix-audit-complete.md",
        "Skills/Workflows/RunFix/runfix-localorchestrator.md",
        "Skills/Workflows/RunFix/runfix-deploy.md"
    )
    foreach ($gf in $goalsFiles) {
        if (Test-Path $gf) { Write-PipelineLog "  OK: $gf" }
        else { Write-PipelineLog "  FAIL: $gf not found"; $ok = $false }
    }

    return $ok
}

# --- Phase 1: Complete Audit ---
function Invoke-Phase1 {
    $outFile = Join-Path $logDir "refactor-pipeline-$timestamp-phase1.out"
    return Invoke-OpencodeCommand -CommandName "runfix" -PhaseLabel 1 -OutFile $outFile -ExtraArgs @("audit-complete")
}

# --- Phase 2: Orchestrate (via RunFix localorchestrator) ---
function Invoke-Phase2 {
    $outFile = Join-Path $logDir "refactor-pipeline-$timestamp-phase2.out"
    return Invoke-OpencodeCommand -CommandName "runfix" -PhaseLabel 2 -OutFile $outFile -ExtraArgs @("localorchestrator")
}

# --- Phase 3: Deploy (via RunFix deploy) ---
function Invoke-Phase3 {
    $outFile = Join-Path $logDir "refactor-pipeline-$timestamp-phase3.out"
    return Invoke-OpencodeCommand -CommandName "runfix" -PhaseLabel 3 -OutFile $outFile -ExtraArgs @("deploy.ps1")
}

# --- Phase 4: Catchall — rescue, fix, re-run ---
function Invoke-Phase4 {
    param([int]$Iteration)
    Write-PipelineLog "CATCHALL ITERATION $Iteration"

    $fixesApplied = $false
    $needPhase1 = $false
    $needPhase2 = $false
    $needPhase3 = $false

    # a) Verify phase exit codes
    $p1Status = @(Get-Content $logPath -Raw | Select-String "PHASE 1 STATUS: exit-0")
    $p2Status = @(Get-Content $logPath -Raw | Select-String "PHASE 2 STATUS: exit-0")
    $p3Status = @(Get-Content $logPath -Raw | Select-String "PHASE 3 STATUS: exit-0")
    if (-not $p1Status) { Write-PipelineLog "CATCHALL: Phase 1 did not exit 0 — will re-run" }
    if (-not $p2Status) { Write-PipelineLog "CATCHALL: Phase 2 did not exit 0 — will re-run" }
    if (-not $p3Status) { Write-PipelineLog "CATCHALL: Phase 3 did not exit 0 — will re-run" }

    # b) Rescue Tasks/Failed/*.md -> Tasks/Code/
    $failedDir = "Tasks/Failed"
    if (Test-Path $failedDir) {
        $failedFiles = @(Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue)
        if ($failedFiles) {
            Write-PipelineLog "CATCHALL: Found $($failedFiles.Count) file(s) in Tasks/Failed/ — rescuing"
            $null = New-Item -ItemType Directory -Path "Tasks/Code" -Force
            foreach ($f in $failedFiles) {
                $dest = Join-Path "Tasks/Code" $f.Name
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                Write-PipelineLog "  RESCUE: $($f.Name) -> Tasks/Code/"
            }
            $fixesApplied = $true
            $needPhase2 = $true
        }
    }

    # c) Rescue Tasks/Complete/Failed/*.md -> Tasks/Code/
    $cfailedDir = "Tasks/Complete/Failed"
    if (Test-Path $cfailedDir) {
        $cfailedFiles = @(Get-ChildItem "$cfailedDir/*.md" -ErrorAction SilentlyContinue)
        if ($cfailedFiles) {
            Write-PipelineLog "CATCHALL: Found $($cfailedFiles.Count) file(s) in Tasks/Complete/Failed/ — rescuing"
            $null = New-Item -ItemType Directory -Path "Tasks/Code" -Force
            foreach ($f in $cfailedFiles) {
                $dest = Join-Path "Tasks/Code" $f.Name
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                Write-PipelineLog "  RESCUE: $($f.Name) -> Tasks/Code/"
            }
            $fixesApplied = $true
            $needPhase2 = $true
        }
    }

    # d) Remove stale lock artifacts
    $locksDir = "Tasks/Locks"
    if (Test-Path $locksDir) {
        $locks = @(Get-ChildItem "$locksDir/*" -ErrorAction SilentlyContinue)
        if ($locks) {
            Write-PipelineLog "CATCHALL: Removing $($locks.Count) stale lock(s)"
            Remove-Item "$locksDir/*" -Force -ErrorAction SilentlyContinue
        }
    }

    # e) Remove stale orchestrator PID files (dead PIDs only)
    $orchPidFiles = @(Get-ChildItem "Tasks/Logs/.orchestrator-*-pid" -ErrorAction SilentlyContinue)
    $wdPidFiles = @(Get-ChildItem "Tasks/Logs/.orchestrate-watchdog-pid" -ErrorAction SilentlyContinue)
    foreach ($pf in ($orchPidFiles + $wdPidFiles)) {
        $pidContent = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
        $pidNum = if ($pidContent) { $pidContent.Trim() -as [int] } else { $null }
        if (-not $pidNum -or -not (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) {
            Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
            Write-PipelineLog "  CLEAN: stale $($pf.Name)"
        }
    }

    # f) Remove stale agent PID files (dead PIDs only)
    $agentDir = "Tasks/Logs/agents"
    if (Test-Path $agentDir) {
        $agentPids = @(Get-ChildItem "$agentDir/*.pid" -ErrorAction SilentlyContinue)
        foreach ($pf in $agentPids) {
            $pidContent = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
            $pidNum = if ($pidContent) { $pidContent.Trim() -as [int] } else { $null }
            if (-not $pidNum -or -not (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) {
                $baseName = $pf.BaseName
                Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
                foreach ($ext in @('.heartbeat', '.mode', '.stdout', '.stderr', '.log')) {
                    Remove-Item (Join-Path $agentDir "${baseName}$ext") -Force -ErrorAction SilentlyContinue
                }
                Write-PipelineLog "  CLEAN: stale agent $baseName"
            }
        }
    }

    # g) Remove stale orchestrator active/heartbeat markers
    foreach ($staleFile in @(
        "Tasks/Logs/.orchestrator-active",
        "Tasks/Logs/.orchestrator-heartbeat",
        "Tasks/Logs/.orchestrate-reload-count",
        "Tasks/Logs/.orchestrate-crash-report"
    )) {
        if (Test-Path $staleFile) {
            Remove-Item $staleFile -Force -ErrorAction SilentlyContinue
            Write-PipelineLog "  CLEAN: $staleFile"
        }
    }

    # h) Check orchestrator logs for crash evidence
    $wdLogs = @(Get-ChildItem "Tasks/Logs/orchestrate-watchdog-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    foreach ($wl in $wdLogs) {
        $logContent = Get-Content $wl.FullName -Raw -ErrorAction SilentlyContinue
        if ($logContent -match 'CRASH_EVIDENCE') {
            Write-PipelineLog "CATCHALL WARNING: Crash evidence in $($wl.Name)"
            $fixesApplied = $true
            $needPhase2 = $true
        }
        if ($logContent -match 'NO_PROGRESS|ROGUE_AGENT|STALE_AGENT|DUPLICATE_INSTANCE') {
            Write-PipelineLog "CATCHALL WARNING: Orchestrator anomaly in $($wl.Name)"
        }
    }

    # i) Scan orchestrator structured logs for errors
    $structLogs = @(Get-ChildItem "Tasks/Logs/orchestrator-*-structured.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    foreach ($sl in $structLogs) {
        $logContent = Get-Content $sl.FullName -Raw -ErrorAction SilentlyContinue
        $errorCount = [regex]::Matches($logContent, '"level":"ERROR"').Count
        $warnCount = [regex]::Matches($logContent, '"level":"WARN"').Count
        if ($errorCount -gt 0) {
            Write-PipelineLog "CATCHALL WARNING: $errorCount ERROR(s) in $($sl.Name)"
        }
        if ($warnCount -gt 5) {
            Write-PipelineLog "CATCHALL WARNING: $warnCount WARN(s) in $($sl.Name) (threshold >5)"
        }
    }

    # j) Verify namespace assignments from audit output
    $phase1Out = @(Get-ChildItem "Tasks/Logs/refactor-pipeline-*-phase1.out" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($phase1Out) {
        $out = Get-Content $phase1Out.FullName -Raw -ErrorAction SilentlyContinue
        if ($out -match 'Namespace') {
            Write-PipelineLog "CATCHALL: Namespace assignments found in audit output"
        }
    }

    # k) Check file-retry-budget for cycling files
    $retryBudgetPath = "Tasks/Logs/file-retry-budget.json"
    if (Test-Path $retryBudgetPath) {
        try {
            $budget = Get-Content $retryBudgetPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($budget) {
                $cyclers = $budget.PSObject.Properties | Where-Object { $_.Value.retries -ge 2 }
                if ($cyclers) {
                    Write-PipelineLog "CATCHALL WARNING: $($cyclers.Count) cycling file(s) with 2+ retries"
                    foreach ($cyc in $cyclers) {
                        Write-PipelineLog "  CYCLE: $($cyc.Name) — retries=$($cyc.Value.retries)"
                    }
                }
            }
        } catch {}
    }

    # l) Check completed plans for max-fail misclassification
    $completedPlans = @(Get-ChildItem "Tasks/Complete/**/*.md" -Recurse -ErrorAction SilentlyContinue)
    $suspiciousPlans = @()
    foreach ($cp in $completedPlans) {
        $content = Get-Content $cp.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'Max fail count|failed.*quarantine|retries.*3') {
            $suspiciousPlans += $cp
        }
    }
    if ($suspiciousPlans) {
        Write-PipelineLog "CATCHALL: $($suspiciousPlans.Count) plan(s) may be falsely completed — rescuing"
        $null = New-Item -ItemType Directory -Path "Tasks/Code" -Force
        foreach ($sp in $suspiciousPlans) {
            $dest = Join-Path "Tasks/Code" $sp.Name
            Copy-Item -LiteralPath $sp.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            Write-PipelineLog "  RESCUE: $($sp.Name) -> Tasks/Code/"
        }
        $fixesApplied = $true
        $needPhase2 = $true
    }

    # --- Fix-and-re-run logic ---
    if (-not $p1Status) { $needPhase1 = $true }
    if (-not $p2Status) { $needPhase2 = $true }
    if (-not $p3Status) { $needPhase3 = $true }

    if ($needPhase1 -or $needPhase2 -or $needPhase3 -or $fixesApplied) {
        Write-PipelineLog "CATCHALL: Re-running phases (Phase1=$needPhase1 Phase2=$needPhase2 Phase3=$needPhase3 fixes=$fixesApplied)"
        if ($needPhase1) { Invoke-Phase1 }
        if ($needPhase2) { Invoke-Phase2 }
        if ($needPhase3) { Invoke-Phase3 }
        return $false  # loop will continue iteration
    }

    # --- All checks passed ---
    Write-PipelineLog "CATCHALL: All checks passed — pipeline complete"
    return $true
}

# --- Fleet Health Check ---
function Invoke-FleetHealthCheck {
    Write-PipelineLog "FLEET HEALTH CHECK"
    $unhealthy = @()
    try {
        $stackName = & {
            $stacks = docker stack ls --format "{{.Name}}" 2>$null
            if ($stacks) { $stacks | Select-Object -First 1 } else { $null }
        }
        if ($stackName) {
            $services = docker service ls --filter name=$stackName --format "{{.Name}} {{.Replicas}}" 2>$null
            if ($services) {
                $services | ForEach-Object {
                    Write-PipelineLog "  SERVICE: $_"
                    if ($_ -match '\s(\d+)/(\d+)$') {
                        if ($matches[1] -ne $matches[2]) { $unhealthy += $_ }
                    }
                }
            } else {
                Write-PipelineLog "  No services found for stack $stackName"
            }
        } else {
            Write-PipelineLog "  No running stack found"
        }

        if ($unhealthy.Count -gt 0) {
            Write-PipelineLog "  HEALTH FAIL: $($unhealthy.Count) service(s) not at desired replica count"
            $unhealthy | ForEach-Object { Write-PipelineLog "    UNHEALTHY: $_" }
            return $false
        } else {
            Write-PipelineLog "  HEALTH OK: All services at desired replica count"
            return $true
        }
    } catch {
        Write-PipelineLog "  Health check error: $_"
        return $false
    }
}

# --- Final Summary ---
function Invoke-FinalSummary {
    Write-PipelineLog "=== REFACTOR PIPELINE SUMMARY ==="
    Write-PipelineLog "Pipeline log: $logPath"
    Write-PipelineLog "Timestamp: $timestamp"
    foreach ($phase in @(1,2,3,4)) {
        $matches = Select-String -Path $logPath -Pattern "PHASE $phase (START|END|STATUS:)" -SimpleMatch
        if ($matches) {
            foreach ($m in $matches) { Write-PipelineLog "  $($m.Line.Trim())" }
        } else {
            Write-PipelineLog "  Phase ${phase}: not started"
        }
    }
    Write-PipelineLog "=== END ==="
}

# --- Cleanup ---
function Remove-PipelinePid {
    if (Test-Path $pidFilePath) {
        Remove-Item $pidFilePath -Force -ErrorAction SilentlyContinue
    }
}

# --- Main ---
try {
    [System.IO.File]::WriteAllText($pidFilePath, [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString())

    # Self-daemonize: re-launch hidden and exit immediately
    if ($Detach) {
        $pwsh = (Get-Command pwsh.exe).Source
        $childCmd = "& '$($MyInvocation.MyCommand.Path)' -ResumeFromPhase $ResumeFromPhase -MaxRuntimeMinutes $MaxRuntimeMinutes -MaxCatchallIterations $MaxCatchallIterations"
        if ($DryRun) { $childCmd += ' -DryRun' }
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($childCmd)
        $encoded = [Convert]::ToBase64String($bytes)
        $null = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
        Remove-PipelinePid
        exit 0
    }

    Write-PipelineLog "=== REFACTOR PIPELINE START ==="
    Write-PipelineLog "MaxRuntimeMinutes: $MaxRuntimeMinutes (per phase)"
    Write-PipelineLog "MaxCatchallIterations: $MaxCatchallIterations"
    Write-PipelineLog "ResumeFromPhase: $ResumeFromPhase"
    Write-PipelineLog "Log: $logPath"

    # Orphan cleanup: kill only subprocesses spawned by this pipeline process
    try {
        $stalePids = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$PID" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'opencode|pwsh' } |
            Select-Object -ExpandProperty ProcessId
        $stalePids = $stalePids | Select-Object -Unique
        if ($stalePids) {
            Write-PipelineLog "ORPHAN_CLEANUP: $($stalePids.Count) stale subprocess(es) under pipeline PID $PID — cleaning"
            $stalePids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-PipelineLog "ORPHAN_CLEANUP: scan error: $_"
    }

    if (-not (Test-Prerequisites)) {
        if ($DryRun) {
            Write-PipelineLog "DRY RUN: Prerequisites check complete. Some checks failed — review above."
            Remove-PipelinePid
            exit 0
        }
        Write-PipelineLog "FATAL: Prerequisites check failed"
        Remove-PipelinePid
        exit 1
    }

    if ($DryRun) {
        Write-PipelineLog "DRY RUN: Prerequisites OK. Phases that would run:"
        if ($ResumeFromPhase -le 1) { Write-PipelineLog "  Phase 1: RunFix audit-complete" }
        if ($ResumeFromPhase -le 2) { Write-PipelineLog "  Phase 2: RunFix localorchestrator" }
        if ($ResumeFromPhase -le 3) { Write-PipelineLog "  Phase 3: RunFix deploy.ps1" }
        if ($ResumeFromPhase -le 4) { Write-PipelineLog "  Phase 4: Catchall (rescue + fix + re-run)" }
        Write-PipelineLog "  Fleet Health Check"
        Remove-PipelinePid
        exit 0
    }

    Write-PipelineLog "Pipeline running from: $repoRoot"

    # --- Catchall loop (up to MaxCatchallIterations) ---
    $pipelineComplete = $false
    for ($iteration = 1; $iteration -le $MaxCatchallIterations; $iteration++) {
        if ($iteration -gt 1) {
            Write-PipelineLog "PIPELINE LOOP: Starting iteration $iteration"
        }

        # Phase 1: Complete Audit
        if ($ResumeFromPhase -le 1) {
            $p1 = Invoke-Phase1
            if (-not (Test-PhaseSuccess $p1)) {
                Write-PipelineLog "Phase 1 failed — catchall will handle re-run"
            }
        } else { Write-PipelineLog "Phase 1 skipped (ResumeFromPhase=$ResumeFromPhase)" }

        # Phase 2: Orchestrate
        if ($ResumeFromPhase -le 2) {
            $p2 = Invoke-Phase2
            if (-not (Test-PhaseSuccess $p2)) {
                Write-PipelineLog "Phase 2 failed — catchall will handle re-run"
            }
        } else { Write-PipelineLog "Phase 2 skipped (ResumeFromPhase=$ResumeFromPhase)" }

        # Phase 3: Deploy
        if ($ResumeFromPhase -le 3) {
            $p3 = Invoke-Phase3
            if (-not (Test-PhaseSuccess $p3)) {
                Write-PipelineLog "Phase 3 failed — catchall will handle re-run"
            }
        } else { Write-PipelineLog "Phase 3 skipped (ResumeFromPhase=$ResumeFromPhase)" }

        # Phase 4: Catchall
        $completed = Invoke-Phase4 -Iteration $iteration
        if ($completed) {
            $pipelineComplete = $true
            break
        }

        # Clear ResumeFromPhase for subsequent iterations so all phases are eligible
        $ResumeFromPhase = 1
    }

    if (-not $pipelineComplete) {
        Write-PipelineLog "FATAL: Catchall iterations exceeded ($MaxCatchallIterations) — manual intervention needed"
        Write-PipelineLog "CATCHALL_ITERATIONS_EXCEEDED"
    }

    $fleetOk = Invoke-FleetHealthCheck
    Invoke-FinalSummary

    if (-not $pipelineComplete) {
        Write-PipelineLog "Pipeline aborted — catchall could not resolve issues within $MaxCatchallIterations iterations"
        Remove-PipelinePid
        exit 1
    }

    if (-not $fleetOk) {
        Write-PipelineLog "FATAL: Fleet health check failed — some services not at desired replica count"
        Remove-PipelinePid
        exit 1
    }

    Write-PipelineLog "=== REFACTOR PIPELINE COMPLETE ==="
}
catch {
    Write-PipelineLog "FATAL PIPELINE ERROR: $_"
    Write-PipelineLog "=== REFACTOR PIPELINE CRASHED ==="
}
finally {
    Remove-PipelinePid
}
