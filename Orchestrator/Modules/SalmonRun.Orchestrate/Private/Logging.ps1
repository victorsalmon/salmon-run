# Logging.ps1
# Structured error collector and logging functions

$script:iterationErrors = @()

# ─── Fallback functions for SalmonRun.AgentLifecycle dependency ──
# The orchestrator module optionally depends on SalmonRun.AgentLifecycle
# for heartbeat/pid/aliveness tracking. If that module isn't loaded,
# these fallback functions provide basic file-based tracking.

if (-not (Get-Command Write-AgentPidFile -ErrorAction SilentlyContinue)) {
    function Write-AgentPidFile {
        param([string]$AgentId)
        $dir = Join-Path $script:RepoRoot "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $dir -Force
        $PID.ToString() | Out-File (Join-Path $dir "$AgentId.pid") -Encoding utf8 -NoNewline
    }
}
if (-not (Get-Command Write-AgentHeartbeat -ErrorAction SilentlyContinue)) {
    function Write-AgentHeartbeat {
        param([string]$AgentId)
        $dir = Join-Path $script:RepoRoot "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $dir -Force
        [datetime]::UtcNow.ToString('o') | Out-File (Join-Path $dir "$AgentId.heartbeat") -Encoding utf8 -NoNewline
    }
}
if (-not (Get-Command Test-AgentAlive -ErrorAction SilentlyContinue)) {
    function Test-AgentAlive {
        param([string]$AgentId)
        $dir = Join-Path $script:RepoRoot "Tasks/Logs/agents"
        $pidFile = Join-Path $dir "$AgentId.pid"
        $hbFile = Join-Path $dir "$AgentId.heartbeat"
        $processId = if (Test-Path $pidFile) { (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)?.Trim() } else { $null }
        $pidNum = Convert-PidSafe -Value $processId
        $alive = $pidNum -and (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)
        $hb = if (Test-Path $hbFile) { (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue)?.Trim() -as [datetime] } else { $null }
        $stale = $alive -and $hb -and (([datetime]::UtcNow) - $hb.ToUniversalTime()).TotalMinutes -ge 15
        return @{ Alive = $alive -eq $true; Stale = $stale }
    }
}
if (-not (Get-Command Clear-StaleAgentFiles -ErrorAction SilentlyContinue)) {
    function Clear-StaleAgentFiles {
        param(
            [int]$HeartbeatStaleThresholdSeconds = 120,
            [switch]$RemoveLogs
        )
        $repoRoot = Get-InterclawRepoRoot
        $dir = Join-Path $repoRoot "Tasks/Logs/agents"
        if (-not (Test-Path $dir)) { return [PSCustomObject]@{ RemovedCount = 0; RemovedFiles = @() } }
        $removedFiles = [System.Collections.Generic.List[string]]::new()
        Get-ChildItem "$dir\*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
            $processId = (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue)?.Trim()
            $pidNum = Convert-PidSafe -Value $processId
            if ($pidNum -and -not (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                $removedFiles.Add("agent=$($_.BaseName) type=pid reason=process-dead")
                foreach ($ext in @('.heartbeat', '.stdout', '.stderr', '.mode', '.log')) {
                    $p = Join-Path $dir "$($_.BaseName)$ext"
                    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; $removedFiles.Add("agent=$($_.BaseName) type=$ext reason=process-dead") }
                }
            }
        }
        return [PSCustomObject]@{ RemovedCount = $removedFiles.Count; RemovedFiles = $removedFiles.ToArray() }
    }
}

function Write-OrchestratorLog {
    param($Message, [string]$Level = "INFO", [string]$Agent = "orchestrator", [string]$Phase = "orchestrator")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "{`"timestamp`":`"$ts`",`"level`":`"$Level`",`"agent`":`"$Agent`",`"phase`":`"$Phase`",`"message`":`"$($Message -replace '"','\"')`",`"runId`":`"$env:INTERCLAW_RUN_ID`"}"
    $logPath = if ($script:orchLogPath) { $script:orchLogPath } else {
        $repoRoot = $script:RepoRoot
        Join-Path "$repoRoot/Tasks/Logs" "orchestrator-$PID-fallback.log"
    }
    try {
        if ($logPath) { Add-Content -Path $logPath -Value $entry -Encoding utf8 }
    } catch {
        Write-Host "[$Level] [$Agent] $Message" -ForegroundColor DarkGray
    }
}

