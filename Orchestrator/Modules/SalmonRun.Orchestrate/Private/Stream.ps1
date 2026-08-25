function Write-AtomicJson {
    <#
    .SYNOPSIS
        Writes JSON to a file atomically via temp-file + rename.
    #>
    param(
        [string]$Path,
        [object]$InputObject
    )
    $tmpPath = "$Path.tmp"
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    try {
        $json = if ($InputObject -is [string]) { $InputObject } else { $InputObject | ConvertTo-Json -Compress }
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        if (-not (Test-Path $tmpPath)) { throw "Write-AtomicJson temp file not created: $tmpPath" }
        [System.IO.File]::Move($tmpPath, $Path, $true)
    } catch {
        if (Test-Path $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-NextStreamId {
    param([string]$WorkingDir)
    $maxId = 0
    $dirs = Get-ChildItem "$WorkingDir/stream-*" -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if ($d.Name -match '^stream-(\d+)$') {
            $id = [int]$Matches[1]
            if ($id -gt $maxId) { $maxId = $id }
        }
    }
    return $maxId + 1
}

function New-Stream {
    param([string]$WorkingDir, [string]$Namespace, [string]$Role)
    $streamId = Get-NextStreamId -WorkingDir $WorkingDir
    $streamDir = Join-Path $WorkingDir "stream-$streamId"
    $null = New-Item -ItemType Directory -Path $streamDir -Force
    Write-AtomicJson -Path (Join-Path $streamDir "stream.json") -InputObject @{ Id = $streamId; Namespace = $Namespace; Role = $Role; Module = 'main'; Created = [datetime]::UtcNow.ToString('o') }
    return @{ Id = $streamId; Path = $streamDir; Namespace = $Namespace; Role = $Role; Module = 'main'; Pid = $null }
}

function Remove-Stream {
    param([string]$StreamDir, [string]$AgentId)
    if (-not (Test-Path $StreamDir)) { return }
    Remove-Item $StreamDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($AgentId) {
        $agentDir = Join-Path (Split-Path (Split-Path $StreamDir)) "Logs/agents"
        Remove-Item (Join-Path $agentDir "$AgentId.pid") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $agentDir "$AgentId.heartbeat") -Force -ErrorAction SilentlyContinue
    }
}

function Get-StreamStatus {
    param([string]$StreamDir)
    if (-not (Test-Path $StreamDir)) { return $null }
    $metaPath = Join-Path $StreamDir "stream.json"
    $meta = if (Test-Path $metaPath) { Get-Content $metaPath -Raw | ConvertFrom-Json } else { $null }
    $lastAction = $null
    $planFiles = Get-ChildItem "$StreamDir\*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($planFiles) {
        $content = Get-Content $planFiles[0].FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match '- Status: (\S+)') {
            $status = $Matches[1]
            $agentMatch = [regex]::Match($content, '- Agent: (\S+)')
            $agent = if ($agentMatch.Success) { $agentMatch.Groups[1].Value } else { "unknown" }
            $lastAction = "[$agent] Status=$status"
        }
    }
    if (-not $lastAction) {
        $logPath = Join-Path $StreamDir "stream.log"
        if (Test-Path $logPath) { $lastAction = (Get-Content $logPath -TotalCount 1 -ErrorAction SilentlyContinue) }
    }
    $pidAlive = $false
    $metaPid = Convert-PidSafe -Value $meta.Pid
    if ($meta -and $metaPid) { $pidAlive = $null -ne (Get-Process -Id $metaPid -ErrorAction SilentlyContinue) }
    return @{ Id = if ($meta) { $meta.Id } else { $null }; Namespace = if ($meta) { $meta.Namespace } else { $null }; Role = if ($meta) { $meta.Role } else { $null }; LastAction = $lastAction; PidAlive = $pidAlive }
}

function Add-FileToStream {
    param([string]$StreamDir, [string]$SourcePath, [string]$Role = 'coder')
    if (-not (Test-Path $SourcePath)) { return }
    $dest = Join-Path $StreamDir (Split-Path $SourcePath -Leaf)
    Move-Item -LiteralPath $SourcePath -Destination $dest -Force
    # Reset stale lock headers so STREAM_STATUS doesn't see "Status: released"
    # and sweep the freshly dispatched file back to Code/ (redispatch loop fix).
    # Reviewer lanes must preserve the coder's lock header (chain of possession),
    # so the reset applies to coder lanes only.
    if ($Role -eq 'coder') {
        Reset-PlanLockHeader -FilePath $dest
    }
}

