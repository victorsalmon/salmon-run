# ─── Spawned PID Registry ─────────────────────────────────────────────
# Tracks only PIDs that the orchestrator explicitly spawned via Start-Process.
# All kill operations check this registry first — anything not in the registry
# is never touched (prevents killing interactive opencode sessions or recycled PIDs).
# Registry file: Tasks/Logs/agents/.spawned-pids.json (shared across processes)

$script:SpawnedPidsRegistryPath = $null

function Initialize-SpawnedPidRegistry {
    param([string]$RegistryPath)
    $script:SpawnedPidsRegistryPath = $RegistryPath
    $null = New-Item -ItemType Directory -Path (Split-Path $RegistryPath -Parent) -Force
    if (-not (Test-Path $RegistryPath)) {
        # Atomic write: temp-file + move prevents a concurrent reader from seeing a partial registry.
        Write-AtomicFile -Path $RegistryPath -Value '{"pids":[],"byAgent":{}}' -Encoding utf8
    }
}

function Get-SpawnedPids {
    if (-not $script:SpawnedPidsRegistryPath -or -not (Test-Path $script:SpawnedPidsRegistryPath)) { return @() }
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { return @() }
        return @($data.pids)
    } catch { return @() }
}

function Register-SpawnedPid {
    param(

        [int]$ProcessId,
        [string]$AgentId = ""
    )
    if (-not $script:SpawnedPidsRegistryPath) { return }
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { $data = [PSCustomObject]@{ pids = @(); byAgent = @{} } }
        $priorPid = $null
        if ($AgentId -and $data.byAgent.PSObject.Properties.Name -contains $AgentId) {
            $priorPid = [int]$data.byAgent.$AgentId
        }
        if ($priorPid -and $priorPid -ne $ProcessId) {
            # Agent IDs are lane identities, not process identities. When a
            # lane is restarted, retire its prior PID so a dead generation
            # cannot remain eligible for later process-tree operations.
            $data.pids = @($data.pids | Where-Object { [int]$_ -ne $priorPid })
        }
        if ($data.pids -notcontains $ProcessId) { $data.pids += $ProcessId }
        if ($AgentId) { $data.byAgent | Add-Member -NotePropertyName $AgentId -NotePropertyValue $ProcessId -Force }
        # Atomic write: temp-file + move prevents a concurrent reader from seeing a partial registry.
        $data | ConvertTo-Json -Depth 3 | Write-AtomicFile -Path $script:SpawnedPidsRegistryPath -Encoding utf8
    } catch { Write-OrchestratorLog "REGISTER_PID_FAILED pid=$ProcessId agentId=$AgentId error='$($_.Exception.Message)'" -Level WARN }
}

function Unregister-SpawnedPid {
    param(

        [int]$ProcessId,
        [string]$AgentId = ""
    )
    if (-not $script:SpawnedPidsRegistryPath -or -not (Test-Path $script:SpawnedPidsRegistryPath)) { return }
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { return }
        $data.pids = @($data.pids | Where-Object { $_ -ne $ProcessId })
        if ($AgentId -and $data.byAgent.PSObject.Properties.Name -contains $AgentId -and [int]$data.byAgent.$AgentId -eq $ProcessId) {
            $data.byAgent.PSObject.Properties.Remove($AgentId)
        }
        # Atomic write: temp-file + move prevents a concurrent reader from seeing a partial registry.
        $data | ConvertTo-Json -Depth 3 | Write-AtomicFile -Path $script:SpawnedPidsRegistryPath -Encoding utf8
    } catch { Write-OrchestratorLog "UNREGISTER_PID_FAILED pid=$ProcessId agentId=$AgentId error='$($_.Exception.Message)'" -Level WARN }
}

function Test-IsSpawnedPid {
    param(

        [int]$ProcessId
    )
    return (Get-SpawnedPids) -contains $ProcessId
}

function Stop-ProcessTree {
    param([int]$ProcessId, [switch]$Force)
    # Kill a process and all its descendants (children first, then parent).
    # Safety: only kills PIDs registered in .spawned-pids.json — never kills
    # interactive opencode sessions or unrelated processes. The registry guard
    # ensures only orchestrator-spawned process trees are killed.
    if (-not (Test-IsSpawnedPid -ProcessId $ProcessId)) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { "unknown" }
        Write-OrchestratorLog "PROCESS_TREE_SKIP_UNREGISTERED pid=$ProcessId name=$procName — not in spawned PID registry" -Level WARN
        return
    }
    $killedPids = @()
    try {
        # Recursively find all descendant PIDs via CIM
        $toKill = [System.Collections.Generic.Queue[int]]::new()
        $toKill.Enqueue($ProcessId)
        $allPids = [System.Collections.Generic.List[int]]::new()
        $allPids.Add($ProcessId)
        $visited = [System.Collections.Generic.HashSet[int]]::new()
        [void]$visited.Add($ProcessId)
        while ($toKill.Count -gt 0) {
            $currentPid = $toKill.Dequeue()
            try {
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$currentPid" -ErrorAction SilentlyContinue
                foreach ($child in $children) {
                    $childPid = [int]$child.ProcessId
                    if (-not $visited.Contains($childPid)) {
                        [void]$visited.Add($childPid)
                        [void]$allPids.Add($childPid)
                        $toKill.Enqueue($childPid)
                    }
                }
            } catch { Write-OrchestratorLog "CIM_CHILD_QUERY_FAILED pid=$currentPid error='$($_.Exception.Message)'" -Level WARN }
        }
        # Kill children first (reverse order), then the root
        for ($idx = $allPids.Count - 1; $idx -ge 0; $idx--) {
            $pidToKill = $allPids[$idx]
            try {
                $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $pidToKill -Force:$Force -ErrorAction Stop
                    $killedPids += $pidToKill
                }
            } catch { Write-OrchestratorLog "STOP_PROCESS_FAILED pid=$pidToKill error='$($_.Exception.Message)'" -Level WARN }
        }
        Write-OrchestratorLog "PROCESS_TREE_STOP_OK root=$ProcessId killed=$($killedPids.Count) pids='$($killedPids -join ',')'"
    } catch {
        Write-OrchestratorLog "PROCESS_TREE_STOP_FAILED root=$ProcessId error='$($_.Exception.Message)' killed='$($killedPids -join ',')'" -Level WARN
    }
}