function Write-OrchestratorLogSafe {
    param($Message, [string]$Level = "INFO", [string]$Agent = "orchestrator", [string]$Phase = "orchestrator")
    try {
        $null = Get-Command Write-OrchestratorLog -ErrorAction SilentlyContinue
        if ($?) {
            Write-OrchestratorLog $Message -Level $Level -Agent $Agent -Phase $Phase
        } else {
            Write-Host "[$Level] [$Agent] $Message" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "[$Level] [$Agent] $Message (fallback)" -ForegroundColor DarkGray
    }
}

function Write-OrchestratorExitMarker {
    param([string]$RepoDir, [string]$ExitKind = "unknown", [int]$ElapsedTotal = 0)
    if (-not $RepoDir) { return }
    $plainLog = Join-Path $RepoDir "Tasks/Logs" "orchestrator-$PID.log"
    $marker = "ORCHESTRATOR_EXIT exit_kind=$ExitKind elapsed=$ElapsedTotal runId=$env:INTERCLAW_RUN_ID"
    try {
        Add-Content -Path $plainLog -Value $marker -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {
        Write-Host "EXIT_MARKER_FAILED marker='$marker'" -ForegroundColor DarkGray
    }
}

function Get-StreamRuntimeEstimate {
    param([string]$RepoDir, [hashtable]$ActiveStreams = @{})
    $avg = 300
    $startTimes = $ActiveStreams.Values | Where-Object { $_.StartTime } | ForEach-Object { $_.StartTime }
    if (-not $startTimes) { return $null }
    $oldest = ($startTimes | Sort-Object | Select-Object -First 1)
    $eta = $oldest.AddSeconds($avg)
    return $eta.ToString('o')
}

function Write-OrchestratorLiveStatus {
    param([string]$RepoDir, [int]$InstanceId = 1, [PSCustomObject]$Counts, [hashtable]$ActiveStreams = @{})
    if (-not $RepoDir) { return }
    $liveFile = Join-Path $RepoDir "Tasks/Logs/orchestrator-live.json"
    $active = [System.Collections.Generic.List[object]]::new()
    if ($ActiveStreams) {
        foreach ($ns in $ActiveStreams.Keys) {
            $s = $ActiveStreams[$ns]
            $active.Add([PSCustomObject]@{
                Id        = $s.Id
                Pid       = if ($s.Pid) { $s.Pid } else { $null }
                Role      = $s.Role
                Namespace = $ns
                Status    = $s.Status
                StartTime = if ($s.StartTime) { $s.StartTime.ToString('o') } else { $null }
            })
        }
    }
    $status = [PSCustomObject]@{
        timestamp     = (Get-Date -Format 'o')
        pid           = $PID
        instanceId    = $InstanceId
        code          = if ($Counts) { $Counts.RootCoder } else { 0 }
        review        = if ($Counts) { $Counts.Review } else { 0 }
        handoff       = if ($Counts) { $Counts.Handoff } else { 0 }
        working       = if ($Counts) { $Counts.Working } else { 0 }
        failed        = if ($Counts) { $Counts.Failed } else { 0 }
        manual        = if ($Counts) { $Counts.Manual } else { 0 }
        todo          = if ($Counts) { $Counts.ToDo } else { 0 }
        paused        = if ($Counts) { $Counts.Paused } else { 0 }
        blocked       = if ($Counts) { $Counts.Blocked } else { 0 }
        complete_files = if ($Counts) { $Counts.CompleteFiles } else { 0 }
        complete_dirs  = if ($Counts) { $Counts.CompleteDirs } else { 0 }
        nextExpected  = Get-StreamRuntimeEstimate -RepoDir $RepoDir -ActiveStreams $ActiveStreams
        activeStreams = $active
        healthy       = $true
    }
    try {
        $status | ConvertTo-Json -Depth 3 | Set-Content $liveFile -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
    } catch {
        Write-OrchestratorLog "LIVE_STATUS_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN
    }
}

function Register-LaneCompletion {
    param([string]$RepoDir, [string]$Lane, [string]$File, [string]$Outcome)
    if (-not $RepoDir -or -not $Lane -or -not $File) { return }
    $compFile = Join-Path $RepoDir "Tasks/Logs/.lane-completions.jsonl"
    $entry = [PSCustomObject]@{
        timestamp = (Get-Date -Format 'o')
        lane      = $Lane
        file      = $File
        outcome   = if ($Outcome) { $Outcome } else { 'complete' }
    } | ConvertTo-Json -Compress
    try {
        $entry | Out-File -FilePath $compFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {
        Write-OrchestratorLog "LANE_COMPLETION_APPEND_FAILED lane='$Lane' file='$File' error='$($_.Exception.Message)'" -Level WARN
    }
}

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

# Exit code constants
$script:ExitCodeFileLocked = 10
$script:ExitCodeNoWork    = 11
$script:ExitCodeGitLock   = 12
$script:ExitCodePushFailed = 13
$script:ExitCodeSkipped   = 14
$script:ExitCodeContextLimit = 99

# Label map for outcome reporting
$script:LabelMap = @{
    0                                  = "completed"
    $script:ExitCodeFileLocked         = "collision-file-locked"
    $script:ExitCodeNoWork             = "collision-no-work"
    $script:ExitCodeGitLock            = "collision-git-lock"
    $script:ExitCodePushFailed         = "collision-push-failed"
    $script:ExitCodeSkipped            = "skipped"
}