if (-not (Get-Command Test-PlanHeaderContent -ErrorAction SilentlyContinue)) {
    function Test-PlanHeaderContent {
        param([AllowEmptyString()][string]$Content)
        if (-not $Content) { return $false }
        if ($Content -match '(?m)^\s*#\s+(?:Session\s+Plan|Session|Plan):\s+.+$') { return $true }
        if ($Content -match '(?m)^\s*#\s+Scheduled Task:\s+.+$' -and
            $Content -match '(?m)^\s*\*\*Type\*\*:\s*scheduled-task\b' -and
            $Content -match '(?m)^\s*\*\*Schedule ID\*\*:\s*\S+') { return $true }
        $plainTitle = $Content -match '(?m)^\s*#\s+[^#\r\n].+$'
        if (-not $plainTitle) { return $false }
        $metadataSignals = @(
            ($Content -match '(?m)^\s*\*\*Repo:?\*\*:?\s*.+$'),
            ($Content -match '(?m)^\s*\*\*Date:?\*\*:?\s*.+$'),
            ($Content -match '(?m)^\s*\*\*Origin:?\*\*:?\s*Plan-mode session\b'),
            ($Content -match '(?m)^\s*##\s+(?:Context|Overview|Task(?:s)?)\b')
        ) | Where-Object { $_ }
        return $metadataSignals.Count -ge 2
    }
    function ConvertTo-CanonicalPlanHeader {
        param([AllowEmptyString()][string]$Content)
        if (-not $Content) { return $Content }
        $normalized = $Content -replace '(?m)^\s*#\s+(?:Session\s+Plan|Session|Plan):\s+(.+)$', '# Session Plan: $1'
        if ($normalized -match '(?m)^\s*#\s+Session\s+Plan:\s+.+$') { return $normalized }
        $isScheduledTask = (Test-PlanHeaderContent -Content $normalized) -and
            ($normalized -match '(?m)^\s*#\s+Scheduled Task:\s+.+$')
        if ($isScheduledTask) {
            if ($normalized -match '(?m)^\s*\*\*Status\*\*:\s*$' -and
                $normalized -match '(?m)^\s*\*\*Attempts\*\*:\s*\d+\s+ready\s*$') {
                $normalized = $normalized -replace '(?m)^\s*(\*\*Status\*\*):\s*$', '**Status**: ready'
                $normalized = $normalized -replace '(?m)^\s*(\*\*Attempts\*\*:\s*\d+)\s+ready\s*$', '${1}'
            }
            return $normalized
        }
        $title = [regex]::Match($normalized, '(?m)^\s*#\s+([^#\r\n].+?)\s*$')
        if ($title.Success -and (Test-PlanHeaderContent -Content $normalized)) {
            $canonical = '# Session Plan: ' + $title.Groups[1].Value.Trim()
            return $normalized.Substring(0, $title.Index) + $canonical + $normalized.Substring($title.Index + $title.Length)
        }
        return $normalized
    }
}

function Test-LanePlanFileIntegrity {
    <#
    .SYNOPSIS
        Verifies a plan file's lock header after dispatch into a lane
        (orchestrator-tooling-4). A corrupted/header-only plan must never reach a
        lane agent: if the plan title/body is missing or a present
        **Lock** block has a blank Agent:, restore the body from git HEAD, then
        from history (git log --all), before the lane agent starts.
    .OUTPUTS
        [bool] $true when the file is usable, $false when it could not be restored
        (caller should quarantine/requeue the file).
    #>
    param(
        [string]$RepoDir,
        [string]$FilePath,
        [string]$LaneId
    )
    if (-not (Test-Path $FilePath)) { return $false }
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    $hasBody = Test-PlanHeaderContent -Content $content
    $agentOk = $true
    if ($content -match '(?m)^\*\*Lock\*\*') {
        if (-not ($content -match '(?m)^- Agent:\s*\S+')) { $agentOk = $false }
    }
    if ($hasBody -and $agentOk) { return $true }

    # Corrupted (header-only or blank Agent:) — restore from git.
    # Search ALL paths the file has ever lived at (current path, Code/, Review/,
    # Working/lane-*/, Failed/) to find the original header-full version.
    try {
        $fileName = Split-Path $FilePath -Leaf
        $relSpec = try { [System.IO.Path]::GetRelativePath($RepoDir, $FilePath).Replace('\\', '/') } catch { $FilePath }
        $searchPaths = @($relSpec, "Tasks/Code/$fileName", "Tasks/Review/$fileName", "Tasks/Failed/$fileName")
        $workingDir = Join-Path $RepoDir "Tasks/Working"
        if (Test-Path $workingDir) {
            Get-ChildItem $workingDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $searchPaths += "Tasks/Working/$($_.Name)/$fileName"
            }
        }
        $restored = $null
        $restoredFrom = $null
        foreach ($searchPath in $searchPaths) {
            if ($restored) { break }
            $candidates = git -C $RepoDir log --all --format='%H' -- "$searchPath" 2>$null
            foreach ($candidate in $candidates) {
                if (-not $candidate) { continue }
                $candidateContent = git -C $RepoDir show "$candidate`:$searchPath" 2>$null
                if ($candidateContent -and (Test-PlanHeaderContent -Content $candidateContent)) {
                    $restored = ConvertTo-CanonicalPlanHeader -Content $candidateContent
                    $restoredFrom = "$searchPath@($candidate.Substring(0,8))"
                    break
                }
            }
        }
        if ($restored) {
            Set-Content -LiteralPath $FilePath -Value $restored -Encoding utf8 -NoNewline
            Write-OrchestratorLog "LANE_PLAN_RESTORED file='$fileName' lane='$LaneId' source='$restoredFrom' reason=corrupt-header"
            return $true
        }
        Write-OrchestratorLog "LANE_PLAN_UNRESTORABLE file='$fileName' lane='$LaneId' reason=no-header-full-version-in-git-history" -Level WARN
    } catch {
        Write-OrchestratorLog "LANE_PLAN_RESTORE_FAILED file='$FilePath' lane='$LaneId' error='$($_.Exception.Message)'" -Level WARN
    }
    return $false
}

