<#
.SYNOPSIS
    Main orchestrator entry point. Manages coder/reviewer stream dispatch.
    Contains the entire main loop logic.
.OUTPUTS
    System.Void

.DESCRIPTION
    The orchestrator is the dev-environment equivalent of VERI's dispatch role.
    It never touches client code or secrets — it only inspects Tasks/Code/*.md and Tasks/Review/*.md files
    to make role-dispatch decisions.

    Architecture — connascence-group parallel dispatch:
    Files are grouped by connascence (namespace + file-target overlap). Each
    connascence group is dispatched as a single subprocess.  Up to $CodeParallelCount
    groups run concurrently.  Pre-lock ordering prevents file collisions between
    concurrent subprocesses.

    Loop:
    1. Count Tasks/Code/*.md (Coder), Tasks/Review/*.md (Reviewer), Tasks/Working/*.md (in-progress)
    2. Parse Lock Headers in Working/ to identify locked agents per role
    3. Apply priority rules to decide which role dispatches next
    4. Build connascence groups from available unlocked files
    5. Dispatch each group serially: spawn `opencode run --command work-<role>-once`
       with explicit filenames via OC_RESERVATION_FILES
    6. Wait for subprocess, then check exit code
    7. On timeout: kill subprocess, rescue Working/ files
    8. On non-zero exit: log and continue to next group
    9. When all queues empty: exit 0

.PARAMETER Executor
    Executor variant: local (Process), local-platform (PowerShell job), platform (third-party).
.PARAMETER MaxIterations
    Maximum consecutive iterations with no progress before the stall guard
    exits. Progress is measured by queue/state change (Code, Review, Working
    counts) between iterations. The loop continues while work is being done.
    Default 20.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes a single subprocess runs before being killed. Default 30.
.PARAMETER CodeParallelCount
    Maximum concurrent coder groups. Default 10.
.PARAMETER ReviewerParallelCount
    Maximum concurrent reviewer groups. Default 6.
.PARAMETER PollIntervalSeconds
    Seconds between queue re-scans when no streams are active. Default 300.
.PARAMETER MaxRuntimeMinutes
    Max wall-clock minutes before entering drain mode. 0 = unlimited. Default 0.
.PARAMETER NoAuditPrompt
    Skip the Alignment Audit prompt when queues are empty.
.PARAMETER Detach
    Re-launch as a hidden PowerShell process.
.PARAMETER Resume
    Rescue orphaned locks before starting the loop.
.PARAMETER InstanceId
    Orchestrator instance ID for mutex naming.
.PARAMETER SpawnMode
    Subprocess (local) or Container (docker exec).
.PARAMETER ModuleCount
    Number of additional git-worktree modules to create, each with its own
    3+1 lanes. 0 = no worktrees (shared-tree mode). Default 0.
.PARAMETER IdleTimeoutMinutes
    Minutes to wait with empty queues before exiting. Default 30.
## Constraints
- Single-instance mutex prevents concurrent orchestrator processes
- Serial dispatch per namespace to prevent file collisions
- Worktree mode for multi-module parallel dispatch
- Stop/soft-stop signals for graceful shutdown
- Spin detection to prevent tight-loop crashes
## Lessons Learned
- Persistent lanes prevent stream-ID proliferation; lanes are recycled across namespaces
- Dynamic capacity scaling avoids overwhelming subprocess capacity under load
- DependsOn cycle detection must be non-destructive (auto-repair by removing the cycle edge)
- Worktree module lanes must be created at startup, not lazily, to avoid race conditions
## Error-swallowing convention (2026-08-04 alignment)
- `-ErrorAction SilentlyContinue` is used ONLY for probe/cleanup operations where
  absence is a valid state: Get-Process liveness checks, Get-ChildItem/Get-Content
  of optional files, and Remove-Item of possibly-absent artifacts.
- State-changing failures (dispatch, spawn, stream lifecycle) are never suppressed;
  they log via Write-OrchestratorLog with -Level WARN/ERROR.
- `Out-Null` discards are justified inline with a comment where the return value is
  deliberately unused and the operation's failure is handled separately.
#>
function Start-Orchestrator {

param(
    [ValidateSet("opencode", "devin", "deepseek", "codex")]
    [string]$Harness = $env:OC_HARNESS,
    [string]$Provider = $env:OC_PROVIDER,
    [string]$Model = $env:OC_MODEL,
    [string]$Effort = $env:OC_EFFORT,
    [ValidateSet("local", "local-platform", "platform", "devin", "dsh")]
    [string]$Executor = $(if (Test-Path (Join-Path $script:RepoRoot "Tasks/Logs/.orchestrator-executor-$PID")) { Get-Content (Join-Path $script:RepoRoot "Tasks/Logs/.orchestrator-executor-$PID") -Raw } elseif ($env:OC_EXECUTOR) { $env:OC_EXECUTOR } else { "local" }),
    [ValidateRange(1, 360)]
    [int]$MaxIterations = 20,
    [ValidateRange(1, 120)]
    [int]$SubprocessTimeoutMinutes = 30,
    [ValidateRange(1, 20)]
    [int]$CodeParallelCount = 3,
    [ValidateRange(1, 20)]
    [int]$ReviewerParallelCount = 6,
    [ValidateRange(10, 600)]
    [int]$PollIntervalSeconds = 300,
    [ValidateRange(0, 1440)]
    [int]$MaxRuntimeMinutes = 0,
    [switch]$NoAuditPrompt,
    [switch]$Detach,
    [switch]$Resume,
    [ValidateRange(1, 100)]
    [int]$InstanceId = 1,
    [ValidateSet('Subprocess', 'Container')]
    [string]$SpawnMode = "Subprocess",
    [ValidateRange(1, 480)]
    [int]$IdleTimeoutMinutes = 30,
    [ValidateRange(0, 10)]
    [int]$ModuleCount = 1
)

function Wait-PokeOrSeconds {
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir,
        [Parameter(Mandatory)]
        [int]$Seconds
    )
    $pokeFile = Join-Path $RepoDir 'Tasks/Logs/.orchestrator-poke'
    for ($s = 0; $s -lt $Seconds; $s++) {
        if (Test-Path $pokeFile) {
            Remove-Item $pokeFile -Force -ErrorAction SilentlyContinue
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# ─── Outer init guard — catches startup failures that happen before the main loop ──
try {

# ─── Compute project root early (used by Write-OrchestratorLog, mutex, etc.) ──
$RepoDir = $script:RepoRoot
$script:SkillsRoot = Get-SkillsRoot -RepoRoot $RepoDir

# ─── Set up logging environment before any code that might log ─────────────────
if (-not $env:INTERCLAW_SETUP_LOG) {
    $env:INTERCLAW_RUN_ID = "instance-$InstanceId"
    $setupLogDir = "$RepoDir/Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $setupLogDir -Force
    $env:INTERCLAW_SETUP_LOG = Join-Path $setupLogDir "orchestrator-$PID.log"
}
$script:orchLogPath = $env:INTERCLAW_SETUP_LOG
$script:orchRunId   = $env:INTERCLAW_RUN_ID

# ─── Named mutex — single-instance enforcement ──────────────────────────
$script:OrchMutex = $null
$mutexNames = @(
    "Global\InterclawOrchestrator-Instance$InstanceId",
    "Local\InterclawOrchestrator-Instance$InstanceId",
    "InterclawOrchestrator-Instance$InstanceId"
)
$mutexAcquired = $false
foreach ($mutexName in $mutexNames) {
    try {
        $script:OrchMutex = New-Object System.Threading.Mutex($false, $mutexName)
        $acquired = $script:OrchMutex.WaitOne(0)
        if ($acquired) {
            $mutexAcquired = $true
            Write-OrchestratorLogSafe "MUTEX_ACQUIRED name='$mutexName'" -Level INFO
            break
        }
        $orchPidFile = Join-Path $RepoDir "Tasks/Logs/.orchestrator-$InstanceId-pid"
        Write-Host "Another orchestrator is already running (PID $(Get-Content $orchPidFile -ErrorAction SilentlyContinue)) — exiting" -ForegroundColor Red
        exit 1
    } catch [System.Threading.AbandonedMutexException] {
        # Abandoned mutex from crashed orchestrator — we now own it
        $mutexAcquired = $true
        Write-OrchestratorLogSafe "MUTEX_ABANDONED_RECOVERED name='$mutexName'" -Level WARN
        break
    } catch {
        Write-OrchestratorLogSafe "MUTEX_CREATE_FAILED name='$mutexName' error='$($_.Exception.Message)'" -Level WARN
    }
}
if (-not $mutexAcquired) {
    Write-OrchestratorLogSafe "ALL_MUTEX_NAMES_FAILED" -Level WARN
}

trap {
    $exceptionMessage = $_.Exception.Message
    $errorStackTrace = $_.ScriptStackTrace
    $exceptionType = $_.Exception.GetType().Name
    try {
        Write-OrchestratorLogSafe "ORCHESTRATOR_FATAL_CRASH type='$exceptionType' message='$($exceptionMessage -replace "'", "''")' stack='$($errorStackTrace -replace "'", "''")'" -Level ERROR
        $initErrPath = Join-Path $RepoDir "Tasks/Logs/.orchestrator-init-error"
        "$exceptionType`: $exceptionMessage`n$errorStackTrace" | Out-File $initErrPath -Encoding utf8 -Force
    } catch {
        $trapCatchMsg = $_.Exception.Message
        try { Write-OrchestratorLogSafe "TRAP_LOG_WRITE_FAILED error='$($trapCatchMsg -replace "'", "''")'" -Level WARN } catch { Write-OrchestratorLogSafe "TRAP_LOG_CATASTROPHIC_FAILURE - unable to log trap error" -Level ERROR }
    }
    try { Write-OrchestratorExitMarker -RepoDir $RepoDir -ExitKind 'fatal-crash' } catch { Write-OrchestratorLogSafe "EXIT_MARKER_WRITE_FAILED error='$($_.Exception.Message -replace "'", "''")'" -Level WARN }
    return
}

$null = Register-EngineEvent -SourceIdentifier "SalmonRun.OrchFatalExit_$PID" -Action {
    try {
        $logPath = $script:orchLogPath
        if ($logPath) {
            $entry = "{`"timestamp`":`"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`",`"level`":`"ERROR`",`"agent`":`"orchestrator`",`"phase`":`"orchestrator`",`"message`":`"ORCHESTRATOR_EXIT_UNEXPECTED`",`"runId`":`"$env:INTERCLAW_RUN_ID`"}"
            Add-Content -Path $logPath -Value $entry -Encoding utf8 -ErrorAction SilentlyContinue
        }
    } catch { Write-OrchestratorLog "ENGINE_EVENT_ACTION_FAILED error='$($_.Exception.Message -replace "'", "''")'" -Level WARN }
} -SupportEvent -ErrorAction SilentlyContinue

# ─── Reservation manifest path — maps each spawned slot to a pre-assigned file
$script:ReservationsPath = Join-Path $RepoDir "Tasks/Logs/.reservations.json"

# Module dependencies are handled by the .psd1 RequiredModules
$script:moduleLoaded = $true

# Resolve harness, provider, model, effort before loading the executor
$script:HarnessConfig = Resolve-HarnessConfig -Harness $Harness -Provider $Provider -Model $Model -Effort $Effort -LegacyExecutor $Executor
$script:DefaultHarnessConfig = $script:HarnessConfig
Write-OrchestratorLogSafe "HARNESS_RESOLVED harness=$($script:HarnessConfig.Harness) provider=$($script:HarnessConfig.Provider) model=$($script:HarnessConfig.Model) effort=$($script:HarnessConfig.Effort) executor=$($script:HarnessConfig.ExecutorFile)"

# Load the executor
$executorScript = Join-Path $script:ModuleRoot "Executors\$($script:HarnessConfig.ExecutorFile).ps1"
if (Test-Path $executorScript) {
    . $executorScript
} else {
    throw "Executor script not found: $executorScript"
}
if (Test-Path "Function:\Initialize-Executor") {
    $script:AgentPath = Initialize-Executor
} else {
    $script:AgentPath = $null
}
$script:ExecutorProfiles = @{}
$script:ExecutorProfiles["$($script:HarnessConfig.Harness)|$($script:HarnessConfig.Provider)|$($script:HarnessConfig.Model)|$($script:HarnessConfig.Effort)"] = $script:AgentPath
$script:LoadedExecutorFile = $script:HarnessConfig.ExecutorFile

function Use-PlanExecutorProfile {
    param($Config, [switch]$Initialize)
    # Streams recovered from an older orchestrator process have no persisted
    # profile. Preserve backward compatibility by treating them as run-default.
    if (-not $Config) { $Config = $script:DefaultHarnessConfig }
    $key = "$($Config.Harness)|$($Config.Provider)|$($Config.Model)|$($Config.Effort)"
    $script:HarnessConfig = $Config
    if ($script:LoadedExecutorFile -ne $Config.ExecutorFile) {
        $profileExecutor = Join-Path $script:ModuleRoot "Executors\$($Config.ExecutorFile).ps1"
        if (-not (Test-Path -LiteralPath $profileExecutor)) { throw "Executor script not found: $profileExecutor" }
        . $profileExecutor
        $script:LoadedExecutorFile = $Config.ExecutorFile
    }
    if ($Initialize -and -not $script:ExecutorProfiles.ContainsKey($key)) {
        if (-not (Test-Path "Function:\Initialize-Executor")) { throw "Executor '$($Config.ExecutorFile)' does not implement Initialize-Executor" }
        $script:ExecutorProfiles[$key] = Initialize-Executor
    }
    return $script:ExecutorProfiles[$key]
}
$script:executorDisconnectOnExit = $true
# Safe discard: Register-EngineEvent returns a PSEventSubscriber; the registration side-effect is what matters and errors inside the action are already caught/logged.
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { if (Test-Path "Function:\Disconnect-Executor") { Disconnect-Executor } } catch { Write-OrchestratorLog "DISCONNECT_EXECUTOR_ON_EXIT_FAILED error='$($_.Exception.Message -replace "'", "''")'" -Level WARN }
}

# ─── Initialize spawned-PID registry ─────────────────────────────────
# Shared across all orchestrator processes — only PIDs in this registry
# may be killed by Stop-ProcessTree.
$script:RegistryPath = Join-Path $RepoDir "Tasks/Logs/agents/.spawned-pids.json"
Initialize-SpawnedPidRegistry -RegistryPath $script:RegistryPath

# Wrapper script for detach re-launch
$wrapperScript = Join-Path $RepoDir "Orchestrator/Orchestration/LocalOrchestrator.ps1"
if (-not (Test-Path -LiteralPath $wrapperScript -PathType Leaf)) {
    throw "Canonical orchestrator wrapper not found: $wrapperScript"
}

# ─── Detached-orchestrator detection ─────────────────────────────────────────
$script:orchParentProc = $null
try {
    $pPid = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
    $script:orchParentProc = Get-Process -Id $pPid -ErrorAction SilentlyContinue
} catch {
    Write-OrchestratorLog "PARENT_PROC_QUERY_FAILED error='$($_.Exception.Message)'" -Level WARN
}
if (-not $Detach -and -not $env:OC_ORCHESTRATOR_BACKGROUND -and $script:orchParentProc -and $script:orchParentProc.ProcessName -match 'opencode') {
    Write-Host "  ⚡ Launched by opencode agent — entering detached mode" -ForegroundColor Yellow
    $Detach = $true
}

# ─── Detach mode ──────────────────────────────────────────────────────────────
if ($Detach -and -not $env:OC_ORCHESTRATOR_BACKGROUND) {
    $logDir = "$RepoDir/Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $pwsh = Get-Command pwsh.exe | Select-Object -ExpandProperty Source

    $scriptArgList = @(
        "-Harness", "$($script:HarnessConfig.Harness)",
        "-Provider", "$($script:HarnessConfig.Provider)",
        "-Model", "$($script:HarnessConfig.Model)",
        "-Effort", "$($script:HarnessConfig.Effort)",
        "-Executor", "$Executor",
        "-MaxIterations", "$MaxIterations",
        "-SubprocessTimeoutMinutes", "$SubprocessTimeoutMinutes",
        "-CodeParallelCount", "$CodeParallelCount",
        "-ReviewerParallelCount", "$ReviewerParallelCount",
        "-PollIntervalSeconds", "$PollIntervalSeconds",
        "-MaxRuntimeMinutes", "$MaxRuntimeMinutes",
        "-InstanceId", "$InstanceId",
        "-SpawnMode", "$SpawnMode",
        "-IdleTimeoutMinutes", "$IdleTimeoutMinutes",
        "-ModuleCount", "$ModuleCount"
    )
    if ($NoAuditPrompt) { $scriptArgList += "-NoAuditPrompt" }
    if ($Resume) { $scriptArgList += "-Resume" }
    $scriptArgsJoined = ($scriptArgList | ForEach-Object {
        if ($_ -match '[\s"&|<>()@^!;]') { "'$_'" } else { $_ }
    }) -join ' '

    $scriptCmd = "`$env:OC_ORCHESTRATOR_BACKGROUND='1'; " +
        "`$logDir = '$logDir'; " +
        "`$null = New-Item -ItemType Directory -Path `$logDir -Force; " +
        "`$logFile = Join-Path `$logDir ""orchestrator-`$PID.log""; " +
        "`$structuredLogFile = Join-Path `$logDir ""orchestrator-`$PID-structured.log""; " +
        "'# ORCHESTRATOR RUN RECORD' | Out-File -FilePath `$logFile -Encoding utf8; " +
        "'# PID: ' + `$PID | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# InstanceId: $InstanceId' | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# Serial dispatch' | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# StartTime: ' + (Get-Date -Format 'o') | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# Args: $scriptArgsJoined' | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# User: ' + `$env:USERNAME | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# Hostname: ' + `$env:COMPUTERNAME | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# Version: 2' | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# ---' | Out-File -FilePath `$logFile -Encoding utf8 -Append; " +
        "'# ---' | Out-File -FilePath `$structuredLogFile -Encoding utf8; " +
        "`$env:INTERCLAW_SETUP_LOG = `$structuredLogFile; `$env:INTERCLAW_RUN_ID = 'instance-$InstanceId'; " +
        "& '$wrapperScript' $scriptArgsJoined *>&1 | Out-File -FilePath `$logFile -Encoding utf8 -Append"

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptCmd)
    $encodedCmd = [Convert]::ToBase64String($bytes)
    $proc = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $encodedCmd) -WorkingDirectory $RepoDir -WindowStyle Hidden -PassThru
    Register-SpawnedPid -ProcessId $proc.Id -AgentId "orchestrator-detached-$InstanceId"

    Write-Host "  ✓ Orchestrator detached (PID $($proc.Id))" -ForegroundColor Green
    Write-Host "  Log:  $logDir\orchestrator-$($proc.Id).log" -ForegroundColor DarkGray
    Write-Host "  Structured: $logDir\orchestrator-$($proc.Id)-structured.log" -ForegroundColor DarkGray
    Write-OrchestratorExitMarker -RepoDir $RepoDir -ExitKind 'detach-wrapper'
exit 0
}

# ─── Register-OrphanedAgent ─────────────────────────────────────────────────
function Register-OrphanedAgent {
    param([string]$WorkingDir)
    $adopted = 0
    if (-not (Test-Path $WorkingDir)) { return $adopted }
    $workingFiles = @(Get-ChildItem "$WorkingDir\*.md" -ErrorAction SilentlyContinue)
    $streamDirs = @(Get-ChildItem "$WorkingDir\stream-*" -Directory -ErrorAction SilentlyContinue)
    foreach ($sd in $streamDirs) {
        $workingFiles += @(Get-ChildItem "$($sd.FullName)\*.md" -ErrorAction SilentlyContinue)
    }
    foreach ($f in $workingFiles) {
        try {
            $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            $agentMatch  = [regex]::Match($content, '- Agent: (\S+)')
            $orchMatch   = [regex]::Match($content, '- Orchestrated: (\S+)')
            $orchPidMatch = [regex]::Match($content, '- OrchestratorPID: (\S+)')
            $orchIdMatch = [regex]::Match($content, '- OrchestratorId: (\S+)')
            if (-not $agentMatch.Success -or -not $orchMatch.Success) { continue }
            if ($orchMatch.Groups[1].Value -ne 'true') { continue }
            $agentId = $agentMatch.Groups[1].Value
            $orchPid = if ($orchPidMatch.Success) { [int]::Parse($orchPidMatch.Groups[1].Value) } else { $null }
            if ($script:orphanStreams.ContainsKey($agentId)) { continue }
            $pidFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$agentId.pid"
            $agentPid = $null
            if (Test-Path $pidFile) {
                $rawPid = Get-Content $pidFile -Raw -ErrorAction SilentlyContinue
                if ($rawPid) { $agentPid = $rawPid.Trim() }
            }
            $agentAlive = $agentPid -and (Get-Process -Id ([int]$agentPid) -ErrorAction SilentlyContinue)
            if (-not $agentAlive) { continue }
            if ($orchPid) {
                $orchAlive = Get-Process -Id $orchPid -ErrorAction SilentlyContinue
                if ($orchAlive) { continue }
            }
            $ns = Get-FileNamespace -FileName $f.Name
            if (-not $ns) { $ns = "orphan-$($f.BaseName)" }
            $script:orphanStreams[$agentId] = @{
                AgentId        = $agentId
                Namespace      = $ns
                FilePath       = $f.FullName
                AdoptedAt      = Get-Date
                OrchestratorId = if ($orchIdMatch.Success) { $orchIdMatch.Groups[1].Value } else { "unknown" }
            }
            $script:busyNamespaces[$ns] = $true
            Write-OrchestratorLog "ORPHAN_ADOPTED agent=$agentId ns=$ns orchPid=$orchPid file=$($f.Name)"
            $adopted++
        } catch {
            Write-OrchestratorLog "ORPHAN_ADOPT_SCAN_ERROR file=$($f.Name) error='$($_.Exception.Message)'" -Level WARN
        }
    }
    if ($adopted -gt 0) {
        Write-Host "  Adopted $adopted orphaned agent(s) — their namespaces are blocked from dispatch" -ForegroundColor Cyan
    }
    return $adopted
}

# ─── Dispatch-rename commit (orchestrator-tooling-3) ─────────────────────────
# Commits the dispatch move (Tasks/Code|Review → Tasks/Working/<lane>/) immediately
# so a concurrent merge-phase `git checkout main` / `git pull --rebase` cannot
# restore the tracked source copy over the in-flight lane copy. Best-effort:
# a commit failure must never block dispatch.
function Invoke-DispatchRenameCommit {
    param([string]$RepoDir, [string]$StreamDir, [string]$StreamId, [string]$Role, [string]$Namespace)
    try {
        $laneFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue)
        if ($laneFiles.Count -eq 0) { return }
        $stageArgs = @()
        foreach ($lf in $laneFiles) {
            $rel = [System.IO.Path]::GetRelativePath($RepoDir, $lf.FullName).Replace('\\', '/')
            $stageArgs += $rel
        }
        git -C $RepoDir add -- $stageArgs 2>$null | Out-Null
        # Stage the source deletions (Tasks/Code + Tasks/Review) for these exact
        # basenames so pull --rebase cannot resurrect the stale originals.
        foreach ($lf in $laneFiles) {
            foreach ($srcDir in @('Tasks/Code', 'Tasks/Review')) {
                $srcRel = "$srcDir/$($lf.Name)"
                if (-not (Test-Path (Join-Path $RepoDir ($srcRel -replace '/', '\')))) {
                    git -C $RepoDir add -- $srcRel 2>$null | Out-Null
                }
            }
        }
        $stagedCount = @(git -C $RepoDir diff --cached --name-only 2>$null | Where-Object { $_ }).Count
        if ($stagedCount -gt 0) {
            git -C $RepoDir commit -m "chore(stream): dispatch $Namespace to $StreamId ($($laneFiles.Count) plan file(s))" --no-verify 2>&1 | Out-Null
            Write-OrchestratorLog "DISPATCH_RENAME_COMMITTED lane=$StreamId ns=$Namespace files=$($laneFiles.Count) staged=$stagedCount"
        }
    } catch {
        Write-OrchestratorLog "DISPATCH_RENAME_COMMIT_FAILED lane=$StreamId ns=$Namespace error='$($_.Exception.Message)'" -Level WARN
    }
}

# ─── Resume mode ─────────────────────────────────────────────────────────────
if ($Resume) {
    Write-Host "╔══ Resume mode ──╗" -ForegroundColor Cyan
    Write-Host "║  Rescuing orphaned locks in Working/..." -ForegroundColor DarkGray
    Write-Host "╚═════════════════╝" -ForegroundColor Cyan
    Restore-OrphanedLock -RepoDir $RepoDir
}

# ─── Main loop ────────────────────────────────────────────────────────────────
Write-Host "╔══ LocalOrchestrator ──╗" -ForegroundColor Cyan
Write-Host "║  Max stall iterations: $MaxIterations" -ForegroundColor DarkGray
Write-Host "║  Subprocess timeout: ${SubprocessTimeoutMinutes}m" -ForegroundColor DarkGray
Write-Host "║  Poll interval: ${PollIntervalSeconds}s" -ForegroundColor DarkGray
Write-Host "║  Max runtime: $(if ($MaxRuntimeMinutes -gt 0) { "$($MaxRuntimeMinutes)m" } else { 'unlimited' })" -ForegroundColor DarkGray
Write-Host "║  Parallel: $CodeParallelCount coders, $ReviewerParallelCount reviewers" -ForegroundColor DarkGray
Write-Host "║  Spawn mode: $SpawnMode" -ForegroundColor DarkGray
Write-Host "║  Harness: $($script:HarnessConfig.Harness)" -ForegroundColor DarkGray
Write-Host "║  Provider: $($script:HarnessConfig.Provider)" -ForegroundColor DarkGray
Write-Host "║  Model: $($script:HarnessConfig.Model)" -ForegroundColor DarkGray
Write-Host "║  Effort: $($script:HarnessConfig.Effort)" -ForegroundColor DarkGray
Write-Host "╚═══════════════════════╝" -ForegroundColor Cyan
$orchModeLabel = if ($env:OC_ORCHESTRATOR_BACKGROUND) { "detached" } else { "terminal" }
$orchLaunchCtx = if ($script:orchParentProc -and $script:orchParentProc.ProcessName -match 'opencode') { "opencode-parent" } else { "terminal" }
Write-Host "  PID: $PID   Mode: $orchModeLabel   Launch: $orchLaunchCtx   Log: $env:INTERCLAW_SETUP_LOG" -ForegroundColor DarkGray
Write-OrchestratorLog "ORCHESTRATOR_START pid=$PID mode=$orchModeLabel launch=$orchLaunchCtx instance=$InstanceId parallel=$CodeParallelCount max_iterations=$MaxIterations harness=$($script:HarnessConfig.Harness) provider=$($script:HarnessConfig.Provider) model=$($script:HarnessConfig.Model) effort=$($script:HarnessConfig.Effort) executor=$($script:HarnessConfig.ExecutorFile)"

Get-ChildItem "$RepoDir/Tasks/Logs/orchestrator-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -ErrorAction SilentlyContinue

# Clean structured logs from dead orchestrator instances — prevents stale
# STREAM_CRASHED entries from triggering false RunFix error detection
Get-ChildItem "$RepoDir/Tasks/Logs/orchestrator-*-structured.log" -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.Name -match 'orchestrator-(\d+)-structured\.log$') {
            $pidNum = [int]$Matches[1]
            if ($pidNum -ne $PID -and -not (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "STRUCTURED_LOG_CLEANED pid=$pidNum file='$($_.Name)'"
            }
        }
    }

$pidLockFile = Join-Path $RepoDir "Tasks/Logs/.orchestrator-$InstanceId-pid"
$lockAcquired = Initialize-OrchestratorPidLock -PidLockFile $pidLockFile -InstanceId $InstanceId
if (-not $lockAcquired) { exit 1 }

$heartbeatFile = Join-Path $RepoDir "Tasks/Logs/.orchestrator-heartbeat"
Invoke-OrchestratorStartupRescue -RepoDir $RepoDir -HeartbeatFile $heartbeatFile -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes

$null = Clear-StaleOrchestratorFiles -RepoDir $RepoDir -InstanceId $InstanceId -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes

# Prune stale git worktrees that could block new-stream worktree creation
try {
    $wtDir = Join-Path $RepoDir "Tasks/worktrees"
    if (Test-Path $wtDir) {
        $errGitPrune1 = $null
        # Safe discard: git stdout is informational; stderr error records are captured into $errGitPrune1 and logged below.
        git -C $RepoDir worktree prune 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $errGitPrune1 += "$_`n"; $null } else { $_ }
        } | Out-Null
        if ($errGitPrune1) { Write-OrchestratorLog "WORKTREE_PRUNE_STDERR error='$($errGitPrune1.Trim())'" -Level WARN }
        # Module worktrees are persistent shared infrastructure (3 coder lanes
        # plus 1 reviewer lane). Only transient per-stream worktrees belong in
        # this startup cleanup; deleting module-1 here converts a registered
        # worktree into a plain directory before New-WorktreeModule can resume.
        . (Join-Path $script:SkillsRoot "Git/Invoke-WorktreeSetup.ps1")
        $registeredWorktrees = @{}
        foreach ($registered in @(Get-ExistingWorktrees)) {
            if ($registered.BranchName -match '^wt/module-\d+$') {
                continue
            }
            $registeredWorktrees[(Get-WorktreePathKey -Path $registered.WorktreePath)] = $registered
        }
        # A prior failed setup can leave Tasks/Worktrees/module-N as an
        # ordinary directory. It must not be passed to New-AgentWorktree as if
        # it were registered: preserve the directory under a timestamped
        # quarantine name, then let the normal module creation path recreate a
        # real git worktree at the canonical location.
        Get-ChildItem "$wtDir\*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^module-\d+$' -and -not (Test-Path (Join-Path $_.FullName '.git')) } |
            ForEach-Object {
                $moduleBranch = "wt/$($_.Name)"
                $registeredModule = @(Get-ExistingWorktrees | Where-Object { $_.BranchName -eq $moduleBranch })
                if ($registeredModule.Count -eq 0) {
                    $quarantineName = "$($_.Name)-quarantine-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                    $quarantinePath = Join-Path $wtDir $quarantineName
                    try {
                        Move-Item -LiteralPath $_.FullName -Destination $quarantinePath -ErrorAction Stop
                        Write-OrchestratorLog "WORKTREE_MODULE_QUARANTINED dir='$($_.FullName)' quarantine='$quarantinePath' reason=unregistered-ordinary-directory" -Level WARN
                    } catch {
                        Write-OrchestratorLog "WORKTREE_MODULE_QUARANTINE_FAILED dir='$($_.FullName)' error='$($_.Exception.Message)'" -Level ERROR
                    }
                }
            }
        Get-ChildItem "$wtDir\*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^module-\d+$') {
                Write-OrchestratorLog "WORKTREE_MODULE_PRESERVED dir='$($_.FullName)'"
            } else {
                $registered = $registeredWorktrees[(Get-WorktreePathKey -Path $_.FullName)]
                if ($null -ne $registered) {
                    $errGitRemove = $null
                    # Safe discard: git stdout is informational; stderr error records are captured into $errGitRemove and logged below.
                    git -C $RepoDir worktree remove $_.FullName 2>&1 | ForEach-Object {
                        if ($_ -is [System.Management.Automation.ErrorRecord]) { $errGitRemove += "$_`n"; $null } else { $_ }
                    } | Out-Null
                    if ($errGitRemove) { Write-OrchestratorLog "WORKTREE_REMOVE_STDERR dir='$($_.FullName)' error='$($errGitRemove.Trim())'" -Level WARN }
                }
                if (Test-Path $_.FullName) { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        $errGitPrune2 = $null
        # Safe discard: git stdout is informational; stderr error records are captured into $errGitPrune2 and logged below.
        git -C $RepoDir worktree prune 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $errGitPrune2 += "$_`n"; $null } else { $_ }
        } | Out-Null
        if ($errGitPrune2) { Write-OrchestratorLog "WORKTREE_PRUNE_STDERR error='$($errGitPrune2.Trim())'" -Level WARN }
    }
    Write-OrchestratorLog "WORKTREE_CLEANUP_COMPLETE"
} catch { Write-OrchestratorLog "WORKTREE_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }

try { Clear-StaleRetryBudgetEntries -RepoDir $RepoDir } catch { Write-OrchestratorLog "RETRY_BUDGET_GC_STARTUP_FAILED error='$($_.Exception.Message)'" -Level WARN }

$lockDir = Join-Path $RepoDir "Tasks" "Locks"
if (Test-Path $lockDir) {
    Get-ChildItem "$lockDir\*" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue
}

$tasksRoot = Join-Path $RepoDir "Tasks"
$workingDir = Join-Path $RepoDir "Tasks" "Working"
$null = New-Item -ItemType Directory -Path $workingDir -Force
$orphanStreams = Get-ChildItem "$tasksRoot\stream-*" -Directory -ErrorAction SilentlyContinue
foreach ($os in $orphanStreams) {
    $dest = Join-Path $workingDir $os.Name
    if (-not (Test-Path $dest)) {
        Write-OrchestratorLog "RESCUE_ORPHAN_STREAM dir=$($os.Name) src=$($os.FullName) dst=$dest"
        Move-Item -LiteralPath $os.FullName -Destination $dest -Force
    } else {
        Write-OrchestratorLog "RESCUE_ORPHAN_STREAM_MERGE dir=$($os.Name) src=$($os.FullName) dst=$dest"
        Get-ChildItem "$($os.FullName)\*" -ErrorAction SilentlyContinue | Move-Item -Destination $dest -Force
        Remove-Item $os.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path $workingDir) {
    Get-ChildItem "$workingDir\stream-*" -Directory -ErrorAction SilentlyContinue | Where-Object {
        @(Get-ChildItem "$($_.FullName)\*.md" -ErrorAction SilentlyContinue).Count -eq 0
    } | ForEach-Object {
        Write-OrchestratorLog "CLEANUP_EMPTY_STREAM dir=$($_.Name)"
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$null = Register-OrphanedAgent -WorkingDir $workingDir

$orchAgentId = "orchestrator-$InstanceId"
$orchMode = if ($env:OC_ORCHESTRATOR_BACKGROUND) { "detached" } else { "terminal" }
try {
    # Safe discard: Import-Module emits no pipeline output on success; module-missing is handled by the catch fallback below.
    $null = Import-Module SalmonRun.Core -ErrorAction SilentlyContinue
    Write-AgentPidFile -AgentId $orchAgentId
    Write-AgentHeartbeat -AgentId $orchAgentId
    Write-OrchestratorLog "AGENT_REGISTER agent=$orchAgentId pid=$PID mode=$orchMode"
} catch {
    $orchLogDir = Join-Path $RepoDir "Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $orchLogDir -Force
    $PID.ToString() | Out-File -FilePath (Join-Path $orchLogDir "$orchAgentId.pid") -Encoding utf8 -NoNewline
    [datetime]::UtcNow.ToString('o') | Out-File -FilePath (Join-Path $orchLogDir "$orchAgentId.heartbeat") -Encoding utf8 -NoNewline
    $orchMode | Out-File -FilePath (Join-Path $orchLogDir "$orchAgentId.mode") -Encoding utf8 -NoNewline
    Write-OrchestratorLog "AGENT_REGISTER_FALLBACK agent=$orchAgentId pid=$PID mode=$orchMode"
}
if ($?) {
    $orchLogDir = Join-Path $RepoDir "Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $orchLogDir -Force
    $orchMode | Out-File -FilePath (Join-Path $orchLogDir "$orchAgentId.mode") -Encoding utf8 -NoNewline
}

$previousCounts = $null
$stallCount = 0
$script:activeStreams = @{}
$script:orphanStreams = @{}
$script:busyNamespaces = @{}
$script:lastRole = "reviewer"
$script:usedNamespaces = @{}
$script:streamCrashHistory = [System.Collections.Generic.List[datetime]]::new()
$script:worktreeBranches = [System.Collections.Generic.List[string]]::new()
$script:worktreeModules = @()
$script:useWorktrees = $false
$exitKind = "unknown"
$sessionStart = Get-Date
$sessionStart.ToString('o') | Out-File (Join-Path $RepoDir "Tasks/Logs/session-start-orchestrator-$InstanceId.log") -Encoding utf8 -Force
$totalProcessed = 0
$totalCrashed = 0
$script:softStopDispatched = $false
$script:drainWaitExit = $false
$orchStartTime = Get-Date

Write-OrchestratorLog "ORCHESTRATOR_START InstanceId=$InstanceId PID=$PID parallel=$CodeParallelCount"
Write-FleetStatusTable

if ($SpawnMode -eq "Container") {
    $container = Get-AvailableContainerAgent
    if (-not $container) {
        Write-Host "  ⚠ No running container agents found — check: docker ps | Select-String mcp_opencode" -ForegroundColor Red
        Write-OrchestratorLog "CONTAINER_MODE_NO_AGENTS startup=true" -Level WARN
    }
} else {
    # Executor Initialize-Executor already produced the agent path; use it for dispatch.
    $agentPath = $script:AgentPath
}
} catch {
    $orchInitErrMsg = "Startup failure at pre-loop init: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-Host "[FATAL] $orchInitErrMsg" -ForegroundColor Red
    $moduleRoot = $script:ModuleRoot
    if ($moduleRoot) {
        $interclawRoot = $script:RepoRoot
        $initErrFile = Join-Path $interclawRoot "Tasks/Logs/.orchestrator-init-error"
        $null = New-Item -ItemType Directory -Path (Split-Path $initErrFile -Parent) -Force
        $orchInitErrMsg | Out-File $initErrFile -Encoding utf8
    }
    exit 1
}

try {
    # Determine effective parallelism based on worktree mode
    if ($ModuleCount -gt 0) {
        # Worktree modules: main tree + $ModuleCount worktree modules, scaled from parameters
        $mainCoder = [math]::Max(1, $CodeParallelCount - ($ModuleCount * 3))
        $mainReviewer = [math]::Max(1, $ReviewerParallelCount - $ModuleCount)
        $moduleCoder = 3; $moduleReviewer = 1
        $effectiveCoder = $mainCoder + ($ModuleCount * $moduleCoder)
        $effectiveReviewer = $mainReviewer + ($ModuleCount * $moduleReviewer)
        Write-OrchestratorLog "WORKTREE_MODE moduleCount=$ModuleCount totalCoder=$effectiveCoder totalReviewer=$effectiveReviewer"
    } else {
        # Without worktrees: shared tree, cap at 4 total
        $mainCoder = [math]::Min($CodeParallelCount, 3)
        $mainReviewer = [math]::Min($ReviewerParallelCount, 1)
        if ($mainCoder + $mainReviewer -gt 4) { $mainCoder = 3; $mainReviewer = 1 }
        $effectiveCoder = $mainCoder
        $effectiveReviewer = $mainReviewer
        Write-OrchestratorLog "WORKTREE_CAP moduleCount=0 coder=$mainCoder reviewer=$mainReviewer"
    }

    # Initialize main tree lanes
    $script:persistentLanes = Initialize-PersistentLanes -WorkingDir "$RepoDir/Tasks/Working" -CoderCount $mainCoder -ReviewerCount $mainReviewer
    Write-OrchestratorLog "LANES_INITIALIZED coder=$mainCoder reviewer=$mainReviewer lanes=$($script:persistentLanes.Count)"

    # Create worktree modules
    $script:worktreeModules = @()
    if ($ModuleCount -gt 0) {
        $script:useWorktrees = $true
        for ($m = 1; $m -le $ModuleCount; $m++) {
            $module = New-WorktreeModule -RepoDir $RepoDir -ModuleIndex $m -CoderCount 3 -ReviewerCount 1
            if ($module) {
                $script:worktreeModules += $module
                foreach ($ml in $module.Lanes) { $script:persistentLanes += $ml }
            }
        }
        Write-OrchestratorLog "WORKTREE_MODULES_CREATED count=$($script:worktreeModules.Count) totalLanes=$($script:persistentLanes.Count)"
    } else {
        $script:useWorktrees = $false
    }

    # Stall guard: MaxIterations now means the no-progress limit; the loop
    # runs indefinitely while work is being completed.
    $maxStall = $MaxIterations

    for ($i = 1; $true; $i++) {
    # Fix E: Circuit breaker — detect and break tight-loop spinning
    $now = Get-Date
    if (-not $script:iterationTimestamps) { $script:iterationTimestamps = [System.Collections.Generic.List[datetime]]::new() }
    $script:iterationTimestamps.Add($now)
    # Prune timestamps older than 60s
    $cutoff = $now.AddSeconds(-60)
    while ($script:iterationTimestamps.Count -gt 0 -and $script:iterationTimestamps[0] -lt $cutoff) {
        $script:iterationTimestamps.RemoveAt(0)
    }
    if ($script:iterationTimestamps.Count -gt 10) {
        Write-OrchestratorLog "SPIN_DETECTED iterations_in_60s=$($script:iterationTimestamps.Count) — forcing 30s cooldown sleep" -Level ERROR
        Write-Host "  ⚠ Spin detected — $($script:iterationTimestamps.Count) iterations in 60s — forcing cooldown" -ForegroundColor Red
        Start-Sleep -Seconds 30
        $script:iterationTimestamps.Clear()
    }
    Clear-IterationEnvironment -Iteration $i
    $script:iterationErrors = @()
    $counts = Get-TaskCounts
    Invoke-InterIterationStaleSweep -RepoDir $RepoDir
    Invoke-PeriodicCleanup -Iteration $i -RepoDir $RepoDir
    # Recover stuck lanes whose subprocesses crashed without completing
    try {
        $recoveredLanes = Invoke-LaneStateRecovery -RepoDir $RepoDir -Lanes $script:persistentLanes -ActiveStreams $script:activeStreams
        if ($recoveredLanes -gt 0) {
            $counts = Get-TaskCounts
        }
    } catch {
        Write-OrchestratorLog "LANE_RECOVERY_ERROR message='$($_.Exception.Message)'" -Level WARN
    }
    if ($i % 5 -eq 0 -and $script:streamCrashHistory.Count -gt 0) {
        $crashWindow = (Get-Date).AddSeconds(-300)
        $script:streamCrashHistory.RemoveAll({ param($t) $t -lt $crashWindow })
    }
    try { Write-AgentHeartbeat -AgentId "orchestrator-$InstanceId" } catch { Write-OrchestratorLog "HEARTBEAT_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN }
    Write-IterationStatus -Counts $counts -Iteration $i -MaxIterations $maxStall -TotalProcessed $totalProcessed -TotalCrashed $totalCrashed -SessionStart $sessionStart
    Write-OrchestratorLiveStatus -RepoDir $RepoDir -InstanceId $InstanceId -Counts $counts -ActiveStreams $script:activeStreams
    if ($SpawnMode -ne "Subprocess") {
        Write-Host "  Spawn mode: $SpawnMode" -ForegroundColor DarkGray
    }

    # Attempt to re-promote Manual plans whose dependencies are now satisfied
    $manualFiles = Get-ChildItem "$RepoDir/Tasks/Manual/*.md" -ErrorAction SilentlyContinue
    $completeNames = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $repaired = 0
    foreach ($mf in $manualFiles) {
        $content = Get-Content $mf.FullName -Raw -ErrorAction SilentlyContinue
        $depMatch = [regex]::Match($content, '^\*\*DependsOn\*\*:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($depMatch.Success) {
            $deps = [regex]::Matches($depMatch.Groups[1].Value, '([^,;]+?)(?:\s+\(status:\s*\w+\))?(?:[,;]|$)') |
                ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ }
            $missing = foreach ($dep in $deps) {
                $depName = if ($dep -match '\.md$') { $dep } else { "$dep.md" }
                $matched = $completeNames | Where-Object { $_ -eq $depName -or $_ -like "*$dep*" } | Select-Object -First 1
                if (-not $matched) { $dep }
            }
            if (-not $missing) {
                $target = Join-Path $RepoDir "Tasks/Code" $mf.Name
                Move-Item $mf.FullName $target -Force
                Write-OrchestratorLog "MANUAL_REPAIRED file='$($mf.Name)' reason='dependencies now satisfied'"
                $repaired++
            }
        }
    }
    if ($repaired -gt 0) {
        Write-OrchestratorLog "MANUAL_REPAIR_BATCH reintroduced=$repaired"
        $counts = Get-TaskCounts
    }

    Write-OrchestratorLog "DISPATCH coder_workload=$($counts.CoderWorkload) reviewer_workload=$($counts.ReviewerWorkload) activeStreams=$($script:activeStreams.Count)"

    $hasWork = ($counts.CoderWorkload + $counts.ReviewerWorkload - ($counts.Blocked ?? 0) -gt 0) -or ($script:activeStreams.Count -gt 0)
    if (-not $hasWork) {
        if (-not $idleStartTime) {
            $idleStartTime = Get-Date
            Write-Host "`n  All queues empty — waiting up to ${IdleTimeoutMinutes}m for new tasks" -ForegroundColor Yellow
            Write-OrchestratorLog "IDLE_START timeout=${IdleTimeoutMinutes}m"
        }
        $idleElapsed = ((Get-Date) - $idleStartTime).TotalMinutes
        if ($idleElapsed -ge $IdleTimeoutMinutes) {
            Write-Host "`n  Idle timeout (${IdleTimeoutMinutes}m) reached — exiting" -ForegroundColor Green
            Write-OrchestratorLog "IDLE_TIMEOUT reached elapsed=$([math]::Round($idleElapsed,1))m timeout=${IdleTimeoutMinutes}m"
            $exitKind = "idle-timeout"
            break
        }
        Write-OrchestratorLog "IDLE_WAITING elapsed=$([math]::Round($idleElapsed,1))m timeout=${IdleTimeoutMinutes}m"
        $stallCount = 0
    } elseif ($idleStartTime) {
        Write-Host "  Tasks arrived — resuming" -ForegroundColor Green
        Write-OrchestratorLog "IDLE_RESUMED elapsed=$([math]::Round(((Get-Date) - $idleStartTime).TotalMinutes,1))m"
        $idleStartTime = $null
    }

    $orchStopPath = Join-Path $RepoDir "Tasks/Logs/.orchestrator-stop"
    $agentStopSignals = @(
        (Join-Path $RepoDir "Tasks/stop.code"),
        (Join-Path $RepoDir "Tasks/stop.review"),
        (Join-Path $RepoDir "Tasks/stop")
    )
    $stopFound = Test-Path $orchStopPath
    if ($stopFound) { Remove-Item $orchStopPath -Force -ErrorAction SilentlyContinue }
    $agentSignalFound = $agentStopSignals | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($agentSignalFound) { $stopFound = $true }

    if ($stopFound) {
        Write-Host "  ⏹ Stop signal received — exiting" -ForegroundColor Yellow
        Write-OrchestratorLog "STOP_SIGNAL iteration=$i agentSignal=$($null -ne $agentSignalFound)"
        $exitKind = "stopped"
        break
    }

    if ($MaxRuntimeMinutes -gt 0) {
        $elapsedMinutes = ((Get-Date) - $orchStartTime).TotalMinutes
        if ($elapsedMinutes -ge $MaxRuntimeMinutes -and -not $script:softStopDispatched) {
            Write-Host "  ⏱ Max runtime (${MaxRuntimeMinutes}m) reached — entering drain mode" -ForegroundColor Yellow
            Write-OrchestratorLog "MAX_RUNTIME_REACHED elapsed=$([math]::Round($elapsedMinutes,1))m limit=${MaxRuntimeMinutes}m"
            $script:softStopDispatched = $true
        }
    }

    $softStopPath = Join-Path $RepoDir "Tasks/Logs/.orchestrator-soft-stop"
    if (-not $script:softStopDispatched -and (Test-Path $softStopPath)) {
        Remove-Item $softStopPath -Force -ErrorAction SilentlyContinue
        Write-Host "  ⏸ Soft-stop signal received — draining active streams" -ForegroundColor Yellow
        Write-OrchestratorLog "SOFT_STOP_SIGNAL iteration=$i"
        $script:softStopDispatched = $true
    }

    $stallResult = Invoke-StallDetection -Counts $counts -PreviousCounts $previousCounts -StallCount $stallCount -MaxStall $maxStall -Iteration $i -InstanceId $InstanceId
    if ($stallResult.StallLimitReached) {
        $exitKind = "stalled"
        $retryBudget = Get-FileRetryBudget
        $stuckNames = if ($retryBudget -and $retryBudget.PSObject.Properties) {
            @($retryBudget.PSObject.Properties | Where-Object { $_.Value.retries -ge 1 } | ForEach-Object { $_.Name })
        } else { @() }
        if ($stuckNames.Count -gt 0) {
            $stuckFiles = @(Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' -and $stuckNames -contains $_.Name }) +
                          @(Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' -and $stuckNames -contains $_.Name })
            if ($stuckFiles.Count -gt 0) {
                Write-Host "  ⚠ Stall limit reached — quarantining $($stuckFiles.Count) stuck file(s)" -ForegroundColor Red
                Write-OrchestratorLog "STALL_QUARANTINE count=$($stuckFiles.Count) files='$(($stuckFiles | ForEach-Object { $_.Name }) -join ',')'"
            }
            foreach ($f in $stuckFiles) {
                Invoke-QuarantineFile -FilePath $f.FullName -RepoDir $RepoDir -Reason "stall-limit-reached"
                $script:usedNamespaces.Remove($f.Name)
            }
        }
        break
    }
    $stallCount = $stallResult.NewStallCount

    $previousCounts = [PSCustomObject]@{
        RootCoder = $counts.RootCoder
        Review    = $counts.Review
        Working   = $counts.Working
    }

    if ($script:softStopDispatched) {
        if ($script:activeStreams.Count -gt 0) {
            $drainElapsed = ((Get-Date) - $orchStartTime).TotalMinutes
            if ($drainElapsed -ge $SubprocessTimeoutMinutes) {
                Write-Host "  ⏱ Drain timeout reached (${SubprocessTimeoutMinutes}m) — force-exiting with $($script:activeStreams.Count) streams still active" -ForegroundColor Yellow
                Write-OrchestratorLog "DRAIN_TIMEOUT elapsed=$([math]::Round($drainElapsed,1))m limit=${SubprocessTimeoutMinutes}m streams=$($script:activeStreams.Count)"
                $exitKind = "drain-timeout"
                break
            }
            Write-OrchestratorLog "DRAIN_MODE iteration=$i activeStreams=$($script:activeStreams.Count) - monitoring existing streams"
        } else {
            Write-Host "  All streams drained — exiting" -ForegroundColor Green
            $exitKind = "clean"
            break
        }
    }

    $fsState = Invoke-ReadFilesystemState -RepoDir $RepoDir -ExistingActiveStreams $script:activeStreams
    if ($fsState.activeStreams.Count -gt 0) {
        Write-Host "  → Recovered $($fsState.activeStreams.Count) stream(s) from filesystem state" -ForegroundColor Cyan
        foreach ($k in $fsState.activeStreams.Keys) {
            $script:activeStreams[$k] = $fsState.activeStreams[$k]
            Write-OrchestratorLog "FILESYSTEM_RECOVERED ns=$k"
        }
    }

    # Executor-specific preflight (opencode dispatch check, devin availability, etc.)
    if ($SpawnMode -eq "Subprocess" -and (Test-Path "Function:\Test-ExecutorPreflight")) {
        if (-not (Test-ExecutorPreflight -AgentPath $script:AgentPath)) {
            Write-Host "  ⚠ Stream dispatch unavailable — falling back to inline dispatch" -ForegroundColor Yellow
            $script:useWorktrees = ($env:ORCHESTRATOR_USE_WORKTREES -eq '1')
        }
    }

    # ── Pre-Phase-A: Flush usedNamespaces stale entries every iteration ──
    Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces
    Update-DependencyGapReport -RepoDir $RepoDir

    # ── Phase A: Full namespace scan ──
    if (-not $script:softStopDispatched) {
    try {
    $codeFiles = Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    $reviewFiles = Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    # Scheduled plans are scheduler-owned. Do not let them enter the generic
    # Code/Review pipeline, where they cannot be dispatched and would appear
    # as a permanent uncommitted queue item.
    $scheduledPlanRe = '(?im)^\*\*Type\*\*:\s*scheduled-task\b'
    $scheduledCode = 0; $scheduledReview = 0
    $codeFiles = $codeFiles | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match $scheduledPlanRe) { $scheduledCode++; $false } else { $true }
    }
    $reviewFiles = $reviewFiles | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match $scheduledPlanRe) { $scheduledReview++; $false } else { $true }
    }
    if ($scheduledCode -gt 0 -or $scheduledReview -gt 0) {
        Write-OrchestratorLog "DISPATCH_SCHEDULED_SKIPPED code=$scheduledCode review=$scheduledReview reason='scheduler-owned'"
    }

    # Skip plans explicitly marked **Status: blocked — their gate is closed.
    $blockRe = '(?m)^\*\*Status\*\*:\s*blocked\b'
    $blockedCode = 0; $blockedReview = 0
    $codeFiles = $codeFiles | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match $blockRe) { $blockedCode++; $false } else { $true }
    }
    $reviewFiles = $reviewFiles | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match $blockRe) { $blockedReview++; $false } else { $true }
    }
    if ($blockedCode -gt 0 -or $blockedReview -gt 0) {
        Write-OrchestratorLog "DISPATCH_BLOCKED skipped code=$blockedCode review=$blockedReview"
    }

    # ── Git-committed gate: only dispatch plans that are tracked, committed,
    #    and pushed. Untracked files (??) or modified-but-uncommitted files
    #    ( M) are skipped — they may be mid-write by a planner agent.
    #    This prevents the orchestrator from sweeping up plans before the
    #    project-plan re-review and git commit are complete.
    #    EXCEPTION: untracked (??) files that have a recognized plan header
    #    are auto-committed. These are plans that were recovered by
    #    lane-recovery after a stream crash — they exist on disk but are
    #    untracked because the worktree's dispatch commit deleted them from
    #    Code/ and the merge brought that deletion back. Without this
    #    auto-commit, the DISPATCH_UNCOMMITTED gate would skip them forever.
    $uncommittedCode = 0; $uncommittedReview = 0
    $autoCommitted = 0
    if ($codeFiles) {
        $codeFiles = $codeFiles | Where-Object {
            $rel = "Tasks/Code/$($_.Name)"
            # Terminal-state guard: skip plans already in a terminal queue
            if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "DISPATCH_SKIP_TERMINAL file='$($_.Name)' queue=Code reason=already_in_terminal_queue"
                $false
            } else {
                $status = git -C $RepoDir status --porcelain -- "$rel" 2>$null
                if ($status) {
                    if ($status.StartsWith('??')) {
                        # Untracked — check if it's a real plan file (has a plan header)
                        $fc = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                        if ($fc -and (Test-PlanHeaderContent -Content $fc)) {
                            # Auto-commit this recovered plan
                            git -C $RepoDir add -- "$rel" 2>$null
                            $autoCommitted++
                            $true  # treat as committable (will be committed below)
                        } else {
                            $uncommittedCode++; $false
                        }
                    } else {
                        $uncommittedCode++; $false
                    }
                } else { $true }
            }
        }
    }
    if ($reviewFiles) {
        $reviewFiles = $reviewFiles | Where-Object {
            $rel = "Tasks/Review/$($_.Name)"
            # Terminal-state guard: skip plans already in a terminal queue
            if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "DISPATCH_SKIP_TERMINAL file='$($_.Name)' queue=Review reason=already_in_terminal_queue"
                $false
            } else {
                $status = git -C $RepoDir status --porcelain -- "$rel" 2>$null
                if ($status) {
                    if ($status.StartsWith('??')) {
                        $fc = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                        if ($fc -and (Test-PlanHeaderContent -Content $fc)) {
                            git -C $RepoDir add -- "$rel" 2>$null
                            $autoCommitted++
                            $true
                        } else {
                            $uncommittedReview++; $false
                        }
                    } else {
                        $uncommittedReview++; $false
                    }
                } else { $true }
            }
        }
    }
    if ($autoCommitted -gt 0) {
        $commitMsg = "chore(orchestrator): auto-commit $autoCommitted recovered plan(s) for dispatch`n`nLane-recovery moved plan(s) back to Code/ or Review/ after a stream crash.`nAuto-committed so the DISPATCH_UNCOMMITTED gate can dispatch them.`n`nGenerated with [Devin](https://devin.ai)"
        try {
            git -C $RepoDir commit -m $commitMsg 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                git -C $RepoDir push 2>$null | Out-Null
                Write-OrchestratorLog "DISPATCH_AUTOCOMMIT count=$autoCommitted pushed=$($LASTEXITCODE -eq 0)"
            }
        } catch {
            Write-OrchestratorLog "DISPATCH_AUTOCOMMIT_FAILED error='$($_.Exception.Message)'" -Level WARN
        }
    }
    if ($uncommittedCode -gt 0 -or $uncommittedReview -gt 0) {
        Write-OrchestratorLog "DISPATCH_UNCOMMITTED skipped code=$uncommittedCode review=$uncommittedReview"

        # ── WIP auto-commit gate: if the same uncommitted Code/Review plans stay
        #    idle for several dispatch cycles, commit them as WIP so the queue
        #    can resume. This prevents stalls when an agent leaves a dirty worktree.
        $wipIdleThreshold = 3
        $wipStatePath = Join-Path $RepoDir 'Tasks/Logs/.orchestrator-wip-state.json'
        $wipState = if (Test-Path $wipStatePath) { try { Get-Content $wipStatePath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $null } } else { $null }
        if (-not $wipState) { $wipState = [PSCustomObject]@{ lastHash = ''; count = 0 } }

        $wipRelevant = git -C $RepoDir status --porcelain -- 'Tasks/Code/*.md' 'Tasks/Review/*.md' 2>$null |
            Where-Object { $_ -match '^( M|\?\?) ' }
        $wipHash = $wipRelevant -join "`n"

        if ($wipHash -and $wipHash -eq $wipState.lastHash) {
            $wipState.count = [int]$wipState.count + 1
        } else {
            $wipState.count = 1
            $wipState.lastHash = $wipHash
        }

        if ([int]$wipState.count -ge $wipIdleThreshold -and $wipHash) {
            $wipPaths = $wipRelevant | ForEach-Object { $_.Substring(3) }
            $wipToAdd = [System.Collections.Generic.List[string]]::new()
            foreach ($wipRel in $wipPaths) {
                $wipAbs = Join-Path $RepoDir $wipRel
                $wipContent = if (Test-Path $wipAbs) { Get-Content $wipAbs -Raw -ErrorAction SilentlyContinue } else { '' }
                if ($wipContent -notmatch '\*\*Type\*\*:\s*scheduled-task') {
                    $null = $wipToAdd.Add($wipRel)
                } else {
                    Write-OrchestratorLog "WIP_AUTOCOMMIT_SKIP rel=$wipRel reason='scheduled-task not eligible for Code/Review queue'"
                }
            }
            if ($wipToAdd.Count -gt 0) {
                git -C $RepoDir add -- @($wipToAdd) 2>$null | Out-Null
                $wipCommitMsg = "chore(orchestrator): WIP commit $($wipToAdd.Count) idle plan(s) after $($wipState.count) cycles`n`nUncommitted Code/Review plans were idle for $($wipState.count) cycles. Auto-committed so the ORCHESTRATOR can dispatch them.`n`nGenerated with [Devin](https://devin.ai)"
                git -C $RepoDir commit -m $wipCommitMsg 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    git -C $RepoDir push 2>$null | Out-Null
                    Write-OrchestratorLog "WIP_AUTOCOMMIT count=$($wipToAdd.Count) cycles=$($wipState.count) pushed=$($LASTEXITCODE -eq 0)"
                    $wipState.count = 0
                    $wipState.lastHash = ''
                } else {
                    Write-OrchestratorLog "WIP_AUTOCOMMIT_COMMIT_FAILED count=$($wipToAdd.Count)" -Level WARN
                }
            }
        }

        $wipState | ConvertTo-Json -Compress | Set-Content -Path $wipStatePath -Encoding utf8 -NoNewline
    } else {
        $wipStatePath = Join-Path $RepoDir 'Tasks/Logs/.orchestrator-wip-state.json'
        if (Test-Path $wipStatePath) { Remove-Item $wipStatePath -Force -ErrorAction SilentlyContinue }
    }

        $connascenceCandidates = @(
            (Join-Path $RepoDir "Orchestrator/Orchestration/Get-ConnascenceGroups.ps1"),
            (Join-Path $RepoDir "Skills/Orchestration/Get-ConnascenceGroups.ps1")
        )
        $connascenceScript = $connascenceCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        try {
            if (-not $connascenceScript) { throw "Connascence scanner not found in known locations" }
            Write-OrchestratorLog "CONNASCENCE_SCANNER_RESOLVED path='$connascenceScript'" -Level INFO
            $cgOutput = & $connascenceScript -RepoRoot $RepoDir -TaskDir (Join-Path $RepoDir 'Tasks/Code') -ModuleCount $ModuleCount -PassThru
            $cgResult = ($cgOutput | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-OrchestratorLog "CONNASCENCE_PARSE_FAILED path='$connascenceScript' error='$($_.Exception.Message)'" -Level WARN
            $cgResult = $null
        }
    $dependencyAnalysisValid = $null -ne $cgResult -and $cgResult.PSObject.Properties.Name -contains 'readySet'
    if ($cgResult -and -not $dependencyAnalysisValid) {
        Write-OrchestratorLog "CONNASCENCE_MISSING_READYSET" -Level WARN
        $cgResult = $null
    }
    # Keep this as a real array. PowerShell enumerates an empty HashSet returned
    # from an expression and assigns `$null`, which made the valid all-blocked
    # state crash at `.Contains()` instead of dispatching nothing.
    $readySet = if ($dependencyAnalysisValid) { @($cgResult.readySet) } else { $null }
    if ($cgResult -and $cgResult.cycleDetected) {
        Write-Host "  ⚠ Cycle detected in DependsOn graph: $($cgResult.cyclePath -join ' → ')" -ForegroundColor Red
        Write-OrchestratorLog "DAG_CYCLE_DETECTED path='$($cgResult.cyclePath -join ' → ')'"
        $broken = $false
        foreach ($__f in $cgResult.cyclePath) {
            $__filePath = Join-Path "$RepoDir/Tasks/Code" $__f
            if (Test-Path $__filePath) {
                $__content = Get-Content $__filePath -Raw -ErrorAction SilentlyContinue
                if ($__content -match '(?m)^\*\*DependsOn\*\*:') {
                    $__repaired = $__content -replace '(?m)^\*\*DependsOn\*\*:.*(\r?\n\s+\S+.*)*', ''
                    Set-Content $__filePath -Value $__repaired -Encoding utf8 -NoNewline
                    Write-OrchestratorLog "DAG_CYCLE_REPAIRED file=$__f action=removed-depends-on" -Level WARN
                    Write-Host "    ↪ Auto-repaired: removed DependsOn from $__f (cycle breaker)" -ForegroundColor Yellow
                    $broken = $true
                    break
                }
            }
        }
        if (-not $broken) {
            Write-Host "    ⚠ Cannot auto-repair cycle — quarantining all files in cycle" -ForegroundColor Red
            foreach ($__f in $cgResult.cyclePath) {
                $__filePath = Join-Path "$RepoDir/Tasks/Code" $__f
                if (Test-Path $__filePath) {
                    Invoke-QuarantineFile -FilePath $__filePath -RepoDir $RepoDir -Reason "dag-cycle"
                }
            }
        }
    }

    if ($dependencyAnalysisValid) {
        $codeFiles = @($codeFiles | Where-Object { $readySet -contains $_.Name })
        if ($readySet.Count -eq 0 -and $codeFiles.Count -eq 0) {
            Write-OrchestratorLog "DISPATCH_READY_SET_EMPTY role=coder action=dispatch-none"
        }
    } else {
        $codeFiles = @()
        Write-OrchestratorLog "DISPATCH_DEPENDENCY_ANALYSIS_UNAVAILABLE role=coder action=dispatch-none" -Level ERROR
    }

    # Get-ConnascenceGroups scans Tasks/Code only. Review plans have already
    # crossed the implementation dependency gate and must be governed by the
    # reviewer evidence gate below, not by the Code ready set.

    # Reviewer-dispatch gate (orchestrator-tooling-4): a plan in Tasks/Review must
    # carry implementation evidence — a **Lock** block with a non-empty Agent:,
    # Progress: 100%, and a **Validation** block with at least one populated item.
    # Otherwise it is unimplemented and belongs in Tasks/Code.
    $reviewFiles = @($reviewFiles | Where-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return $false }
        $hasLock = $content -match '\*\*Lock\*\*'
        $hasAgent = $content -match '(?m)^- Agent:\s*\S+'
        $has100 = $content -match 'Progress:\s*100%'
        $hasValidation = $content -match '\*\*Validation\*\*'
        $validationBlock = $null
        if ($hasValidation) {
            if ($content -match '(?ms)\*\*Validation\*\*(.*?)(?=---|^\*\*|\z)') { $validationBlock = $Matches[1] }
        }
        # A Validation item is "populated" when it is a checkbox tick ([x]) or a
        # key with a non-empty value (e.g. "- Tests: 10/10 passed").
        $hasPopulatedItem = $null -ne $validationBlock -and $validationBlock -match '(?m)^-\s+(?:\[[xX]\]|[^:\r\n]+:\s*\S)'
        $gatePass = $hasLock -and $hasAgent -and $has100 -and $hasPopulatedItem
        if (-not $gatePass) {
            $missing = @()
            if (-not $hasLock) { $missing += 'lock' }
            if (-not $hasAgent) { $missing += 'agent' }
            if (-not $has100) { $missing += '100%' }
            if (-not $hasValidation -or -not $hasPopulatedItem) { $missing += 'validation-populated' }
            $backToCode = Join-Path $RepoDir "Tasks/Code" $_.Name
            if (-not (Test-Path $backToCode)) {
                Move-Item $_.FullName $backToCode -Force
                Write-OrchestratorLog "REVIEWER_GATE_REJECTED file='$($_.Name)' reason='unimplemented; missing $($missing -join ', ')' dest=Code"
            }
            return $false
        }
        return $true
    })

    $fileModule = @{}
    if ($cgResult -and $cgResult.PSObject.Properties.Name -contains 'fileModules') {
        foreach ($prop in $cgResult.fileModules.PSObject.Properties) {
            $fileModule[$prop.Name] = $prop.Value
        }
    }

    $allCandidates = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $codeFiles) {
        $ns = Get-FileNamespace -FileName $f.Name
        $mod = if ($fileModule.ContainsKey($f.Name)) { $fileModule[$f.Name] } else { 'main' }
        $allCandidates.Add(@{ File = $f; Namespace = $ns; Role = "coder"; Module = $mod })
    }
    foreach ($f in $reviewFiles) {
        $ns = Get-FileNamespace -FileName $f.Name
        $mod = if ($fileModule.ContainsKey($f.Name)) { $fileModule[$f.Name] } else { 'main' }
        $allCandidates.Add(@{ File = $f; Namespace = $ns; Role = "reviewer"; Module = $mod })
    }

    $grouped = $allCandidates | Group-Object { "$($_.Namespace)|$($_.Role)|$($_.Module)" }
    $unassigned = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($g in $grouped) {
        $parts = $g.Name -split '\|'
        $ns = $parts[0]; $role = $parts[1]; $moduleId = $parts[2]
        $files = $g.Group | ForEach-Object { $_.File }
        $unused = $files | Where-Object { -not $script:usedNamespaces.ContainsKey($_.Name) }
        if ($unused) {
            $unassigned.Add(@{ Namespace = $ns; Role = $role; Module = $moduleId; Files = $unused })
        }
    }

    $coderGroups = $unassigned | Where-Object { $_.Role -eq "coder" }
    $reviewerGroups = $unassigned | Where-Object { $_.Role -eq "reviewer" }

    # Clean up zombie streams from activeStreams before counting capacity.
    # Streams whose process has exited but weren't removed by the normal
    # completion path inflate the active count and starve dispatch.
    $zombieKeys = @()
    foreach ($__ns in @($script:activeStreams.Keys)) {
        $__s = $script:activeStreams[$__ns]
        $__isZombie = $false
        if ($__s.Process) {
            try {
                if ($__s.Process.HasExited) { $__isZombie = $true }
                # Also check if the process ID no longer exists on the system
                elseif (-not (Get-Process -Id $__s.Process.Id -ErrorAction SilentlyContinue)) { $__isZombie = $true }
            } catch {
                $__isZombie = $true
            }
        } else {
            # No process handle (e.g. recovered from filesystem state) — check heartbeat/PID before treating as zombie.
            try {
                $alive = Test-AgentAlive -AgentId $__s.Id
                if (-not ($alive.ProcessAlive -or ($alive.HasHeartbeat -and -not $alive.HeartbeatStale))) {
                    $__isZombie = $true
                }
            } catch { $__isZombie = $true }
        }
        if ($__isZombie) { $zombieKeys += $__ns }
    }
    if ($zombieKeys.Count -gt 0) {
        Write-OrchestratorLog "ZOMBIE_CLEANUP removing=$($zombieKeys.Count) keys=$($zombieKeys -join ',')" -Level WARN
        foreach ($__k in $zombieKeys) { $script:activeStreams.Remove($__k) }
    }

    $activeCoder = @($script:activeStreams.Keys | Where-Object { $script:activeStreams[$_].Role -eq "coder" }).Count
    $activeReviewer = @($script:activeStreams.Keys | Where-Object { $script:activeStreams[$_].Role -eq "reviewer" }).Count

    $coderWorkload = $counts.CoderWorkload
    $reviewerWorkload = $counts.ReviewerWorkload

    # Get-DynamicCapacity treats CodeParallelCount as the TOTAL shared stream pool
    # (coders + reviewers combined). Pass effectiveCoder + effectiveReviewer so the
    # full lane capacity is used, not just the coder count.
    $totalLaneCapacity = $effectiveCoder + $effectiveReviewer
    Write-OrchestratorLog "CAPACITY_INPUT totalLaneCap=$totalLaneCapacity reviewerCap=$effectiveReviewer activeCoder=$activeCoder activeReviewer=$activeReviewer coderWork=$coderWorkload reviewerWork=$reviewerWorkload"
    $cap = Get-DynamicCapacity -CodeParallelCount $totalLaneCapacity -ReviewerParallelCount $effectiveReviewer `
        -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
        -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer
    Write-OrchestratorLog "CAPACITY_RESULT coder=$($cap.CapacityCoder) reviewer=$($cap.CapacityReviewer)"
    $capacityCoder = Get-CrashThrottleCapacity -CrashHistory $script:streamCrashHistory -DefaultCapacity $cap.CapacityCoder
    $capacityReviewer = Get-CrashThrottleCapacity -CrashHistory $script:streamCrashHistory -DefaultCapacity $cap.CapacityReviewer
    if ($capacityCoder -lt $cap.CapacityCoder -or $capacityReviewer -lt $cap.CapacityReviewer) {
        Write-OrchestratorLog "CRASH_THROTTLE coder=$capacityCoder/$($cap.CapacityCoder) reviewer=$capacityReviewer/$($cap.CapacityReviewer)" -Level WARN
    }

    $dispatchQueue = [System.Collections.Generic.List[hashtable]]::new()
    $coderDispatched = 0; $reviewerDispatched = 0
    foreach ($g in $coderGroups) {
        if ($coderDispatched -ge $capacityCoder) { break }
        $moduleId = $g.Module
        $ns = $g.Namespace
        $nsKey = "$moduleId|$ns|coder"
        if ($script:activeStreams.ContainsKey($nsKey)) { continue }
        if ($script:busyNamespaces.ContainsKey($nsKey)) {
            Write-OrchestratorLog "DISPATCH_SKIP_BUSY_NAMESPACE module=$moduleId ns=$ns role=coder reason=orphan-adoption"
            continue
        }
        $moduleLanes = $script:persistentLanes | Where-Object { $_.ModuleId -eq $moduleId }
        $freeLane = Get-FreeLane -Role "coder" -Lanes $moduleLanes
        if (-not $freeLane -and $moduleId -ne 'main') {
            Write-OrchestratorLog "DISPATCH_MODULE_FALLBACK module=$moduleId role=coder ns=$ns fallback=main"
            $freeLane = Get-FreeLane -Role "coder" -Lanes ($script:persistentLanes | Where-Object { $_.ModuleId -eq 'main' })
        }
        if (-not $freeLane) {
            Write-OrchestratorLog "DISPATCH_NO_FREE_LANE module=$moduleId role=coder ns=$ns"
            continue
        }
        $freeLane.Idle = $false
        $g.Lane = $freeLane
        $dispatchQueue.Add($g); $coderDispatched++
    }
    foreach ($g in $reviewerGroups) {
        if ($reviewerDispatched -ge $capacityReviewer) { break }
        $moduleId = $g.Module
        $ns = $g.Namespace
        $nsKey = "$moduleId|$ns|reviewer"
        if ($script:activeStreams.ContainsKey($nsKey)) { continue }
        if ($script:busyNamespaces.ContainsKey($nsKey)) {
            Write-OrchestratorLog "DISPATCH_SKIP_BUSY_NAMESPACE module=$moduleId ns=$ns role=reviewer reason=orphan-adoption"
            continue
        }
        $moduleLanes = $script:persistentLanes | Where-Object { $_.ModuleId -eq $moduleId }
        $freeLane = Get-FreeLane -Role "reviewer" -Lanes $moduleLanes
        if (-not $freeLane -and $moduleId -ne 'main') {
            Write-OrchestratorLog "DISPATCH_MODULE_FALLBACK module=$moduleId role=reviewer ns=$ns fallback=main"
            $freeLane = Get-FreeLane -Role "reviewer" -Lanes ($script:persistentLanes | Where-Object { $_.ModuleId -eq 'main' })
        }
        if (-not $freeLane) {
            Write-OrchestratorLog "DISPATCH_NO_FREE_LANE module=$moduleId role=reviewer ns=$ns"
            continue
        }
        $freeLane.Idle = $false
        $g.Lane = $freeLane
        $dispatchQueue.Add($g); $reviewerDispatched++
    }

    foreach ($g in $dispatchQueue) {
        $ns = $g.Namespace; $role = $g.Role; $moduleId = $g.Module; $peerFilesToProcess = $g.Files
        $nsKey = "$moduleId|$ns|$role"

        if ($script:activeStreams.ContainsKey($nsKey)) {
            $streamInfo = $script:activeStreams[$nsKey]
            foreach ($f in $peerFilesToProcess) {
                Add-FileToStream -StreamDir $streamInfo.Path -SourcePath $f.FullName -Role $role
                $script:usedNamespaces[$f.Name] = $true
            }
            Write-OrchestratorLog "STREAM_ADD_FILES module=$moduleId ns=$ns stream=$($streamInfo.Id) count=$($peerFilesToProcess.Count)"
            # Commit the added-file rename immediately and re-verify plan integrity
            # (orchestrator-tooling-3/-4) — the stream is live, so restore-only, no quarantine.
            Invoke-DispatchRenameCommit -RepoDir $RepoDir -StreamDir $streamInfo.Path -StreamId $streamInfo.Id -Role $role -Namespace $ns
            foreach ($lf in @(Get-ChildItem "$($streamInfo.Path)/*.md" -ErrorAction SilentlyContinue)) {
                $null = Test-LanePlanFileIntegrity -RepoDir $RepoDir -FilePath $lf.FullName -LaneId $streamInfo.Id
            }
        } else {
            $freeLane = $g.Lane
            if (-not $freeLane) {
                Write-OrchestratorLog "DISPATCH_NO_LANE_RESERVED module=$moduleId ns=$ns role=$role"
                continue
            }
            $streamId = $freeLane.Id
            $streamDir = $freeLane.Path
            $null = New-Item -ItemType Directory -Path $streamDir -Force -ErrorAction SilentlyContinue
            # Clear any stale plan files and .complete sentinel from the lane
            Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue | Remove-Item -Force
            $staleComplete = Join-Path $streamDir ".complete"
            if (Test-Path $staleComplete) {
                Remove-Item -LiteralPath $staleComplete -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "LANE_REUSE_CLEANED_SENTINEL lane=$streamId removed stale .complete"
            }
            Write-OrchestratorLog "LANE_REUSE lane=$streamId role=$role ns=$ns module=$moduleId"

            foreach ($f in $peerFilesToProcess) {
                $destPath = Join-Path $streamDir $f.Name
                try {
                    Move-Item -LiteralPath $f.FullName -Destination $destPath -Force -ErrorAction Stop
                } catch {
                    throw "FILE_MOVE_FAILED file=$($f.Name) source=$($f.FullName) dest=$destPath error=$($_.Exception.Message)"
                }
                if (-not (Test-Path $destPath)) {
                    throw "FILE_MOVE_VERIFY_FAILED file=$($f.Name) dest=$destPath"
                }
                # Reset stale lock headers so STREAM_STATUS doesn't see "Status: released"
                # and sweep the freshly dispatched files back to Code/ (redispatch loop fix).
                # Reviewer lanes must preserve the coder's lock header (chain of possession),
                # so the reset applies to coder lanes only.
                if ($role -eq 'coder') {
                    Reset-PlanLockHeader -FilePath $destPath
                }
                $script:usedNamespaces[$f.Name] = $true
                Write-OrchestratorLog "FILE_MOVED file=$($f.Name) from=$($f.Directory.Name)/ to=$streamId/ role=$role ns=$ns"
            }

            $planFilesStaged = @(Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue)
            if ($planFilesStaged.Count -ne $peerFilesToProcess.Count) {
                throw "PLAN_STAGE_MISMATCH expected=$($peerFilesToProcess.Count) actual=$($planFilesStaged.Count) streamDir=$streamDir"
            }

            # Mark lane as busy
            for ($__li = 0; $__li -lt $script:persistentLanes.Count; $__li++) {
                if ($script:persistentLanes[$__li].Id -eq $streamId) {
                    $script:persistentLanes[$__li].Idle = $false
                    break
                }
            }

            Write-AtomicJson -Path (Join-Path $streamDir "stream.json") -InputObject (@{
                Id        = $streamId
                Namespace = $ns
                Role      = $role
                Module    = $moduleId
                Created   = (Get-Date -Format 'o')
            })

            # Post-dispatch lock-header integrity check (orchestrator-tooling-4):
            # never hand a header-only/corrupted plan to the lane agent. Restores
            # the body from git HEAD/history; quarantines only if unrestorable.
            $lanePlanOk = $true
            foreach ($lf in @(Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue)) {
                if (-not (Test-LanePlanFileIntegrity -RepoDir $RepoDir -FilePath $lf.FullName -LaneId $streamId)) {
                    $lanePlanOk = $false
                    $failedDir = Join-Path $RepoDir "Tasks/Failed"
                    $null = New-Item -ItemType Directory -Path $failedDir -Force -ErrorAction SilentlyContinue
                    Move-Item -LiteralPath $lf.FullName -Destination (Join-Path $failedDir $lf.Name) -Force -ErrorAction SilentlyContinue
                    Write-OrchestratorLog "LANE_PLAN_QUARANTINED file='$($lf.Name)' lane=$streamId dest=Failed/ reason=unrestorable-header"
                }
            }
            if (-not $lanePlanOk) {
                for ($__li = 0; $__li -lt $script:persistentLanes.Count; $__li++) {
                    if ($script:persistentLanes[$__li].Id -eq $streamId) { $script:persistentLanes[$__li].Idle = $true; break }
                }
                Write-OrchestratorLog "LANE_PLAN_INTEGRITY_FAILED lane=$streamId ns=$ns — skipping spawn" -Level WARN
                continue
            }
            # Commit the dispatch rename immediately (orchestrator-tooling-3) so a
            # concurrent merge-phase checkout/pull cannot restore the stale source copy.
            Invoke-DispatchRenameCommit -RepoDir $RepoDir -StreamDir $streamDir -StreamId $streamId -Role $role -Namespace $ns

            try {
                $branchName = $null
                if ($script:useWorktrees) {
                    $branchName = if ($moduleId -ne 'main') { "wt/$moduleId" } else { 'main' }
                }
                $planProfile = Resolve-ModelRoutedProfile -PlanPath @($planFilesStaged.FullName) -DefaultConfig $script:DefaultHarnessConfig
                $agentPath = Use-PlanExecutorProfile -Config $planProfile.Config -Initialize
                Write-OrchestratorLog "PLAN_PROFILE_RESOLVED stream=$streamId ns=$ns override=$($planProfile.HasOverride) routed=$($planProfile.Routed) tier=$($planProfile.Tier) routedModel=$($planProfile.RoutedModel) harness=$($planProfile.Config.Harness) provider=$($planProfile.Config.Provider) model=$($planProfile.Config.Model) effort=$($planProfile.Config.Effort)"
                $proc = Start-StreamCoder -StreamId $streamId -StreamDir $streamDir -RepoDir $RepoDir -AgentPath $agentPath -InstanceId $InstanceId -Role $role -UseWorktrees:$script:useWorktrees -Namespace $ns -BranchName $branchName -HarnessConfig $planProfile.Config -PlanProfileOverride:$planProfile.HasOverride
                if ($null -eq $proc) {
                    throw "STREAM_SPAWN_FAILED: Start-StreamCoder returned no process for lane=$streamId namespace=$ns"
                }
            } catch {
                Write-Host "  ⚠ Failed to spawn stream for '$ns': $($_.Exception.Message)" -ForegroundColor Red
                Write-OrchestratorLog "STREAM_SPAWN_FAILED ns=$ns error='$($_.Exception.Message)'"
                $destDir = if ($role -eq "coder") { "$RepoDir/Tasks/Code" } else { "$RepoDir/Tasks/Review" }
                Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                    if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        Write-OrchestratorLog "STREAM_SPAWN_SKIP_TERMINAL file='$($_.Name)' reason=already_in_terminal_queue"
                    } else {
                        Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
                    }
                }
                # Don't remove lane dirs — keep them for retry
                continue
            }

            $streamInfo = @{
                Id        = $streamId
                Path      = $streamDir
                Namespace = $ns
                Role      = $role
                Module    = $moduleId
                HarnessConfig = $profile.Config
                Branch    = $branchName
                Process   = if ($proc -is [System.Diagnostics.Process]) { $proc } elseif ($proc.Handle) { $proc.Handle } else { $null }
                Task      = $proc
                Pid       = if ($proc -is [System.Diagnostics.Process]) { $proc.Id } elseif ($proc.Pid) { $proc.Pid } elseif ($proc.Handle) { $proc.Handle.Id } else { $null }
                StartTime = Get-Date
                Status    = "running"
            }
            $script:activeStreams[$nsKey] = $streamInfo
            $script:lastRole = $role
            Write-Host "  → Created $streamId for $role namespace '$ns' ($($peerFilesToProcess.Count) files)" -ForegroundColor Yellow
            Write-OrchestratorLog "STREAM_CREATED id=$streamId ns=$ns role=$role files=$($peerFilesToProcess.Count)"
            if ($script:useWorktrees) {
                if ($moduleId -ne 'main') {
                    $branchName = "wt/$moduleId"
                } else {
                    $branchName = 'main'
                }
                if ($script:worktreeBranches -notcontains $branchName) {
                    $script:worktreeBranches.Add($branchName)
                }
            }
        }
    }
    if ($unassigned.Count -gt $dispatchQueue.Count) {
        Write-OrchestratorLog "STREAM_DISPATCH_LIMITED dispatched=$($dispatchQueue.Count) remaining=$($unassigned.Count - $dispatchQueue.Count) max=$CodeParallelCount"
    }
    } catch {
        Write-OrchestratorError -Op "PhaseA" -Message $_.Exception.Message -Stack $_.ScriptStackTrace -Iteration $i
        if (Test-IsFatalError -Counts $counts -CgResult $cgResult) {
            Write-OrchestratorLog "PHASE_A_FATAL iteration=$i" -Level ERROR
            $exitKind = "crashed"; break
        }
    }
    }

    # ── Phase B: Monitor all active streams ──
    try {
    $completedStreams = [System.Collections.Generic.List[string]]::new()
    $failedStreams = [System.Collections.Generic.List[string]]::new()

    # Sentinel-based completion (live-but-idle-with-sentinel fix):
    # opencode's `run --command` mode keeps the process alive in TUI mode
    # after the command finishes, so HasExited-based completion never fires.
    # The work-stream template (step 7) writes a .complete sentinel when
    # done. Invoke-SentinelLaneReclamation detects .complete-bearing streams
    # with live processes, kills the lingering TUI process, and returns the
    # reclaimed namespaces with their sentinel exit codes. Without this, a
    # lane with an agent-written .complete but a live process is skipped by
    # every reclamation path (Phase B skips non-exited; drained-stream skips
    # .complete; Invoke-DrainedLaneReclamation skips .complete) and is held
    # forever, exhausting dispatch capacity.
    try {
        $sentinelReclaimed = Invoke-SentinelLaneReclamation -ActiveStreams $script:activeStreams
        # Wrap with @() to prevent PowerShell from unwrapping a single-element
        # List into a bare hashtable (which would make foreach iterate over the
        # hashtable's entries instead of the single reclaimed stream).
        $sentinelList = @($sentinelReclaimed)
        if ($sentinelList.Count -gt 0) {
            foreach ($sr in $sentinelList) {
                if ($sr.ExitCode -eq 0) {
                    $completedStreams.Add($sr.Namespace)
                } else {
                    $failedStreams.Add($sr.Namespace)
                }
            }
            Write-OrchestratorLog "SENTINEL_RECLAMATION reclaimed=$($sentinelList.Count) completed=$(@($sentinelList | Where-Object { $_.ExitCode -eq 0 }).Count) failed=$(@($sentinelList | Where-Object { $_.ExitCode -ne 0 }).Count)"
        }
    } catch {
        Write-OrchestratorLog "SENTINEL_RECLAMATION_ERROR message='$($_.Exception.Message)'" -Level WARN
    }

    foreach ($ns in $script:activeStreams.Keys) {
        $stream = $script:activeStreams[$ns]

        $startTime = if ($stream.StartTime -is [datetime]) { $stream.StartTime } elseif ($stream.StartTime) { [datetime]$stream.StartTime } else { Get-Date }
        $elapsed = ((Get-Date) - $startTime).TotalMinutes
        if ($elapsed -ge $SubprocessTimeoutMinutes) {
            Write-Host "  ⏱ $($stream.Id) exceeded ${SubprocessTimeoutMinutes}m timeout — terminating" -ForegroundColor Yellow
            Write-OrchestratorLog "STREAM_TIMEOUT stream=$($stream.Id) ns=$ns elapsed=$([math]::Round($elapsed,1))m"
            if ($stream.Task -and -not $stream.Task.HasExited) {
                Use-PlanExecutorProfile -Config $stream.HarnessConfig | Out-Null
                Stop-ExecutorTask -Task $stream.Task
            }
            $failedStreams.Add($ns)
            continue
        }

        $task = $stream.Task
        $hasExited = if ($task) {
            Use-PlanExecutorProfile -Config $stream.HarnessConfig | Out-Null
            Get-ExecutorTaskStatus -Task $task
            $task.HasExited
        } else { $false }
        if ($task -and $hasExited) {
            $exitCode = $task.ExitCode
            if ($exitCode -eq 0) {
                $completedStreams.Add($ns)
                $sentinel = @{
                    exitCode   = 0
                    finishedAt = (Get-Date -Format 'o')
                    namespace  = $ns
                    stream     = $stream.Id
                } | ConvertTo-Json -Compress
                try { $sentinel | Set-Content (Join-Path $stream.Path ".complete") -Encoding utf8 -NoNewline -ErrorAction Stop } catch { Write-OrchestratorLog "SENTINEL_WRITE_FAILED ns=$ns stream=$($stream.Id) error='$($_.Exception.Message)'" -Level WARN }
            } else {
                $failedStreams.Add($ns)
            }
            continue
        }

        $hbFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$($stream.Id).heartbeat"
        if (Test-Path $hbFile) {
            $hb = (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
            if ($hb -and (([datetime]::UtcNow) - $hb.ToUniversalTime()).TotalMinutes -ge 15) {
                if ($task -and -not $task.HasExited) {
                    Start-Sleep -Seconds 10
                    $hb2 = (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
                    if ($hb2 -and (([datetime]::UtcNow) - $hb2.ToUniversalTime()).TotalMinutes -lt 15) { continue }
                }
                Write-Host "  ⚠ $($stream.Id) heartbeat stale — rescuing" -ForegroundColor Yellow
                $failedStreams.Add($ns)
            }
        }

        $planFiles = Get-ChildItem "$($stream.Path)\*.md" -ErrorAction SilentlyContinue
        $statusSummary = "plans=$($planFiles.Count)"
        if ($planFiles) {
            $released = 0; $locked = 0
            foreach ($pf in $planFiles) {
                $content = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match '- Status: released') { $released++ }
                elseif ($content -match '- Status: locked') { $locked++ }
            }
            $statusSummary = "plans=$($planFiles.Count) released=$released locked=$locked"
        }
        Write-OrchestratorLog "STREAM_STATUS stream=$($stream.Id) ns=$ns $statusSummary"
        $logFile = Join-Path $stream.Path "stream.log"
        if (Test-Path $logFile) {
            $firstLine = Get-Content $logFile -First 1 -ErrorAction SilentlyContinue
            if ($firstLine) {
                Write-OrchestratorLog "STREAM_STATUS_LEGACY stream=$($stream.Id) line='$firstLine'"
            }
        }
    }

    foreach ($ns in $completedStreams) {
        $streamInfo = $script:activeStreams[$ns]
        $streamId = $streamInfo.Id
        $role = $streamInfo.Role
        Write-Host "  ✓ Namespace '$ns' completed (stream $streamId)" -ForegroundColor Green
        $sentinel = @{
            exitCode   = 0
            finishedAt = (Get-Date -Format 'o')
            namespace  = $ns
            stream     = $streamId
        } | ConvertTo-Json -Compress
        $sentinel | Set-Content (Join-Path $streamInfo.Path ".complete") -Encoding utf8 -NoNewline
        $streamNs = $streamInfo.Namespace
        Get-ChildItem "$($streamInfo.Path)/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
            $script:usedNamespaces.Remove($_.Name)
        }
        Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces -NamespaceFilter $streamNs
        $remainingPlans = Get-ChildItem "$($streamInfo.Path)/*.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($rp in $remainingPlans) {
            if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $rp.Name) {
                Remove-Item -LiteralPath $rp.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "COMPLETED_STREAM_SKIP_TERMINAL file='$($rp.Name)' stream='$($streamInfo.Id)' reason=already_in_terminal_queue"
                continue
            }
            $dest = Join-Path $RepoDir "Tasks/Review" $rp.Name
            if (-not (Test-Path $dest)) {
                Move-Item -LiteralPath $rp.FullName -Destination $dest -Force
                Write-OrchestratorLog "COMPLETED_STREAM_MOVE_FILE file='$($rp.Name)' stream='$($streamInfo.Id)' dest='Review/'"
            }
        }

        # Mark lane as idle for reuse
        $isLane = $false
        for ($__li = 0; $__li -lt $script:persistentLanes.Count; $__li++) {
            if ($script:persistentLanes[$__li].Id -eq $streamId) {
                $script:persistentLanes[$__li].Idle = $true
                $isLane = $true
                Write-OrchestratorLog "LANE_IDLE lane=$streamId role=$role"
                break
            }
        }

        if ($isLane) {
            # Lane stays alive — remove from active streams so Phase A can re-dispatch
            $script:activeStreams.Remove($ns)
            # Immediately check for more work from the appropriate queue
            $queueDir = if ($role -eq "coder") { "$RepoDir/Tasks/Code" } else { "$RepoDir/Tasks/Review" }
            $nextPlan = Get-ChildItem "$queueDir/*.md" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne '.gitkeep' -and -not $script:usedNamespaces.ContainsKey($_.Name) } |
                Select-Object -First 1
            if ($nextPlan) {
                $nextNs = Get-FileNamespace -FileName $nextPlan.Name
                $reModuleId = if ($streamInfo.Module) { $streamInfo.Module } else { 'main' }
                $nextNsKey = "$reModuleId|$nextNs|$role"
                if (-not $script:activeStreams.ContainsKey($nextNsKey) -and -not $script:busyNamespaces.ContainsKey($nextNsKey)) {
                    $script:usedNamespaces[$nextPlan.Name] = $true
                    $reDispatchDest = Join-Path $streamInfo.Path $nextPlan.Name
                    Move-Item -LiteralPath $nextPlan.FullName -Destination $reDispatchDest -Force
                    Reset-PlanLockHeader -FilePath $reDispatchDest
                    Write-OrchestratorLog "LANE_RE_DISPATCH lane=$streamId role=$role plan=$($nextPlan.Name)"
                    $script:persistentLanes[$__li].Idle = $false
                    # Remove stale .complete sentinel from prior session — if left in place,
                    # the new agent sees it and exits immediately without doing any work.
                    $staleComplete = Join-Path $streamInfo.Path ".complete"
                    if (Test-Path $staleComplete) {
                        Remove-Item -LiteralPath $staleComplete -Force -ErrorAction SilentlyContinue
                        Write-OrchestratorLog "LANE_RE_DISPATCH_CLEANED_SENTINEL lane=$streamId removed stale .complete"
                    }
                    Write-AtomicJson -Path (Join-Path $streamInfo.Path "stream.json") -InputObject (@{
                        Id        = $streamId
                        Namespace = $nextNs
                        Role      = $role
                        Module    = $reModuleId
                        Created   = (Get-Date -Format 'o')
                    })
                    # Commit the re-dispatch rename and re-verify plan integrity
                    # (orchestrator-tooling-3/-4).
                    Invoke-DispatchRenameCommit -RepoDir $RepoDir -StreamDir $streamInfo.Path -StreamId $streamId -Role $role -Namespace $nextNs
                    foreach ($lf in @(Get-ChildItem "$($streamInfo.Path)/*.md" -ErrorAction SilentlyContinue)) {
                        $null = Test-LanePlanFileIntegrity -RepoDir $RepoDir -FilePath $lf.FullName -LaneId $streamId
                    }
                    try {
                        $nextProfile = Resolve-ModelRoutedProfile -PlanPath @($reDispatchDest) -DefaultConfig $script:DefaultHarnessConfig
                        $nextAgentPath = Use-PlanExecutorProfile -Config $nextProfile.Config -Initialize
                        $proc = Start-StreamCoder -StreamId $streamId -StreamDir $streamInfo.Path -RepoDir $RepoDir -AgentPath $nextAgentPath -InstanceId $InstanceId -Role $role -UseWorktrees:$script:useWorktrees -Namespace $nextNs -HarnessConfig $nextProfile.Config -PlanProfileOverride:$nextProfile.HasOverride
                        $streamInfo.Process = if ($proc -is [System.Diagnostics.Process]) { $proc } elseif ($proc.Handle) { $proc.Handle } else { $null }
                        $streamInfo.Task = $proc
                        $streamInfo.HarnessConfig = $nextProfile.Config
                        $streamInfo.StartTime = Get-Date
                        $streamInfo.Status = "running"
                        $streamInfo.Namespace = $nextNs
                        $script:activeStreams[$nextNsKey] = $streamInfo
                        Write-OrchestratorLog "LANE_RE_SPAWN lane=$streamId role=$role ns=$nextNs"
                    } catch {
                        Write-OrchestratorLog "LANE_RE_SPAWN_FAILED lane=$streamId error='$($_.Exception.Message)'" -Level WARN
                        $script:persistentLanes[$__li].Idle = $true
                    }
                }
            }
        } else {
            # Non-lane stream — old behavior: remove
            Remove-Stream -StreamDir $streamInfo.Path -AgentId $streamInfo.Id
            $script:activeStreams.Remove($ns)
        }
    }

    if ($completedStreams.Count -gt 0 -and $null -ne $readySet) {
            try {
                if (-not $connascenceScript) { throw "Connascence scanner was not resolved during dispatch" }
                $updatedOutput = & $connascenceScript -RepoRoot $RepoDir -TaskDir (Join-Path $RepoDir 'Tasks/Code') -ModuleCount $ModuleCount -PassThru
                $updatedResult = ($updatedOutput | ConvertFrom-Json -ErrorAction Stop)
            } catch { Write-OrchestratorLog "CONNASCENCE_REPARSE_FAILED path='$connascenceScript' error='$($_.Exception.Message)'" -Level WARN; $updatedResult = $null }
        if ($updatedResult -and $updatedResult.readySet) {
            $newReady = $updatedResult.readySet | Where-Object { -not $readySet.Contains($_) }
            if ($newReady) {
                Write-Host "  → Newly ready sessions detected: $($newReady -join ', ')" -ForegroundColor Yellow
                $newReady | ForEach-Object { $null = $readySet.Add($_) }
            }
        }
    }

    foreach ($ns in $failedStreams) {
        $streamInfo = $script:activeStreams[$ns]
        $streamDir = $streamInfo.Path
        $role = $streamInfo.Role
        $procExitCode = if ($streamInfo.Task -and $null -ne $streamInfo.Task.ExitCode) { $streamInfo.Task.ExitCode } else { -1 }

        Write-Host "  ⚠ Namespace '$ns' failed (stream $($streamInfo.Id)) — rescuing" -ForegroundColor Red
        $sentinel = @{
            exitCode   = $procExitCode
            finishedAt = (Get-Date -Format 'o')
            namespace  = $ns
            stream     = $streamInfo.Id
        } | ConvertTo-Json -Compress
        $sentinel | Set-Content (Join-Path $streamDir ".complete") -Encoding utf8 -NoNewline
        # Preserve crash evidence: agent stdout/stderr
        $crashDir = Join-Path $RepoDir "Tasks/Logs/crashes"
        $null = New-Item -ItemType Directory -Path $crashDir -Force
        $evidenceDir = Join-Path $crashDir "$($streamInfo.Id)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $null = New-Item -ItemType Directory -Path $evidenceDir -Force
        foreach ($ext in @('stdout', 'stderr', 'pid', 'heartbeat')) {
            $src = Join-Path $RepoDir "Tasks/Logs/agents/$($streamInfo.Id).$ext"
            if (Test-Path $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $evidenceDir "$($streamInfo.Id).$ext") -Force -ErrorAction SilentlyContinue
            }
        }
        $summary = @{
            stream_id    = $streamInfo.Id
            namespace    = $ns
            exit_code    = $procExitCode
            role         = $role
            preserved_at = (Get-Date -Format 'o')
            evidence_dir = $evidenceDir
        } | ConvertTo-Json -Compress
        $summary | Out-File (Join-Path $evidenceDir "crash-summary.json") -Encoding utf8 -NoNewline
        Write-OrchestratorLog "STREAM_CRASH_EVIDENCE stream=$($streamInfo.Id) evidenceDir='$evidenceDir' exitCode=$procExitCode" -Level WARN
        $alreadyInHead = $false
        foreach ($mdFile in (Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue)) {
            $content = Get-Content $mdFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match 'Already in HEAD:|already[_ ]in[_ ]HEAD') {
                $alreadyInHead = $true
                break
            }
        }
        $logFile = Join-Path $streamDir "stream.log"
        if (-not $alreadyInHead -and (Test-Path $logFile)) {
            $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
            if ($logContent -match 'already[_ ]in[_ ]HEAD|no_changes_needed|COMMIT\s+already') { $alreadyInHead = $true }
        }
        $destDir = if ($alreadyInHead) { "$RepoDir/Tasks/Complete" } elseif ($role -eq "coder") { "$RepoDir/Tasks/Code" } else { "$RepoDir/Tasks/Review" }
        Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
            $retries = Increment-FileRetry -FileName $_.Name -StreamId $streamInfo.Id -ExitCode $procExitCode
            if (Test-FileExceededRetryBudget -FileName $_.Name) {
                Write-Host "    ⚠ $($_.Name) exceeded retry budget ($retries) — quarantining" -ForegroundColor Yellow
                Invoke-QuarantineFile -FilePath $_.FullName -RepoDir $RepoDir -Reason "retry-budget-exceeded"
            } elseif ($alreadyInHead) {
                Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
                Reset-FileRetry -FileName $_.Name
            } elseif (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "STREAM_EXIT_SKIP_TERMINAL file='$($_.Name)' reason=already_in_terminal_queue"
            } else {
                Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
            }
        }
        # Keep lane alive — mark idle for re-dispatch
        $isFailedLane = $false
        for ($__fi = 0; $__fi -lt $script:persistentLanes.Count; $__fi++) {
            if ($script:persistentLanes[$__fi].Id -eq $streamInfo.Id) {
                $script:persistentLanes[$__fi].Idle = $true
                $isFailedLane = $true
                Write-OrchestratorLog "LANE_FAILED_IDLE lane=$($streamInfo.Id) role=$role"
                break
            }
        }
        if (-not $isFailedLane) {
            Remove-Stream -StreamDir $streamDir -AgentId $streamInfo.Id
        }
        $script:activeStreams.Remove($ns)
        $totalCrashed++
        Get-ChildItem "$destDir/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
            $script:usedNamespaces.Remove($_.Name)
        }
    }
    } catch {
        Write-OrchestratorError -Op "PhaseB" -Message $_.Exception.Message -Stack $_.ScriptStackTrace -Iteration $i
        if (Test-IsFatalError -Counts $counts -CgResult $cgResult) {
            Write-OrchestratorLog "PHASE_B_FATAL iteration=$i" -Level ERROR
            $exitKind = "crashed"; break
        }
    }

    Write-OrchestratorHeartbeat -HeartbeatFile $heartbeatFile

    try {
        $discrepancies = Invoke-ReconcileState -RepoDir $RepoDir -ActiveStreams $script:activeStreams -BusyNamespaces $script:busyNamespaces -UsedNamespaces $script:usedNamespaces
        if ($discrepancies.Count -gt 0) {
            Write-OrchestratorLog "STATE_RECONCILE discrepancies=$($discrepancies.Count)" -Level WARN
        }
    } catch {
        Write-OrchestratorError -Op "ReconcileState" -Message $_.Exception.Message -Iteration $i
    }

    try {
        . (Join-Path $script:SkillsRoot "Git/Invoke-WorktreeCleanup.ps1")
        $orphanResults = Remove-OrphanWorktrees -DryRun:$false
        if ($orphanResults.Count -gt 0) {
            Write-OrchestratorLog "ORPHAN_WORKTREES_REMOVED count=$($orphanResults.Count)" -Level INFO
        }
    } catch {
        Write-OrchestratorError -Op "WorktreeCleanup" -Message $_.Exception.Message -Iteration $i
    }

    # ── Phase C: Merge all worktree branches ──
    try {
    if ($script:useWorktrees -and $script:worktreeBranches.Count -gt 0) {
        $activeBranches = $script:activeStreams.Values.Branch | Where-Object { $_ } | Select-Object -Unique
        $readyBranches = $script:worktreeBranches | Where-Object { $_ -notin $activeBranches } | Sort-Object
        if ($readyBranches.Count -eq 0) {
            Write-Host "  Merge phase skipped: worktree branches still active" -ForegroundColor DarkGray
        } else {
        Write-Host "  Merging worktree branches back to main..." -ForegroundColor Cyan
        Write-OrchestratorLog "MERGE_PHASE_START branches='$($readyBranches -join ', ')'"
        . (Join-Path $script:SkillsRoot "Git/Invoke-WorktreeMergeAll.ps1")
        . (Join-Path $script:SkillsRoot "Git/Invoke-WorktreeCleanup.ps1")
        $mergeResult = @{ Merged = 0; Conflicts = 0; ConflictBranches = @() }
        foreach ($branch in $readyBranches) {
            $branchResult = Merge-AgentBranches -Branches @($branch) -RepoRoot $RepoDir
            $mergeResult.Merged += $branchResult.Merged
            $mergeResult.Conflicts += $branchResult.Conflicts
            if ($branchResult.ConflictBranches) { $mergeResult.ConflictBranches += $branchResult.ConflictBranches }
        }
        $mergeDir = Join-Path $RepoDir "Tasks/Merge"
        $mergePlans = Get-ChildItem "$mergeDir/*-merge-feedback-*.md" -ErrorAction SilentlyContinue
        $runningMerges = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($mp in $mergePlans) {
            Write-Host "  Dispatching merge agent for conflict: $($mp.Name)" -ForegroundColor Yellow
            Write-OrchestratorLog "MERGE_DISPATCH plan='$($mp.Name)'"
            $safeBranch = $mp.BaseName -replace '-merge-feedback-.*$', ''
            $branchName = $safeBranch -replace '-', '/'
            $wtPath = Join-Path $RepoDir "Tasks/Worktrees" ($safeBranch -replace '^wt-', '')
            $proc = Invoke-ExecutorMerge -MergePlan $mp.FullName -WorktreePath $wtPath -BranchName $branchName -RepoDir $RepoDir
            $runningMerges.Add([PSCustomObject]@{ Process = $proc; Plan = $mp; Branch = $branchName; SafeBranch = $safeBranch })
        }
        foreach ($rm in $runningMerges) {
            try { $null = $rm.Process.WaitForExit(300000) } catch {
                Write-OrchestratorLog "MERGE_WAIT_EXCEPTION plan='$($rm.Plan.Name)' error='$($_.Exception.Message)'" -Level WARN
            }
            if ($rm.Process.HasExited -and $rm.Process.ExitCode -eq 0) {
                Write-Host "    ✓ Merge resolved: $($rm.Plan.Name)" -ForegroundColor Green
                Write-OrchestratorLog "MERGE_RESOLVED plan='$($rm.Plan.Name)' branch=$($rm.Branch)"
                Move-Item $rm.Plan.FullName (Join-Path $RepoDir "Tasks/Complete") -Force
                $retryResult = Merge-AgentBranches -Branches @($rm.Branch) -RepoRoot $RepoDir
                if ($retryResult.Conflicts -gt 0) {
                    Write-Host "    ⚠ Merge still conflicts after resolution — escalating" -ForegroundColor Red
                }
            } else {
                Write-Host "    ⚠ Merge agent failed to resolve: $($rm.Plan.Name)" -ForegroundColor Red
                Write-OrchestratorLog "MERGE_FAILED plan='$($rm.Plan.Name)' branch=$($rm.Branch) exit=$($rm.Process.ExitCode)"
            }
        }
        Write-Host "  Merged: $($mergeResult.Merged), Conflicts: $($mergeResult.Conflicts)" -ForegroundColor $(if($mergeResult.Conflicts -eq 0){'Green'}else{'Yellow'})
        Write-OrchestratorLog "MERGE_PHASE_END merged=$($mergeResult.Merged) conflicts=$($mergeResult.Conflicts) branches='$($mergeResult.ConflictBranches -join ', ')'"
        # Post-merge re-track: when a stream crashes and lane-recovery moves
        # plan files back to Tasks/Code/ in the worktree, the worktree's
        # dispatch commit deleted them from Code/. After merge to main, the
        # files exist on disk in main's working tree but are untracked (??).
        # The DISPATCH_UNCOMMITTED gate then skips them, stalling the queue.
        # Re-add and commit any untracked plan files in Code/ and Review/.
        $untrackedPlans = @()
        $codeUntracked = Get-ChildItem "$RepoDir/Tasks/Code" -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne '.gitkeep' -and $_.Name -like '*.md'
        } | Where-Object {
            $rel = "Tasks/Code/$($_.Name)"
            $status = git -C $RepoDir status --porcelain -- "$rel" 2>$null
            $status -and $status.StartsWith('??')
        }
        $reviewUntracked = Get-ChildItem "$RepoDir/Tasks/Review" -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne '.gitkeep' -and $_.Name -like '*.md'
        } | Where-Object {
            $rel = "Tasks/Review/$($_.Name)"
            $status = git -C $RepoDir status --porcelain -- "$rel" 2>$null
            $status -and $status.StartsWith('??')
        }
        $untrackedPlans = @($codeUntracked) + @($reviewUntracked)
        # Terminal-state guard: drop plans already in a terminal queue
        $untrackedPlans = @($untrackedPlans | Where-Object {
            if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "MERGE_RETRACK_SKIP_TERMINAL file='$($_.Name)' reason=already_in_terminal_queue"
                $false
            } else { $true }
        })
        if ($untrackedPlans.Count -gt 0) {
            $pathsToCommit = $untrackedPlans | ForEach-Object {
                $queue = if ($_.Directory.Name -eq 'Code') { 'Code' } else { 'Review' }
                "Tasks/$queue/$($_.Name)"
            }
            foreach ($p in $pathsToCommit) {
                git -C $RepoDir add -- "$p" 2>$null
            }
            $commitMsg = "chore(merge): re-track recovered plans after worktree merge`n`nUntracked plans in Code/ or Review/ after worktree merge — lane-recovery`nmoved them back from a crashed stream. Re-commit so DISPATCH_UNCOMMITTED`ngate can dispatch them.`n`nGenerated with [Devin](https://devin.ai)"
            $pushed = $false
            try {
                git -C $RepoDir commit -m $commitMsg 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    git -C $RepoDir push 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $pushed = $true }
                }
            } catch {
                Write-OrchestratorLog "MERGE_RETRACK commit/push failed: $($_.Exception.Message)" -Level WARN
            }
            Write-OrchestratorLog "MERGE_RETRACK count=$($untrackedPlans.Count) pushed=$pushed"
            Write-Host "  Re-tracked $($untrackedPlans.Count) recovered plan(s) after merge (pushed=$pushed)" -ForegroundColor $(if($pushed){'Green'}else{'Yellow'})
        }
        $resolvedBranches = $readyBranches | Where-Object { $_ -notin $mergeResult.ConflictBranches }
        foreach ($branch in $resolvedBranches) {
            $wtPath = Join-Path $RepoDir "Tasks/worktrees" ($branch.Replace('wt/', ''))
            Remove-AgentWorktree -WorktreePath $wtPath -BranchName $branch
        }
        }
    }
    } catch {
        Write-OrchestratorError -Op "PhaseC" -Message $_.Exception.Message -Stack $_.ScriptStackTrace -Iteration $i
        if (Test-IsFatalError -Counts $counts -CgResult $cgResult) {
            Write-OrchestratorLog "PHASE_C_FATAL iteration=$i" -Level ERROR
            $exitKind = "crashed"; break
        }
    }

    # ── Phase B2: Monitor orphaned agents ──
    if ($script:orphanStreams.Count -gt 0) {
        $completedOrphans = [System.Collections.Generic.List[string]]::new()
        foreach ($agentId in $script:orphanStreams.Keys) {
            $orphan = $script:orphanStreams[$agentId]
            $ns = $orphan.Namespace
            $pidFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$agentId.pid"
            $agentPid = $null
            if (Test-Path $pidFile) {
                $rawPid = Get-Content $pidFile -Raw -ErrorAction SilentlyContinue
                if ($rawPid) { $agentPid = $rawPid.Trim() }
            }
            $agentAlive = $agentPid -and (Get-Process -Id ([int]$agentPid) -ErrorAction SilentlyContinue)
            if (-not $agentAlive) {
                Write-OrchestratorLog "ORPHAN_DIED agent=$agentId ns=$ns — awaiting rescue timeout"
                continue
            }
            $fileInWorking = if (Test-Path $orphan.FilePath) { $true } else {
                $found = $false
                foreach ($mdFile in (Get-ChildItem "$workingDir\stream-*\*.md" -ErrorAction SilentlyContinue)) {
                    if ($mdFile.FullName -eq $orphan.FilePath -or $mdFile.Name -eq (Split-Path $orphan.FilePath -Leaf)) {
                        $found = $true
                        break
                    }
                }
                $found
            }
            if (-not $fileInWorking) {
                Write-OrchestratorLog "ORPHAN_COMPLETED agent=$agentId ns=$ns — namespace freed"
                Write-Host "  ✓ Orphaned agent $agentId completed namespace '$ns'" -ForegroundColor Green
                $completedOrphans.Add($agentId)
            } else {
                $orphanElapsed = ((Get-Date) - $orphan.AdoptedAt).TotalMinutes
                if ($orphanElapsed -ge $SubprocessTimeoutMinutes) {
                    Write-OrchestratorLog "ORPHAN_TIMEOUT agent=$agentId ns=$ns elapsed=$([math]::Round($orphanElapsed,1))m — awaiting hard-timeout rescue"
                }
            }
        }
        foreach ($agentId in $completedOrphans) {
            $ns = $script:orphanStreams[$agentId].Namespace
            $script:busyNamespaces.Remove($ns)
            $script:orphanStreams.Remove($agentId)
        }
    }

    # ── Drained-stream reclamation ──
    # Stream agents that released all files and went idle (no .complete written)
    # hold capacity slots forever. Detect and reclaim them here.

    # Live-but-idle lane reclamation: opencode's work-stream command stays alive
    # in TUI mode after completing its task, so HasExited-based completion never
    # fires and the heartbeat refresh keeps hbStale=false. This reclaims those
    # lanes by killing the idle process and marking the lane idle for reuse.
    try {
        $liveIdleReclaimed = Invoke-DrainedLaneReclamation -RepoDir $RepoDir `
            -Lanes $script:persistentLanes -ActiveStreams $script:activeStreams `
            -UsedNamespaces $script:usedNamespaces
        if ($liveIdleReclaimed -and $liveIdleReclaimed.Count -gt 0) {
            Write-OrchestratorLog "DRAINED_LANE_RECLAMATION reclaimed=$($liveIdleReclaimed.Count)"
        }
    } catch {
        Write-OrchestratorLog "DRAINED_LANE_RECLAMATION_ERROR message='$($_.Exception.Message)'" -Level WARN
    }

    $drainedStreams = [System.Collections.Generic.List[string]]::new()
    foreach ($ns in @($script:activeStreams.Keys)) {
        $stream = $script:activeStreams[$ns]
        $hasComplete = Test-Path (Join-Path $stream.Path ".complete")
        if ($hasComplete) { continue }
        $planFiles = @(Get-ChildItem "$($stream.Path)/*.md" -ErrorAction SilentlyContinue)
        if ($planFiles.Count -gt 0) { continue }
        $hbFile = Join-Path "$RepoDir/Tasks/Logs/agents" "$($stream.Id).heartbeat"
        $hbStale = $false
        if (Test-Path $hbFile) {
            $hb = (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
            if ($hb -and (([datetime]::UtcNow) - $hb.ToUniversalTime()).TotalMinutes -ge 5) { $hbStale = $true }
        }
        $procDead = $true
        if ($stream.Task) {
            Use-PlanExecutorProfile -Config $stream.HarnessConfig | Out-Null
            Get-ExecutorTaskStatus -Task $stream.Task
            $procDead = $stream.Task.HasExited
        }
        if ($procDead -or $hbStale) {
            # Skip persistent lanes — they stay alive even when idle
            $__isLane = $false
            for ($__di = 0; $__di -lt $script:persistentLanes.Count; $__di++) {
                if ($script:persistentLanes[$__di].Id -eq $stream.Id) {
                    $__isLane = $true
                    # Mark as idle and remove from active streams tracking
                    $script:persistentLanes[$__di].Idle = $true
                    Write-OrchestratorLog "LANE_DRAINED_SKIP lane=$($stream.Id) role=$($stream.Role) marked_idle"
                    break
                }
            }
            if ($__isLane) {
                $streamNs = $stream.Namespace
                Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces -NamespaceFilter $streamNs
                $drainedStreams.Add($ns)
            } else {
                Write-Host "  → $($stream.Id) drained (no plan files, $(if($procDead){'process exited'}else{'heartbeat stale'}), no .complete) — reclaiming" -ForegroundColor Yellow
                Write-OrchestratorLog "STREAM_DRAINED stream=$($stream.Id) ns=$ns procDead=$procDead hbStale=$hbStale planFiles=$($planFiles.Count)"
                $sentinel = @{
                    exitCode   = -1
                    finishedAt = (Get-Date -Format 'o')
                    reason     = "drained-idle"
                    namespace  = $ns
                    stream     = $stream.Id
                } | ConvertTo-Json -Compress
                $sentinel | Set-Content (Join-Path $stream.Path ".complete") -Encoding utf8 -NoNewline
                $streamNs = $stream.Namespace
                Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces -NamespaceFilter $streamNs
                Remove-Stream -StreamDir $stream.Path -AgentId $stream.Id
                $drainedStreams.Add($ns)
            }
        }
    }
    foreach ($ns in $drainedStreams) {
        $script:activeStreams.Remove($ns)
    }

    # Sentinel-watch loop
    if ($script:activeStreams.Count -gt 0) {
        $watchStart = Get-Date
        $anyCompleted = $false
        $watchHeartbeatCount = 0
        do {
            Start-Sleep -Seconds 5
            $watchHeartbeatCount++
            # Orchestrator-side agent heartbeat refresh: touch heartbeat for agents with live PIDs
            foreach ($__hbNs in @($script:activeStreams.Keys)) {
                $__hbStream = $script:activeStreams[$__hbNs]
                if ($__hbStream.Process -and -not $__hbStream.Process.HasExited) {
                    $__hbPath = Join-Path $RepoDir "Tasks/Logs/agents/$($__hbStream.Id).heartbeat"
                    try { Set-Content $__hbPath -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8 -NoNewline -ErrorAction Stop } catch { Write-Debug "Start-Orchestrator: heartbeat write failed for $($__hbStream.Id): $_" }
                }
            }
            # Fix G: Write orchestrator liveness heartbeat inside the watch loop
            # so the watchdog can distinguish a live-but-watching orchestrator from a spun/stuck one
            try { Write-AgentHeartbeat -AgentId "orchestrator-$InstanceId" } catch { Write-OrchestratorLog "HEARTBEAT_LOOP_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN }
            # Fix F: Update live-status inside the watch loop so orchestrator-live.json stays fresh
            if ($watchHeartbeatCount % 3 -eq 0) {
                try { Write-OrchestratorLiveStatus -RepoDir $RepoDir -InstanceId $InstanceId -Counts $counts -ActiveStreams $script:activeStreams } catch { Write-OrchestratorLog "LIVE_STATUS_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN }
            }
            $watchHeartbeatCount++
            if ($watchHeartbeatCount % 6 -eq 0) {
                $hbElapsed = [math]::Round(((Get-Date) - $sessionStart).TotalSeconds)
                $hbStreamList = ($script:activeStreams.Keys | ForEach-Object { "$_($($script:activeStreams[$_].Role))" }) -join ', '
                Write-Host "  [❤ iter $i] Streams: $($script:activeStreams.Count) running [$hbStreamList] | Queues: $($counts.CoderWorkload) coder, $($counts.ReviewerWorkload) review | Elapsed: ${hbElapsed}s" -ForegroundColor DarkGray
                Write-OrchestratorLog "HEARTBEAT iteration=$i streams=$($script:activeStreams.Count) coder_queue=$($counts.CoderWorkload) reviewer_queue=$($counts.ReviewerWorkload) failed=$($counts.Failed) todo=$($counts.ToDo) manual=$($counts.Manual) paused=$($counts.Paused) complete_files=$($counts.CompleteFiles) complete_dirs=$($counts.CompleteDirs)"
            }
            $completedNs = $null
            foreach ($ns in @($script:activeStreams.Keys)) {
                $stream = $script:activeStreams[$ns]
                if (-not (Test-Path $stream.Path)) {
                    Write-OrchestratorLog "SENTINEL_SKIP_MISSING_DIR ns=$ns stream=$($stream.Id)"
                    $script:activeStreams.Remove($ns)
                    continue
                }
                $sentinelPath = Join-Path $stream.Path ".complete"
                $isComplete = Test-Path $sentinelPath
                if (-not $isComplete) {
                    Use-PlanExecutorProfile -Config $stream.HarnessConfig | Out-Null
                    Get-ExecutorTaskStatus -Task $stream.Task
                }
                $procExited = $stream.Task -and $stream.Task.HasExited
                if (-not $isComplete -and $procExited) {
                    Start-Sleep -Seconds 3
                    Use-PlanExecutorProfile -Config $stream.HarnessConfig | Out-Null
                    Get-ExecutorTaskStatus -Task $stream.Task
                    $procExitCode = if ($stream.Task -and $null -ne $stream.Task.ExitCode) { $stream.Task.ExitCode } else { -1 }
                    $sentinel = @{
                        exitCode   = $procExitCode
                        finishedAt = (Get-Date -Format 'o')
                        namespace  = $ns
                        stream     = $stream.Id
                    } | ConvertTo-Json -Compress
                    $sentinel | Set-Content $sentinelPath -Encoding utf8 -NoNewline
                    $isComplete = $true
                }
                if ($isComplete) {
                    $sentinelExitCode = 0
                    try {
                        $sentinelContent = Get-Content $sentinelPath -Raw -ErrorAction Stop
                        if (-not [string]::IsNullOrWhiteSpace($sentinelContent)) {
                            $sentinelObj = $sentinelContent | ConvertFrom-Json -ErrorAction Stop
                            $sentinelExitCode = if ($sentinelObj.PSObject.Properties.Name -contains 'exitCode') { [int]$sentinelObj.exitCode } else { 0 }
                        }
                    } catch { $sentinelExitCode = 0 }

                    $isSuccessExit = ($sentinelExitCode -eq 0) -or ($sentinelExitCode -eq $script:ExitCodeSkipped)
                    Write-OrchestratorLog "SENTINEL_DETECTED ns=$ns stream=$($stream.Id) exitCode=$sentinelExitCode"
                    $destDir = if ($stream.Role -eq "coder") { "$RepoDir/Tasks/Review" } else { "$RepoDir/Tasks/Complete" }

                    if ($isSuccessExit) {
                        $alreadyInHead = $false
                        foreach ($mdFile in (Get-ChildItem "$($stream.Path)\*.md" -ErrorAction SilentlyContinue)) {
                            $content = Get-Content $mdFile.FullName -Raw -ErrorAction SilentlyContinue
                            if ($content -match 'Already in HEAD:|already[_ ]in[_ ]HEAD|AlreadyDone:\s*true|AlreadyDoneDetail:') {
                                $alreadyInHead = $true
                                break
                            }
                        }
                        if (-not $alreadyInHead) {
                            $logFile = Join-Path $stream.Path "stream.log"
                            if (Test-Path $logFile) {
                                $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
                                if ($logContent -match 'already[_ ]in[_ ]HEAD|no_changes_needed|COMMIT\s+already|AlreadyDone') { $alreadyInHead = $true }
                            }
                        }
                        if ($alreadyInHead) { $destDir = "$RepoDir/Tasks/Complete" }
                        Get-ChildItem "$($stream.Path)/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                            $script:usedNamespaces.Remove($_.Name)
                            if ($alreadyInHead) {
                                Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
                                Reset-FileRetry -FileName $_.Name
                                Write-OrchestratorLog "FILE_ALREADY_IN_HEAD file=$($_.Name) from=$($stream.Id)/ dest=$(Split-Path $destDir -Leaf)"
                            } else {
                                Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
                                Write-OrchestratorLog "FILE_MOVED file=$($_.Name) from=$($stream.Id)/ to=$(Split-Path $destDir -Leaf)/ exitCode=0"
                                Register-LaneCompletion -RepoDir $RepoDir -Lane $stream.Id -File $_.Name -Outcome $(Split-Path $destDir -Leaf)
                            }
                        }
                        Write-OrchestratorLog "STREAM_COMPLETED stream=$($stream.Id) exitCode=$sentinelExitCode files=$(@(Get-ChildItem $stream.Path -Filter '*.md').Count) dest=$(Split-Path $destDir -Leaf)"
                    } else {
                        Write-OrchestratorLog "STREAM_CRASHED stream=$($stream.Id) exitCode=$sentinelExitCode files=$(@(Get-ChildItem $stream.Path -Filter '*.md').Count)" -Level WARN
                        $crashClass = Get-StreamCrashClassification -StreamId $stream.Id -RepoDir $RepoDir -ExitCode $sentinelExitCode
                        Write-OrchestratorLog "STREAM_CRASH_CLASS stream=$($stream.Id) class=$($crashClass.class) transient=$($crashClass.transient) canRetry=$($crashClass.canRetry)"
                        if ($crashClass.class -eq 'rate-limit') {
                            Write-OrchestratorLog "OPENCODE_KEY_RATE_LIMIT stream=$($stream.Id)" -Level WARN
                            Switch-OpenCodeGoApiKey -RepoDir $RepoDir
                        }
                        if ($crashClass.class -eq 'permission-denied') {
                            Write-OrchestratorLog "OPENCODE_PERMISSION_DENIED stream=$($stream.Id)" -Level WARN
                        }
                        if (-not $crashClass.transient) {
                            $script:streamCrashHistory.Add((Get-Date))
                        }
                        # Preserve crash evidence: agent stdout/stderr
                        $crashDir = Join-Path $RepoDir "Tasks/Logs/crashes"
                        $null = New-Item -ItemType Directory -Path $crashDir -Force
                        $evidenceDir = Join-Path $crashDir "$($stream.Id)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                        $null = New-Item -ItemType Directory -Path $evidenceDir -Force
                        foreach ($ext in @('stdout', 'stderr', 'pid', 'heartbeat')) {
                            $src = Join-Path $RepoDir "Tasks/Logs/agents/$($stream.Id).$ext"
                            if (Test-Path $src) {
                                Copy-Item -LiteralPath $src -Destination (Join-Path $evidenceDir "$($stream.Id).$ext") -Force -ErrorAction SilentlyContinue
                            }
                        }
                        $summary = @{
                            stream_id    = $stream.Id
                            namespace    = $ns
                            exit_code    = $sentinelExitCode
                            role         = $stream.Role
                            preserved_at = (Get-Date -Format 'o')
                            evidence_dir = $evidenceDir
                        } | ConvertTo-Json -Compress
                        $summary | Out-File (Join-Path $evidenceDir "crash-summary.json") -Encoding utf8 -NoNewline
                        Write-OrchestratorLog "STREAM_CRASH_EVIDENCE stream=$($stream.Id) evidenceDir='$evidenceDir' exitCode=$sentinelExitCode" -Level WARN
                        Get-ChildItem "$($stream.Path)/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                            $script:usedNamespaces.Remove($_.Name)
                            $retries = Increment-FileRetry -FileName $_.Name -StreamId $stream.Id -ExitCode $sentinelExitCode
                            if (Test-FileExceededRetryBudget -FileName $_.Name) {
                                Write-OrchestratorLog "SENTINEL_FAILED_RETRY_BUDGET file=$($_.Name) retries=$retries dest=Tasks/Failed/"
                                Invoke-QuarantineFile -FilePath $_.FullName -RepoDir $RepoDir -Reason "sentinel-retry-budget-exceeded"
                                Write-OrchestratorLog "FILE_QUARANTINED file=$($_.Name) stream=$($stream.Id) dest=Failed/"
                            } else {
                                Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force
                                Write-OrchestratorLog "FILE_MOVED file=$($_.Name) from=$($stream.Id)/ to=$(Split-Path $destDir -Leaf)/ exitCode=$sentinelExitCode"
                            }
                        }
                    }
                    # Force-clear usedNamespaces for ALL files that were in this stream (prevents state discrepancy)
                    Get-ChildItem "$($stream.Path)/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                        # Safe discard: dictionary Remove returns bool; absence is not an error here.
                        $script:usedNamespaces.Remove($_.Name) | Out-Null
                    }
                    $streamNs = $stream.Namespace
                    Clear-UsedNamepacesForFiles -RepoDir $RepoDir -UsedNamespaces $script:usedNamespaces -NamespaceFilter $streamNs
                    # Keep persistent lanes — just remove tracking
                    $__isLaneSentinel = $false
                    for ($__si = 0; $__si -lt $script:persistentLanes.Count; $__si++) {
                        if ($script:persistentLanes[$__si].Id -eq $stream.Id) {
                            $__isLaneSentinel = $true
                            $script:persistentLanes[$__si].Idle = $true
                            Write-OrchestratorLog "LANE_SENTINEL_IDLE lane=$($stream.Id) role=$($stream.Role)"
                            break
                        }
                    }
                    if (-not $__isLaneSentinel) {
                        Remove-Stream -StreamDir $stream.Path -AgentId $stream.Id
                    }
                    $backoffDelay = Get-CrashBackoffDelay -CrashHistory $script:streamCrashHistory -MaxDelaySeconds 120
                    if ($backoffDelay -gt 0) {
                        Write-OrchestratorLog "CRASH_BACKOFF stream=$($stream.Id) ns=$ns delay=${backoffDelay}s recentCrashes=$($script:streamCrashHistory.Count)" -Level WARN
                        Start-Sleep -Seconds $backoffDelay
                    }
                    if ($crashClass.class -eq 'missing-dependency' -or $crashClass.class -eq 'permission-denied' -or $script:streamCrashHistory.Count -ge 5) {
                        $manualDir = Join-Path $RepoDir "Tasks/Manual"
                        $null = New-Item -ItemType Directory -Path $manualDir -Force
                        $suffix = if ($crashClass.class -ne 'unknown') { $crashClass.class } else { 'crash-throttle' }
                        $manualPath = Join-Path $manualDir "$(Get-Date -Format 'yyyy.MM.dd')-$($stream.Id)-$suffix.md"
                        if (-not (Test-Path $manualPath)) {
                            $manualContent = @"
# ${suffix}: $($stream.Id)

**Date**: $(Get-Date -Format 'yyyy-MM-dd')
**Source**: orchestrator crash classification

Class: $($crashClass.class)
Transient: $($crashClass.transient)
Can retry: $($crashClass.canRetry)

**Stream**: $($stream.Id)
**Namespace**: $ns
**Role**: $($stream.Role)
**Evidence**: $evidenceDir

**Action**: $(if ($crashClass.class -eq 'missing-dependency') { 'Resolve the missing dependency before re-dispatching.' } elseif ($crashClass.class -eq 'permission-denied') { 'Review opencode permission policy or use --auto.' } else { 'Investigate crash cause. Check crash evidence and stream logs.' })
"@
                            Set-Content -Path $manualPath -Value $manualContent -Encoding utf8
                            Write-OrchestratorLog "CRASH_MANUAL_TASK_CREATED path='$manualPath' class=$($crashClass.class)" -Level WARN
                        }
                    }
                    $completedNs = $ns
                    break
                }
            }
            if ($completedNs) {
                $script:activeStreams.Remove($completedNs)
                $anyCompleted = $true
                break
            }
            $elapsed = (Get-Date) - $watchStart
        } while ($elapsed.TotalSeconds -lt 60)
        Write-OrchestratorLog "POLL_SLEEP runningStreams=$($script:activeStreams.Count) completed=$anyCompleted duration=$([math]::Round($elapsed.TotalSeconds))s"
        $watchElapsed = [math]::Round($elapsed.TotalSeconds)
        $hasWork = ($counts.CoderWorkload -gt 0) -or ($counts.ReviewerWorkload -gt 0) -or ($counts.Working -gt 0)
        $baseSleep = if ($hasWork) { 120 } else { $PollIntervalSeconds }
        $remainingSleep = [math]::Max(0, $baseSleep - $watchElapsed)
        # Fix E: Hard sleep floor — always sleep at least 10s even if watch was 0s
        # Prevents tight-loop spinning when streams complete instantly
        $remainingSleep = [math]::Max($remainingSleep, 10)
        if ($remainingSleep -gt 0) {
            $poked = Wait-PokeOrSeconds -RepoDir $RepoDir -Seconds $remainingSleep
            if ($poked) {
                Write-OrchestratorLog "POKE_WAKE at poll sleep (remaining=${remainingSleep}s)"
            }
        }
    } else {
        $hasWork = ($counts.CoderWorkload -gt 0) -or ($counts.ReviewerWorkload -gt 0) -or ($counts.Working -gt 0)
        $idleSleep = if ($hasWork) { 120 } else { $PollIntervalSeconds }
        $remainingIdleSeconds = if ($idleStartTime) { [math]::Max(0, [math]::Round(($IdleTimeoutMinutes * 60) - ((Get-Date) - $idleStartTime).TotalSeconds)) } else { $idleSleep }
        $idleSleep = [math]::Min($idleSleep, $remainingIdleSeconds)
        if ($idleSleep -gt 0) {
            Write-OrchestratorLog "IDLE_SLEEP duration=${idleSleep}s iteration=$i hasWork=$hasWork"
            $poked = Wait-PokeOrSeconds -RepoDir $RepoDir -Seconds $idleSleep
            if ($poked) {
                Write-OrchestratorLog "POKE_WAKE at idle sleep (remaining=${idleSleep}s)"
            }
        }
    }

    Write-IterationErrorSummary
    }
} catch {
    Write-Host "  ⚠ Main loop crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-OrchestratorLog "MAIN_LOOP_CRASH error='$($_.Exception.Message)' stack='$($_.ScriptStackTrace)'" -Level ERROR
    Write-OrchestratorLog "ORCHESTRATOR_FATAL_CRASH type='$($_.Exception.GetType().Name)' message='$($_.Exception.Message -replace "'", "''")' stack='$($_.ScriptStackTrace -replace "'", "''")'" -Level ERROR
    foreach ($ns in @($script:activeStreams.Keys)) {
        $streamDir = $script:activeStreams[$ns].Path
        $sentinel = @{
            exitCode   = -1
            finishedAt = (Get-Date -Format 'o')
            reason     = "crash-recovery"
            namespace  = $ns
            stream     = $script:activeStreams[$ns].Id
        } | ConvertTo-Json -Compress
        try { $sentinel | Set-Content (Join-Path $streamDir ".complete") -Encoding utf8 -NoNewline -ErrorAction Stop } catch { Write-OrchestratorLog "SENTINEL_CRASH_WRITE_FAILED ns=$ns error='$($_.Exception.Message)'" -Level WARN }
    }
    foreach ($ns in @($script:activeStreams.Keys)) {
        $streamDir = $script:activeStreams[$ns].Path
        $role = $script:activeStreams[$ns].Role
        $destDir = if ($role -eq "coder") { "$RepoDir/Tasks/Code" } else { "$RepoDir/Tasks/Review" }
        try {
            Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $_.Name) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    Write-OrchestratorLog "CRASH_CLEANUP_SKIP_TERMINAL file='$($_.Name)' reason=already_in_terminal_queue"
                } else {
                    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force -ErrorAction SilentlyContinue
                }
            }
            $__isLaneCrash = $false
            for ($__ci = 0; $__ci -lt $script:persistentLanes.Count; $__ci++) {
                if ($script:persistentLanes[$__ci].Id -eq $script:activeStreams[$ns].Id) {
                    $__isLaneCrash = $true
                    $script:persistentLanes[$__ci].Idle = $true
                    Write-OrchestratorLog "LANE_CRASH_IDLE lane=$($script:activeStreams[$ns].Id)"
                    break
                }
            }
            if (-not $__isLaneCrash) {
                Remove-Stream -StreamDir $streamDir -AgentId $script:activeStreams[$ns].Id
            }
        } catch { Write-OrchestratorLog "STREAM_RESCUE_ERROR ns=$ns error='$($_.Exception.Message)'" -Level WARN }
    }
    try { if (Test-Path "Function:\Disconnect-Executor") { Disconnect-Executor } } catch { Write-OrchestratorLog "DISCONNECT_EXECUTOR_CRASH error='$($_.Exception.Message)'" -Level WARN }
    try { Write-AgentHeartbeat -AgentId "orchestrator-$InstanceId" } catch { Write-OrchestratorLog "HEARTBEAT_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN }
    try { Remove-Item (Join-Path $RepoDir "Tasks/Logs/.orchestrator-$InstanceId-pid") -Force -ErrorAction SilentlyContinue } catch { Write-OrchestratorLog "ORCHESTRATOR_PID_REMOVE_FAILED error='$($_.Exception.Message)'" -Level WARN }
    try { Remove-Item (Join-Path $RepoDir "Tasks/Logs/.orchestrator-active") -Force -ErrorAction SilentlyContinue } catch { Write-OrchestratorLog "ORCHESTRATOR_ACTIVE_REMOVE_FAILED error='$($_.Exception.Message)'" -Level WARN }
    # Merge worktree modules on crash
    foreach ($__cm in $script:worktreeModules) { try { Remove-WorktreeModule -RepoDir $RepoDir -Module $__cm } catch { Write-OrchestratorLog "WORKTREE_MODULE_CRASH_MERGE_FAILED module=$($__cm.ModuleId) error='$($_.Exception.Message)'" -Level WARN } }
    $exitKind = "crashed"
}

# Merge and remove worktree modules (all lanes should be idle at exit)
foreach ($__xm in $script:worktreeModules) {
    try {
        Remove-WorktreeModule -RepoDir $RepoDir -Module $__xm
    } catch {
        Write-OrchestratorLog "WORKTREE_MODULE_EXIT_MERGE_FAILED module=$($__xm.ModuleId) error='$($_.Exception.Message)'" -Level WARN
    }
}

$finalCounts = Get-TaskCounts
if ($exitKind -notin @("stopped", "drain-timeout", "stalled")) {
    $allEmpty = ($finalCounts.RootCoder -eq 0) -and ($finalCounts.Review -eq 0) -and ($finalCounts.Working -eq 0)
    if (-not $allEmpty) {
        Write-Host "`n⚠ Final drain check failed:" -ForegroundColor Yellow
        Write-Host "  Tasks/Code/:    $($finalCounts.RootCoder) files" -ForegroundColor Yellow
        Write-Host "  Tasks/Review/:  $($finalCounts.Review) files" -ForegroundColor Yellow
        Write-Host "  Tasks/Working/: $($finalCounts.Working) subdirs with files" -ForegroundColor Yellow
        exit 1
    }
}

if ((Test-Path "Function:\Disconnect-Executor") -and $script:executorDisconnectOnExit) {
    Disconnect-Executor
}

$resvPath = Join-Path "$RepoDir\Tasks" "Logs\.reservations.json"
if (Test-Path $resvPath) { Remove-Item $resvPath -Force -ErrorAction SilentlyContinue }
try { Remove-Item (Join-Path $RepoDir "Tasks/Logs/.orchestrator-active") -Force -ErrorAction SilentlyContinue } catch { Write-OrchestratorLog "ORCHESTRATOR_ACTIVE_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN }

if (-not $sessionStart -and (Test-Path (Join-Path $RepoDir "Tasks/Logs/session-start-orchestrator-$InstanceId.log"))) {
    try { $sessionStart = [datetime]::ParseExact((Get-Content (Join-Path $RepoDir "Tasks/Logs/session-start-orchestrator-$InstanceId.log") -Raw).Trim(), 'o', $null) } catch { Write-OrchestratorLog "SESSION_START_PARSE_FAILED error='$($_.Exception.Message)'" -Level WARN }
}
$elapsedTotal = if ($sessionStart) { [math]::Round(((Get-Date).ToUniversalTime() - $sessionStart.ToUniversalTime()).TotalSeconds, 0) } else { 0 }
Write-OrchestratorLog "ORCHESTRATOR_EXIT exit_kind=$exitKind elapsed=$elapsedTotal instance=$InstanceId"
Write-OrchestratorExitMarker -RepoDir $RepoDir -ExitKind $exitKind -ElapsedTotal $elapsedTotal
$exitLabel = switch ($exitKind) {
    "stopped"        { "Stop signal received" }
    "drain-timeout"  { "Drain timeout — some streams may still be running" }
    "crashed"        { "Main loop crashed" }
    "max-iterations" { "Max iterations reached — remaining streams rescued" }
    "stalled"        { "Stall limit reached — no queue progress" }
    default          { "No tasks remain across all queues" }
}
Write-Host "`n[DONE] $exitLabel" -ForegroundColor Green

if ($exitKind -in @("clean", "stopped", "drain-timeout", "stalled")) {
    $pidArchiveDir = Join-Path $RepoDir "Tasks/Complete/PID"
    $null = New-Item -ItemType Directory -Path $pidArchiveDir -Force
    $logName = "orchestrator-$PID.log"
    $activeLogDir = "$RepoDir/Tasks/Logs"
    $activePath = Join-Path $activeLogDir $logName
    if (Test-Path $activePath) {
        $archivePath = Join-Path $pidArchiveDir $logName
        try {
            Move-Item -LiteralPath $activePath -Destination $archivePath -Force -ErrorAction Stop
            Write-OrchestratorLog "LOG_ARCHIVED from=$activePath to=$archivePath" -Level INFO
            Write-Host "  Log archived to Tasks/Complete/PID/$logName" -ForegroundColor DarkGray
        } catch {
            Write-OrchestratorLog "LOG_ARCHIVE_FAILED from=$activePath error=$($_.Exception.Message)" -Level WARN
            Write-Host "  ⚠ Log archive skipped (file in use): Tasks/Logs/$logName" -ForegroundColor Yellow
        }
    }
}

if (-not $NoAuditPrompt -and $exitKind -eq "clean") {
    Write-Host ""
    Write-Host "Queues are empty. Run an Alignment Audit to check for codebase drift?" -ForegroundColor Yellow
    Write-Host "  Invoke-Pester Tests/ -Tag Regression-Only   (or press Enter to skip)" -ForegroundColor DarkGray
}

if ($exitKind -eq "max-iterations") {
    $finalCounts = Get-TaskCounts
    $allEmpty = ($finalCounts.RootCoder -eq 0) -and ($finalCounts.Review -eq 0) -and ($finalCounts.Working -eq 0)
    if (-not $allEmpty) {
        Write-OrchestratorLog "ORCHESTRATOR_INCOMPLETE exit_kind=$exitKind coder=$($finalCounts.RootCoder) review=$($finalCounts.Review) working=$($finalCounts.Working)" -Level WARN
        $continueFile = Join-Path $RepoDir "Tasks/Logs/.orchestrator-continue"
        try { Set-Content $continueFile -Value "true" -Encoding utf8 -NoNewline -ErrorAction Stop } catch { Write-OrchestratorLog "CONTINUE_FILE_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN }
        exit 15
    }
}

exit 0

}


if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Start-Orchestrator
}