function Convert-PidSafe {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = 0
    if ([int]::TryParse($Value.Trim(), [ref]$parsed)) { return $parsed }
    return $null
}

function Initialize-OrchestratorPidLock {
    param([string]$PidLockFile, [int]$InstanceId)
    try {
        $null = New-Item -ItemType File -Path $PidLockFile -ErrorAction Stop
        # Atomic write: temp-file + move prevents a concurrent orchestrator from reading a partial PID.
        Write-AtomicFile -Path $PidLockFile -Value $PID.ToString() -Encoding utf8
    } catch [System.IO.IOException] {
        $existingPid = try { (Get-Content $PidLockFile -Raw -ErrorAction Stop).Trim() } catch { $null }
        if ($existingPid) {
            $alivePid = Convert-PidSafe -Value $existingPid
            $alive = $alivePid -and (Get-Process -Id $alivePid -ErrorAction SilentlyContinue)
            if ($alive) {
                Write-Host "  Orchestrator PID $existingPid is already running" -ForegroundColor Red
                return $false
            }
        }
        # Atomic write: temp-file + move prevents a concurrent orchestrator from reading a partial PID.
        Write-AtomicFile -Path $PidLockFile -Value $PID.ToString() -Encoding utf8
    }
    $logDir = Split-Path $PidLockFile -Parent
    $orchActivePath = Join-Path $logDir ".orchestrator-active"
    $null = New-Item -ItemType Directory -Path $logDir -Force
    # Atomic write: temp-file + move prevents a concurrent reader from seeing a partial active marker.
    Write-AtomicFile -Path $orchActivePath -Value "$PID`n$InstanceId" -Encoding utf8
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        if (Test-Path $PidLockFile) { Remove-Item $PidLockFile -Force -ErrorAction SilentlyContinue }
        $orchActive = Join-Path $logDir ".orchestrator-active"
        if (Test-Path $orchActive) { Remove-Item $orchActive -Force -ErrorAction SilentlyContinue }
        if ($script:OrchMutex) { try { $script:OrchMutex.ReleaseMutex(); $script:OrchMutex.Dispose() } catch { Write-OrchestratorLog "MUTEX_CLEANUP_FAILED error='$($_.Exception.Message)'" -Level WARN } }
    } 2>$null
    return $true
}

function Write-OrchestratorHeartbeat {
    param([string]$HeartbeatFile)
    # Atomic write: temp-file + move prevents a stale-checker from reading a partial timestamp.
    Write-AtomicFile -Path $HeartbeatFile -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8
}

function Test-OrchestratorHeartbeatStale {
    param([string]$HeartbeatFile, [int]$SubprocessTimeoutMinutes)
    if (-not (Test-Path $HeartbeatFile)) { return $false }
    $lastBeat = Get-Content $HeartbeatFile -Raw -ErrorAction SilentlyContinue
    if (-not $lastBeat) { return $false }
    $lastTime = $lastBeat.Trim() -as [datetime]
    if (-not $lastTime) { return $false }
    return (([datetime]::UtcNow) - $lastTime.ToUniversalTime()).TotalMinutes -ge $SubprocessTimeoutMinutes
}

function Invoke-OrchestratorStartupRescue {
    param([string]$RepoDir, [string]$HeartbeatFile, [int]$SubprocessTimeoutMinutes)
    if (Test-Path $HeartbeatFile) {
        if (Test-OrchestratorHeartbeatStale -HeartbeatFile $HeartbeatFile -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes) {
            Write-Host "  Stale heartbeat detected — running orphan sweep" -ForegroundColor DarkGray
            Restore-OrphanedLock -RepoDir $RepoDir
            $resvPath = Join-Path "$RepoDir/Tasks" "Logs/.reservations.json"
            if (Test-Path $resvPath) { Remove-Item $resvPath -Force -ErrorAction SilentlyContinue }
        }
    }
    $workingFiles = Get-ChildItem "$RepoDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    if ($workingFiles) {
        Write-Host "  Found $($workingFiles.Count) file(s) in Working/ at startup — running rescue sweep" -ForegroundColor Yellow
        Write-OrchestratorLog "STARTUP_WORKING_FILES count=$($workingFiles.Count)"
        Restore-OrphanedLock -RepoDir $RepoDir
        Write-OrchestratorLog "STARTUP_RESCUE_COMPLETE"
    } else {
        Get-ChildItem "$RepoDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' } |
            Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Rescue any files in Failed/ queue on startup (reset retries to 0)
    try {
        $rescued = Rescue-FailedQueue -RepoDir $RepoDir
        if ($rescued -gt 0) {
            Write-Host "  Rescued $rescued file(s) from Failed/ queue at startup" -ForegroundColor Yellow
            Write-OrchestratorLog "STARTUP_FAILED_RESCUE count=$rescued"
        }
    } catch {
        Write-OrchestratorLog "STARTUP_FAILED_RESCUE_ERROR error='$($_.Exception.Message)'" -Level WARN
    }
}