function Initialize-PersistentLanes {
    <#
    .SYNOPSIS
        Pre-creates persistent swim lanes that survive stream completion.
        Coder lanes pick from the Code queue; reviewer lanes from the Review queue.
    #>
    param(
        [string]$WorkingDir,
        [int]$CoderCount = 9,
        [int]$ReviewerCount = 1
    )
    $lanes = @()
    $null = New-Item -ItemType Directory -Path $WorkingDir -Force -ErrorAction SilentlyContinue
    # Remove any existing lane directories for a clean slate
    Get-ChildItem "$WorkingDir/lane-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    for ($i = 1; $i -le $CoderCount; $i++) {
        $laneId = "lane-coder-$i"
        $laneDir = Join-Path $WorkingDir $laneId
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        Write-AtomicJson -Path (Join-Path $laneDir "lane.json") -InputObject @{ Id = $laneId; Role = "coder"; Index = $i; Created = [datetime]::UtcNow.ToString('o') }
        $lanes += @{ Id = $laneId; Path = $laneDir; Role = "coder"; ModuleId = 'main'; Index = $i; Idle = $true }
    }
    for ($i = 1; $i -le $ReviewerCount; $i++) {
        $laneId = "lane-reviewer-$i"
        $laneDir = Join-Path $WorkingDir $laneId
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        Write-AtomicJson -Path (Join-Path $laneDir "lane.json") -InputObject @{ Id = $laneId; Role = "reviewer"; Index = $i; Created = [datetime]::UtcNow.ToString('o') }
        $lanes += @{ Id = $laneId; Path = $laneDir; Role = "reviewer"; ModuleId = 'main'; Index = $i; Idle = $true }
    }
    return $lanes
}

function Get-FreeLane {
    <#
    .SYNOPSIS
        Returns the first idle lane for the given role across ALL lane sources (main + modules), or $null if all busy.
        Includes a PID-aliveness guard to prevent duplicate dispatch: a lane
        that is marked Idle but has a live PID file with an alive process is
        NOT free (the Idle flag is stale — the process is still running).
    #>
    param([string]$Role, [array]$Lanes)
    foreach ($lane in $Lanes) {
        if (-not ($lane.Idle -and $lane.Role -eq $Role)) { continue }
        # PID-aliveness guard: check if a live process is still running for this lane.
        # This prevents duplicate dispatch when the Idle flag is stale (e.g., the
        # lane was marked idle by lane-recovery but the opencode process is still
        # running and writing to the plan file).
        $lanePidFile = Join-Path (Split-Path $lane.Path) "Logs/agents/$($lane.Id).pid"
        if (Test-Path $lanePidFile) {
            $lanePid = (Get-Content $lanePidFile -Raw -ErrorAction SilentlyContinue)?.Trim()
            $lanePidNum = Convert-PidSafe -Value $lanePid
            if ($lanePidNum -and (Get-Process -Id $lanePidNum -ErrorAction SilentlyContinue)) {
                # Process is alive — lane is NOT free. Fix the stale Idle flag.
                $lane.Idle = $false
                Write-OrchestratorLog "DUPLICATE_DISPATCH_GUARD lane='$($lane.Id)' pid=$lanePidNum alive=true idle_flag_was_stale=true" -Level WARN
                continue
            }
        }
        return $lane
    }
    return $null
}

