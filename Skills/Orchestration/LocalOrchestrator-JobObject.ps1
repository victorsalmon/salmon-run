# ─── Process tree helpers ──────────────────────────────────────────────

function Stop-ProcessTree {
    param([int]$ProcessId, [switch]$Force)
    # SAFETY: Only kill the specific PID — never traverse the process tree.
    # Tree traversal (via WMI parent-child chain) is unreliable on Windows and
    # can kill interactive opencode sessions that happen to share a parent.
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return }
    if ($proc.ProcessName -eq 'opencode' -or $proc.ProcessName -eq 'opencode.exe') {
        Write-Warning "Stop-ProcessTree: skipped opencode PID $ProcessId (may be user session)"
        return
    }
    try { Stop-Process -Id $ProcessId -Force:$Force -ErrorAction Stop } catch {}
}

# ─── PID lock / heartbeat / startup rescue ──────────────────────────────

function Initialize-OrchestratorPidLock {
    param([string]$PidLockFile, [int]$InstanceId)
    try {
        $null = New-Item -ItemType File -Path $PidLockFile -ErrorAction Stop
        $PID.ToString() | Out-File -FilePath $PidLockFile -Encoding utf8 -NoNewline
    } catch [System.IO.IOException] {
        $existingPid = try { (Get-Content $PidLockFile -Raw -ErrorAction Stop).Trim() } catch { $null }
        if ($existingPid) {
            $alive = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
            if ($alive) {
                Write-Host "  ⚠ Orchestrator PID $existingPid is already running — exiting" -ForegroundColor Red
                return $false
            }
        }
        $PID.ToString() | Out-File -FilePath $PidLockFile -Encoding utf8 -NoNewline
    }
    # Write orchestrator-active signal so standalone agents yield
    $logDir = Split-Path $PidLockFile -Parent
    $orchActivePath = Join-Path $logDir ".orchestrator-active"
    $null = New-Item -ItemType Directory -Path $logDir -Force
    "$PID`n$InstanceId" | Out-File -FilePath $orchActivePath -Encoding utf8 -NoNewline

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
    [datetime]::UtcNow.ToString('o') | Out-File -FilePath $HeartbeatFile -Encoding utf8 -NoNewline
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
    param([string]$InterclawDir, [string]$HeartbeatFile, [int]$SubprocessTimeoutMinutes)
    if (Test-Path $HeartbeatFile) {
        if (Test-OrchestratorHeartbeatStale -HeartbeatFile $HeartbeatFile -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes) {
            Write-Host "  🔄 Stale heartbeat detected — running orphan sweep" -ForegroundColor DarkGray
            Rescue-OrphanedLocks -InterclawDir $InterclawDir
            $resvPath = Join-Path "$InterclawDir/Tasks" "Logs/.reservations.json"
            if (Test-Path $resvPath) { Remove-Item $resvPath -Force -ErrorAction SilentlyContinue }
        }
    }
    $workingFiles = Get-ChildItem "$InterclawDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    if ($workingFiles) {
        Write-Host "  🗂 Found $($workingFiles.Count) file(s) in Working/ at startup — running rescue sweep" -ForegroundColor Yellow
        Write-OrchestratorLog "STARTUP_WORKING_FILES count=$($workingFiles.Count)"
        Rescue-OrphanedLocks -InterclawDir $InterclawDir
        Write-OrchestratorLog "STARTUP_RESCUE_COMPLETE"
    } else {
        Get-ChildItem "$InterclawDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' } |
            Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Windows Job Object (REMOVED) ──────────────────────────────────────────────
# KILL_ON_JOB_CLOSE caused cascade failures: when the orchestrator crashed,
# ALL subprocesses were killed instantly, even ones still working.
# Subprocesses now run independently — the next orchestrator rescues orphans.
# See 2026.05.20-orchestrator-crash-resilience1.md for rationale.
#
# Original C# + functions preserved below as reference only:
# function New-ProcessJobObject { ... }
# function Add-ProcessToJob { ... }