function Invoke-DrainedLaneReclamation {
    <#
    .SYNOPSIS
        Reclaims persistent lanes whose opencode process is alive but idle (zero
        plan files, no .complete sentinel). This handles the case where the
        opencode `work-stream` command completes its task but the process stays
        alive in TUI mode instead of exiting — the orchestrator's
        HasExited-based completion detection never fires, and the heartbeat
        refresh loop keeps hbStale=false, so the standard drained-stream
        reclamation (which requires procDead OR hbStale) skips these lanes
        forever, exhausting dispatch capacity.

    .DESCRIPTION
        For each active stream that maps to a persistent lane:
        - Skip if a .complete sentinel exists (already handled).
        - Skip if plan files are present (lane is actively working).
        - Skip if the stream is younger than MinAgeSeconds (dispatch race window).
        - Otherwise: kill the live opencode process, mark the lane Idle=$true,
          clean up stream.json/.complete/heartbeat, clear used namespaces, and
          remove the stream from activeStreams.

        Returns the list of reclaimed namespace keys so the caller can remove
        them from activeStreams.
    #>
    param(
        [string]$RepoDir,
        [array]$Lanes,
        [hashtable]$ActiveStreams,
        [hashtable]$UsedNamespaces,
        [int]$MinAgeSeconds = 90
    )
    $reclaimed = [System.Collections.Generic.List[string]]::new()
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    foreach ($ns in @($ActiveStreams.Keys)) {
        $stream = $ActiveStreams[$ns]
        $streamDir = $stream.Path
        if (-not (Test-Path $streamDir)) { continue }
        # Skip if already marked complete
        if (Test-Path (Join-Path $streamDir ".complete")) { continue }
        # Skip if plan files are present — lane is actively working
        $planFiles = @(Get-ChildItem "$streamDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
        if ($planFiles.Count -gt 0) { continue }
        # Only reclaim persistent lanes (not transient stream-N dirs)
        $laneEntry = $null
        for ($__li = 0; $__li -lt $Lanes.Count; $__li++) {
            if ($Lanes[$__li].Id -eq $stream.Id) { $laneEntry = $Lanes[$__li]; break }
        }
        if (-not $laneEntry) { continue }
        # Dispatch-race guard: don't reclaim a lane that was just dispatched
        $startTime = if ($stream.StartTime -is [datetime]) { $stream.StartTime } elseif ($stream.StartTime) { [datetime]$stream.StartTime } else { $null }
        $streamAge = if ($startTime) { ((Get-Date) - $startTime).TotalSeconds } else { 0 }
        if ($streamAge -lt $MinAgeSeconds) {
            Write-OrchestratorLog "DRAINED_LANE_SKIP_YOUNG lane=$($stream.Id) ns=$ns age=$([math]::Round($streamAge,0))s min=$MinAgeSeconds"
            continue
        }
        # Kill the live opencode process (it's sitting idle at the TUI prompt)
        $killedPid = $null
        if ($stream.Task -and $stream.Task.Handle -and -not $stream.Task.Handle.HasExited) {
            $killedPid = $stream.Task.Handle.Id
            try { Stop-ProcessTree -ProcessId $killedPid -Force } catch {
                Write-OrchestratorLog "DRAINED_LANE_KILL_FAILED lane=$($stream.Id) pid=$killedPid error='$($_.Exception.Message)'" -Level WARN
            }
        } elseif ($stream.Task -and $stream.Task.Pid) {
            $killedPid = $stream.Task.Pid
            try { Stop-ProcessTree -ProcessId $killedPid -Force } catch {
                Write-OrchestratorLog "DRAINED_LANE_KILL_FAILED lane=$($stream.Id) pid=$killedPid error='$($_.Exception.Message)'" -Level WARN
            }
        }
        # Mark the lane idle so Get-FreeLane can reuse it
        $laneEntry.Idle = $true
        # Clean up stream state files
        $streamJson = Join-Path $streamDir "stream.json"
        if (Test-Path $streamJson) { Remove-Item -LiteralPath $streamJson -Force -ErrorAction SilentlyContinue }
        $completeFile = Join-Path $streamDir ".complete"
        if (Test-Path $completeFile) { Remove-Item -LiteralPath $completeFile -Force -ErrorAction SilentlyContinue }
        # Clear used namespaces for this stream's files
        $streamNs = $stream.Namespace
        if ($UsedNamespaces -and (Get-Command Clear-UsedNamespacesForFiles -ErrorAction SilentlyContinue)) {
            try { Clear-UsedNamespacesForFiles -RepoDir $RepoDir -UsedNamespaces $UsedNamespaces -NamespaceFilter $streamNs } catch { }
        }
        Write-OrchestratorLog "DRAINED_LANE_RECLAIMED lane=$($stream.Id) ns=$ns pid=$killedPid age=$([math]::Round($streamAge,0))s — live-but-idle opencode process killed, lane marked idle"
        $reclaimed.Add($ns)
    }
    # Remove reclaimed streams from activeStreams so dispatch can reuse the lanes
    foreach ($ns in $reclaimed) {
        $ActiveStreams.Remove($ns) | Out-Null
    }
    return $reclaimed
}

function Invoke-SentinelLaneReclamation {
    <#
    .SYNOPSIS
        Reclaims persistent lanes where the agent wrote a .complete sentinel
        but opencode's `run --command` mode kept the process alive in TUI mode.

    .DESCRIPTION
        The work-stream template (step 7) writes a .complete sentinel when
        done. However, opencode's `run --command` mode keeps the process
        alive in TUI mode after the command finishes, so HasExited-based
        completion never fires. Every other reclamation path skips
        .complete-bearing streams:
        - Phase B completion requires HasExited = true
        - Drained-stream reclamation skips .complete (line ~1918)
        - Invoke-DrainedLaneReclamation skips .complete (line ~311)
        This function detects .complete-bearing streams with LIVE processes,
        kills the lingering TUI process, and returns the reclaimed namespaces
        with their sentinel exit codes so the caller (Phase B) can process
        them through the normal completed/failed path.

        For each active stream:
        - Skip if no .complete sentinel exists.
        - Skip if the process has already exited (HasExited-based path will
          handle it).
        - Skip if the stream is younger than MinAgeSeconds (dispatch race
          window -- the agent may still be writing the sentinel).
        - Otherwise: kill the live process, record the sentinel exit code,
          and return the namespace for the caller to reclaim.

    .OUTPUTS
        List of hashtables: @{ Namespace = $ns; ExitCode = $exitCode }
    #>
    param(
        [hashtable]$ActiveStreams,
        [int]$MinAgeSeconds = 30
    )
    $reclaimed = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($ns in @($ActiveStreams.Keys)) {
        $stream = $ActiveStreams[$ns]
        $streamDir = $stream.Path
        if (-not (Test-Path $streamDir)) { continue }
        $sentinelPath = Join-Path $streamDir ".complete"
        if (-not (Test-Path $sentinelPath)) { continue }
        # Skip if the process has already exited -- HasExited-based completion
        # in Phase B will handle it via the normal path.
        $task = $stream.Task
        $hasExited = if ($task) {
            if (Get-Command Get-ExecutorTaskStatus -ErrorAction SilentlyContinue) {
                Get-ExecutorTaskStatus -Task $task
            }
            $task.HasExited
        } else { $true }
        if ($hasExited) { continue }
        # Dispatch-race guard: don't reclaim a lane that was just dispatched
        # (the agent may still be writing the sentinel).
        $startTime = if ($stream.StartTime -is [datetime]) { $stream.StartTime } elseif ($stream.StartTime) { [datetime]$stream.StartTime } else { $null }
        $streamAge = if ($startTime) { ((Get-Date) - $startTime).TotalSeconds } else { 0 }
        if ($streamAge -lt $MinAgeSeconds) {
            Write-OrchestratorLog "SENTINEL_LANE_SKIP_YOUNG ns=$ns stream=$($stream.Id) age=$([math]::Round($streamAge,0))s min=$MinAgeSeconds"
            continue
        }
        # Read the sentinel exit code (agent writes exitCode: 0 on success)
        $exitCode = 0
        try {
            $sentinelJson = Get-Content $sentinelPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $sentinelJson.exitCode) { $exitCode = [int]$sentinelJson.exitCode }
        } catch { $exitCode = 0 }
        # Kill the lingering opencode process (it's done, sitting at TUI prompt)
        if (Get-Command Stop-ExecutorTask -ErrorAction SilentlyContinue) {
            try { Stop-ExecutorTask -Task $task } catch {
                Write-OrchestratorLog "SENTINEL_LANE_KILL_FAILED ns=$ns stream=$($stream.Id) error='$($_.Exception.Message)'" -Level WARN
            }
        } elseif ($task -and $task.Handle -and -not $task.Handle.HasExited) {
            try { Stop-ProcessTree -ProcessId $task.Handle.Id -Force } catch {
                Write-OrchestratorLog "SENTINEL_LANE_KILL_FAILED ns=$ns stream=$($stream.Id) error='$($_.Exception.Message)'" -Level WARN
            }
        }
        Write-OrchestratorLog "SENTINEL_LANE_RECLAIMED ns=$ns stream=$($stream.Id) exitCode=$exitCode age=$([math]::Round($streamAge,0))s -- agent wrote .complete but opencode TUI stayed alive, killed and reclaiming"
        $reclaimed.Add(@{ Namespace = $ns; ExitCode = $exitCode })
        # Remove from ActiveStreams so the per-stream loop in Phase B does not
        # re-process the stream after the process has been killed.
        $ActiveStreams.Remove($ns) | Out-Null
    }
    return $reclaimed
}

function Test-PlanTerminalQueue {
    <#
    .SYNOPSIS
        Returns $true when a plan file with the same name already exists in a
        terminal queue (Tasks/Complete/, Tasks/Failed/, or Tasks/Archive/).
    .DESCRIPTION
        The recovery sweep must never re-queue a plan that has already reached
        a terminal queue. This helper checks all three terminal directories
        for a matching filename.
    #>
    param([string]$RepoDir, [string]$PlanName)
    if ([string]::IsNullOrWhiteSpace($PlanName)) { return $false }
    foreach ($queue in @('Complete', 'Failed', 'Archive')) {
        if (Test-Path (Join-Path $RepoDir "Tasks/$queue/$PlanName")) { return $true }
    }
    return $false
}

function Test-PlanTerminalStatus {
    <#
    .SYNOPSIS
        Returns $true when a plan's Status field indicates a terminal state
        (completed, complete, or voided) — the work is done or invalidated and
        the plan must not be re-dispatched as ready work.
    .DESCRIPTION
        Recognizes all three Status header formats used in the fleet:
        **Status**: X, - Status: X, and Status: X.
    #>
    param([string]$PlanContent)
    if ([string]::IsNullOrWhiteSpace($PlanContent)) { return $false }
    $terminalStatuses = @('completed', 'complete', 'voided')
    foreach ($status in $terminalStatuses) {
        if ($PlanContent -match "(?m)^\*\*Status\*\*:\s*$status\b") { return $true }
        if ($PlanContent -match "(?m)^- Status:\s*$status\b") { return $true }
        if ($PlanContent -match "(?m)^Status:\s*$status\b") { return $true }
    }
    return $false
}

function Invoke-LaneStateRecovery {
    <#
    .SYNOPSIS
        Scans persistent lane directories for stuck/corrupted state and recovers them.
        Called at the top of each orchestrator iteration to ensure lanes whose
        subprocesses crashed are marked idle again.

        Recovery conditions:
        - Lane has stream.json but its namespace is NOT in activeStreams (process died
          and completion handler never ran).
        - Lane has no stream.json and is not in activeStreams (crash during dispatch).
        - Lane has a stale .complete sentinel but no active stream.

        For each recovered lane:
        - Move any orphaned .md plan files back to Tasks/Code/ or Tasks/Review/.
        - Remove stream.json, stream.log, and .complete.
        - Mark the lane Idle=$true in the persistentLanes array.
    #>
    param(
        [string]$RepoDir,
        [array]$Lanes,
        [hashtable]$ActiveStreams
    )
    $recovered = 0
    foreach ($lane in $Lanes) {
        if ($lane.Idle) { continue }
        $laneDir = $lane.Path
        if (-not (Test-Path $laneDir)) { continue }

        $streamJson = Join-Path $laneDir "stream.json"
        $hasStreamJson = Test-Path $streamJson
        $hasComplete = Test-Path (Join-Path $laneDir ".complete")

        # Find the namespace key for this lane's current stream (if any)
        $laneNsKey = $null
        if ($hasStreamJson) {
            try {
                $meta = Get-Content $streamJson -Raw | ConvertFrom-Json
                $moduleId = if ($meta.Module) { $meta.Module } else { 'main' }
                $laneNsKey = "$moduleId|$($meta.Namespace)|$($meta.Role)"
            } catch {
                Write-OrchestratorLog "STREAM_META_PARSE_FAILED lane=$laneDir error='$($_.Exception.Message)'" -Level DEBUG
            }
        }

        # Check if this lane's stream is still active
        $isActive = $false
        if ($laneNsKey -and $ActiveStreams.ContainsKey($laneNsKey)) {
            $streamInfo = $ActiveStreams[$laneNsKey]
            # Verify the active stream's path matches this lane
            if ($streamInfo.Path -eq $laneDir) { $isActive = $true }
        }
        # Also check by path — stream.json may be missing but the lane
        # could still be tracked in ActiveStreams under its namespace key
        if (-not $isActive) {
            foreach ($nsKey in $ActiveStreams.Keys) {
                $streamInfo = $ActiveStreams[$nsKey]
                if ($streamInfo.Path -eq $laneDir) { $isActive = $true; break }
            }
        }
        # If the lane has a .complete sentinel, it finished — don't treat as active
        if ($hasComplete) { $isActive = $false }

        if ($isActive) { continue }

        # Live-agent guard: if the lane's agent process is still alive, the lane is
        # NOT stuck — the in-memory ActiveStreams state just lost track of it
        # (orchestrator restart, dispatch race, usedNamespaces cleared by a
        # concurrent rescue pass). Never recover a lane whose subprocess is running.
        $laneAgentId = $null
        if ($hasStreamJson -and $meta) {
            try { $laneAgentId = $meta.Id } catch {
                Write-OrchestratorLog "STREAM_META_READ_FAILED lane=$laneDir error='$($_.Exception.Message)'" -Level WARN
            }
        }
        if (-not $laneAgentId) {
            $lanePlanFiles = Get-ChildItem "$laneDir/*.md" -ErrorAction SilentlyContinue
            foreach ($pf in $lanePlanFiles) {
                $pfContent = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
                if ($pfContent -match '(?m)^- Agent: (\S+)') { $laneAgentId = $Matches[1]; break }
            }
        }
        $laneAlive = $null
        if ($laneAgentId) {
            try { $laneAlive = Test-AgentAlive -AgentId $laneAgentId } catch {
                Write-OrchestratorLog "LANE_HOLD_CHECK_FAILED lane='$($lane.Id)' agent=$laneAgentId error='$($_.Exception.Message)'" -Level WARN
            }
        }
        # Also check lane-level liveness files; agent id in plan file may differ from lane id
        if (-not $laneAlive -or $laneAlive.Stale) {
            try {
                $laneLevel = Test-AgentAlive -AgentId $lane.Id
                if ($laneLevel -and -not $laneLevel.Stale) {
                    $laneAlive = $laneLevel
                    Write-OrchestratorLog "LANE_HOLD lane='$($lane.Id)' reason='lane_level_liveness' agent=$laneAgentId"
                }
            } catch {
                Write-OrchestratorLog "LANE_LEVEL_PROBE_FAILED lane='$($lane.Id)' agent=$laneAgentId error='$($_.Exception.Message)'" -Level WARN
            }
        }
        # Explicit orchestrator-maintained lane files fallback: the orchestrator writes
        # Tasks/Logs/agents/<lane>.pid and <lane>.heartbeat at spawn (orchestrator-tooling-2).
        # Check them directly when Test-AgentAlive is unavailable or returned nothing.
        if (-not $laneAlive -or $laneAlive.Stale) {
            try {
                $lanePidFile = Join-Path (Split-Path (Split-Path $laneDir)) "Logs/agents/$($lane.Id).pid"
                $laneHbFile = Join-Path (Split-Path (Split-Path $laneDir)) "Logs/agents/$($lane.Id).heartbeat"
                $lanePid = if (Test-Path $lanePidFile) { (Get-Content $lanePidFile -Raw -ErrorAction SilentlyContinue)?.Trim() } else { $null }
                $lanePidNum = Convert-PidSafe -Value $lanePid
                $laneHbRaw = if (Test-Path $laneHbFile) { (Get-Content $laneHbFile -Raw -ErrorAction SilentlyContinue)?.Trim() } else { $null }
                $laneHb = $laneHbRaw -as [datetime]
                $laneProcAlive = $lanePidNum -and (Get-Process -Id $lanePidNum -ErrorAction SilentlyContinue)
                $laneHbFresh = $laneHb -and (([datetime]::UtcNow) - $laneHb.ToUniversalTime()).TotalMinutes -lt 5
                if ($laneProcAlive -or $laneHbFresh) {
                    $laneAlive = @{ Alive = $true; Stale = $false; Pid = $lanePidNum; HeartbeatAgeSeconds = if ($laneHb) { [math]::Round((([datetime]::UtcNow) - $laneHb.ToUniversalTime()).TotalSeconds) } else { 0 } }
                    Write-OrchestratorLog "LANE_HOLD lane='$($lane.Id)' reason='orchestrator_lane_files' pid=$lanePidNum hbFresh=$laneHbFresh"
                }
            } catch {
                Write-OrchestratorLog "LANE_HOLD_CHECK_FAILED lane='$($lane.Id)' fallback error='$($_.Exception.Message)'" -Level WARN
            }
        }
        if ($laneAlive) {
            $laneProcessAlive = $false
            if ($null -ne $laneAlive.ProcessAlive) { $laneProcessAlive = [bool]$laneAlive.ProcessAlive }
            elseif ($null -ne $laneAlive.Alive) { $laneProcessAlive = [bool]$laneAlive.Alive }
            if ($laneProcessAlive) {
                $lanePid = if ($null -ne $laneAlive.Pid) { $laneAlive.Pid } else { "unknown" }
                Write-OrchestratorLog "LANE_HOLD lane='$($lane.Id)' reason='agent_pid_alive' pid=$lanePid" -Level WARN
                continue
            }
            # Heartbeat-freshness guard: a dead PID with a recent heartbeat is a live transient shell, not a stuck lane.
            if ($null -ne $laneAlive.HeartbeatAgeSeconds -and $laneAlive.HeartbeatAgeSeconds -le 300) {
                Write-OrchestratorLog "LANE_HOLD lane='$($lane.Id)' reason='heartbeat_fresh' age=$($laneAlive.HeartbeatAgeSeconds)s" -Level WARN
                continue
            }
        }

        # Lane is NOT idle but has no active stream — it's stuck. Recover it.
        $role = $lane.Role
        $planFiles = Get-ChildItem "$laneDir/*.md" -ErrorAction SilentlyContinue
        foreach ($pf in $planFiles) {
            $pfContent = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
            # Terminal-state guard: never re-queue a plan that has already
            # reached a terminal queue (Complete/Failed/Archive) or whose
            # Status field marks it as done/voided. Delete the stale copy
            # from the lane dir and skip the move.
            if (Test-PlanTerminalQueue -RepoDir $RepoDir -PlanName $pf.Name) {
                Remove-Item -LiteralPath $pf.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "LANE_RECOVERY_SKIP_TERMINAL file='$($pf.Name)' lane='$($lane.Id)' reason=already_in_terminal_queue"
                continue
            }
            if (Test-PlanTerminalStatus -PlanContent $pfContent) {
                Remove-Item -LiteralPath $pf.FullName -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "LANE_RECOVERY_SKIP_STATUS file='$($pf.Name)' lane='$($lane.Id)' reason=terminal_status"
                continue
            }
            # A released file in a coder lane is completed work — route to Review/
            # not Code/ (tempo-quarantine-loop fix: prevents re-dispatch of done work).
            $isReleased = $pfContent -and ($pfContent -match '(?m)^- Status:\s*released\b' -or $pfContent -match '(?m)^\*\*Status\*\*:\s*released\b' -or $pfContent -match '(?m)^Status:\s*released\b')
            $destDir = if ($role -eq "coder" -and -not $isReleased) { "$RepoDir/Tasks/Code" } else { "$RepoDir/Tasks/Review" }
            $dest = Join-Path $destDir $pf.Name
            if (-not (Test-Path $dest)) {
                # Snapshot lock state BEFORE the move — the file leaves the lane dir below.
                $pfWasLocked = $false
                try {
                    $pfContent = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
                    $pfWasLocked = $null -ne $pfContent -and $pfContent -match '(?m)^- Status:\s*locked'
                } catch {
                    Write-OrchestratorLog "LANE_LOCK_SNAPSHOT_FAILED file='$($pf.Name)' lane='$($lane.Id)' error='$($_.Exception.Message)'" -Level WARN
                }
                Move-Item -LiteralPath $pf.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "LANE_RECOVERY_MOVE file='$($pf.Name)' lane='$($lane.Id)' dest='$(Split-Path $destDir -Leaf)/'"
                Write-OrchestratorLog "FILE_MOVED file='$($pf.Name)' from=$($lane.Id)/ to=$(Split-Path $destDir -Leaf)/ reason=lane_recovery"
                # Emit a sweep-release event whenever the sweep releases a locked plan file
                # (orchestrator-tooling-2) — reviewers need to know the coder lock was lifted
                # outside the normal release path.
                if ($pfWasLocked) {
                    try {
                        if (Get-Command Write-WorkflowEvent -ErrorAction SilentlyContinue) {
                            Write-WorkflowEvent -Type RESCUE -Files @($dest) -AgentId $lane.Id -Phase "orchestrator" -Detail "SWEEP_RELEASE reason=lane_recovery dest=$(Split-Path $destDir -Leaf)"
                        }
                    } catch {
                        Write-OrchestratorLog "SWEEP_RELEASE_EVENT_FAILED file='$($pf.Name)' lane='$($lane.Id)' error='$($_.Exception.Message)'" -Level WARN
                    }
                }
            }
        }
        # Clean stale state files
        foreach ($stale in @("stream.json", "stream.log", ".complete")) {
            $stalePath = Join-Path $laneDir $stale
            if (Test-Path $stalePath) { Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue }
        }
        $lane.Idle = $true
        $recovered++
        Write-OrchestratorLog "LANE_RECOVERY lane='$($lane.Id)' role=$role hadStreamJson=$hasStreamJson hadComplete=$hasComplete"
    }
    if ($recovered -gt 0) {
        Write-OrchestratorLog "LANE_RECOVERY_TOTAL recovered=$recovered"
    }
    return $recovered
}

function New-WorktreeModule {
    <#
    .SYNOPSIS
        Creates a worktree module: git worktree + branch + lane dirs.
        Each module is an isolated git checkout on its own branch.
    #>
    param(
        [string]$RepoDir,
        [int]$ModuleIndex,
        [int]$CoderCount = 3,
        [int]$ReviewerCount = 1,
        [string]$BaseRef = 'main'
    )
    $moduleId = "module-$ModuleIndex"
    $branchName = "wt/$moduleId"
    $wtPath = Join-Path $RepoDir "Tasks/Worktrees" $moduleId

    . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) "Git/Invoke-WorktreeSetup.ps1")

    if (Test-Path $wtPath) {
        $registered = @(Get-ExistingWorktrees | Where-Object { (Get-WorktreePathKey -Path $_.WorktreePath) -eq (Get-WorktreePathKey -Path $wtPath) })
        if ($registered.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction Stop
                Write-OrchestratorLog "WORKTREE_STALE_PATH_REMOVED module=$moduleId path=$wtPath"
            } catch {
                Write-OrchestratorLog "WORKTREE_STALE_PATH_REMOVE_FAILED module=$moduleId path=$wtPath error='$($_.Exception.Message)'" -Level WARN
            }
        }
    }

    $baseHead = $null
    try { $baseHead = git -C $RepoDir rev-parse --verify "$BaseRef^{commit}" 2>$null } catch {}
    $branchHead = $null
    if ($baseHead) {
        try { $branchHead = git -C $RepoDir rev-parse --verify "$branchName^{commit}" 2>$null } catch {}
    }
    if ($branchHead -and $branchHead -ne $baseHead) {
        $archiveBranch = "archive/$branchName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        try {
            git -C $RepoDir branch -m $branchName $archiveBranch 2>$null
            Write-OrchestratorLog "WORKTREE_BRANCH_ARCHIVED module=$moduleId old=$branchName archive=$archiveBranch"
        } catch {
            Write-OrchestratorLog "WORKTREE_BRANCH_ARCHIVE_FAILED module=$moduleId branch=$branchName error='$($_.Exception.Message)'" -Level WARN
        }
        $branchHead = $null
    }
    if (-not $branchHead -and $baseHead) {
        try {
            git -C $RepoDir branch $branchName $BaseRef 2>$null
            if ($LASTEXITCODE -ne 0) { throw "git branch exit $LASTEXITCODE" }
            Write-OrchestratorLog "WORKTREE_BRANCH_CREATED module=$moduleId branch=$branchName base=$BaseRef"
        } catch {
            Write-OrchestratorLog "WORKTREE_BRANCH_CREATE_FAILED module=$moduleId branch=$branchName error='$($_.Exception.Message)'" -Level ERROR
            return $null
        }
    }

    $wtResult = New-AgentWorktree -BranchName $branchName -WorktreePath $wtPath -BaseRef $BaseRef -Resume
    if ($wtResult.Error) {
        Write-OrchestratorLog "WORKTREE_MODULE_FAILED module=$moduleId error='$($wtResult.Message)'" -Level ERROR
        return $null
    }

    # Ensure Tasks/Working/ exists inside the worktree
    $workingDir = Join-Path $wtPath "Tasks/Working"
    $null = New-Item -ItemType Directory -Path $workingDir -Force -ErrorAction SilentlyContinue

    $lanes = @()
    for ($i = 1; $i -le $CoderCount; $i++) {
        $laneId = "lane-coder-$i"
        $laneDir = Join-Path $workingDir $laneId
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        $lanes += @{ Id = "$moduleId/$laneId"; Path = $laneDir; Role = "coder"; ModuleId = $moduleId; WorktreePath = $wtPath; BranchName = $branchName; Index = $i; Idle = $true }
    }
    for ($i = 1; $i -le $ReviewerCount; $i++) {
        $laneId = "lane-reviewer-$i"
        $laneDir = Join-Path $workingDir $laneId
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        $lanes += @{ Id = "$moduleId/$laneId"; Path = $laneDir; Role = "reviewer"; ModuleId = $moduleId; WorktreePath = $wtPath; BranchName = $branchName; Index = $i; Idle = $true }
    }

    Write-OrchestratorLog "WORKTREE_MODULE_CREATED module=$moduleId branch=$branchName worktree=$wtPath lanes=$($lanes.Count)"
    return @{
        ModuleId     = $moduleId
        BranchName   = $branchName
        WorktreePath = $wtPath
        Lanes        = $lanes
    }
}

function Remove-WorktreeModule {
    <#
    .SYNOPSIS
        Merges a worktree module's branch to main and removes the worktree.
    #>
    param(
        [string]$RepoDir,
        [hashtable]$Module
    )
    $branch = $Module.BranchName
    $wtPath = $Module.WorktreePath
    Write-OrchestratorLog "WORKTREE_MODULE_MERGE module=$($Module.ModuleId) branch=$branch"

    try {
        . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) "Git/Invoke-WorktreeMergeAll.ps1")
        $mergeResult = Merge-AgentBranches -Branches @($branch) -RepoRoot $RepoDir
        Write-OrchestratorLog "WORKTREE_MODULE_MERGED module=$($Module.ModuleId) merged=$($mergeResult.MergedCount) conflicts=$($mergeResult.ConflictCount)"
    } catch {
        Write-OrchestratorLog "WORKTREE_MODULE_MERGE_FAILED module=$($Module.ModuleId) error='$($_.Exception.Message)'" -Level WARN
    }

    try {
        . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) "Git/Invoke-WorktreeCleanup.ps1")
        Remove-AgentWorktree -WorktreePath $wtPath -BranchName $branch
        Write-OrchestratorLog "WORKTREE_MODULE_REMOVED module=$($Module.ModuleId)"
    } catch {
        Write-OrchestratorLog "WORKTREE_MODULE_REMOVE_FAILED module=$($Module.ModuleId) error='$($_.Exception.Message)'" -Level WARN
    }
}

function Clear-LaneDir {
    <#
    .SYNOPSIS
        Clears stale agent artifacts from a lane directory.
    #>
    param([string]$LaneDir, [string]$AgentId)
    # Remove stale .complete sentinel
    Remove-Item (Join-Path $LaneDir ".complete") -Force -ErrorAction SilentlyContinue
    # Remove stale plan files
    Get-ChildItem "$LaneDir/*.md" -ErrorAction SilentlyContinue | Remove-Item -Force
    # Remove agent artifacts
    if ($AgentId) {
        Remove-Item (Join-Path $LaneDir "$AgentId.pid") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $LaneDir "$AgentId.heartbeat") -Force -ErrorAction SilentlyContinue
    }
}
