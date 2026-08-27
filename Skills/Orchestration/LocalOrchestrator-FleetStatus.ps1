<#
.SYNOPSIS
    Fleet status monitoring functions for LocalOrchestrator.ps1.
#>

function Get-AgentFleetStatus {
    param(
        [string]$LogDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "Tasks/Logs"),
        [string]$ArchiveDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "Tasks/Complete/PID")
    )
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($f in Get-ChildItem "$LogDir\orchestrator-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-structured.log' }) {
        $procPid = 0
        $pidStr = ($f.BaseName -replace 'orchestrator-', '')
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $alive = Get-Process -Id $procPid -ErrorAction SilentlyContinue
        $header = Get-Content $f.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        $instanceId  = ($header | Select-String '# InstanceId:' | ForEach-Object { $_ -replace '# InstanceId: ', '' })
        $startRaw    = ($header | Select-String '# StartTime:' | ForEach-Object { $_ -replace '# StartTime: ', '' })
        $elapsed = if ($alive -and $startRaw) {
            $s = $startRaw -as [datetime]
            if ($s) { [math]::Round(((Get-Date).ToUniversalTime() - $s.ToUniversalTime()).TotalSeconds) } else { $null }
        }
        $modeFile = Join-Path $LogDir "orchestrator-$procPid.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }

        $results.Add([PSCustomObject]@{
            AgentId   = if ($instanceId) { "orchestrator-$instanceId" } else { "orchestrator-?" }
            PID       = $procPid
            Role      = "orchestrator"
            Mode      = $mode
            Status    = if ($alive) { "RUNNING" } else { "STALE" }
            Elapsed   = if ($elapsed) { "$($elapsed)s" } else { "-" }
            LogFile   = $f.FullName
        })
    }

    # Only show archived (COMPLETE) runs from the last 7 days
    $recentCutoff = (Get-Date).AddDays(-7)
    foreach ($f in Get-ChildItem "$ArchiveDir\orchestrator-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-structured.log' -and $_.LastWriteTime -gt $recentCutoff }) {
        $procPid = 0
        $pidStr = ($f.BaseName -replace 'orchestrator-', '')
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $header = Get-Content $f.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        $instanceId = ($header | Select-String '# InstanceId:' | ForEach-Object { $_ -replace '# InstanceId: ', '' })
        $modeFile = Join-Path $ArchiveDir "orchestrator-$procPid.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }

        $results.Add([PSCustomObject]@{
            AgentId   = if ($instanceId) { "orchestrator-$instanceId" } else { "orchestrator-?" }
            PID       = $procPid
            Role      = "orchestrator"
            Mode      = $mode
            Status    = "COMPLETE"
            Elapsed   = "-"
            LogFile   = $f.FullName
        })
    }

    $agentDir = Join-Path $LogDir "agents"
    foreach ($pidFile in Get-ChildItem "$agentDir\*.pid" -ErrorAction SilentlyContinue) {
        $agentId = $pidFile.BaseName
        $rawContent = Get-Content $pidFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $rawContent) { continue }
        $procPid = 0
        $pidStr = $rawContent.Trim()
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $alive = Get-Process -Id $procPid -ErrorAction SilentlyContinue
        $role = if ($agentId -match '^coder-') { "coder" } elseif ($agentId -match '^reviewer-') { "reviewer" } elseif ($agentId -match '^watchdog-') { "watchdog" } else { "agent" }
        $modeFile = Join-Path $agentDir "$agentId.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }
        $heartbeatFile = Join-Path $agentDir "$agentId.heartbeat"
        $elapsed = if ($alive -and (Test-Path $heartbeatFile)) {
            $hb = (Get-Content $heartbeatFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
            if ($hb) { [math]::Round(((Get-Date).ToUniversalTime() - $hb.ToUniversalTime()).TotalSeconds) } else { $null }
        }
        $logFile = Join-Path $agentDir "$agentId.log"

        $results.Add([PSCustomObject]@{
            AgentId   = $agentId
            PID       = $procPid
            Role      = $role
            Mode      = $mode
            Status    = if ($alive) { "RUNNING" } else { "STALE" }
            Elapsed   = if ($elapsed) { "$($elapsed)s" } else { "-" }
            LogFile   = $logFile
        })
    }

    return $results | Sort-Object Status, Role, AgentId
}

function Write-FleetStatusTable {
    $fleet = Get-AgentFleetStatus
    if (-not $fleet) { return }
    $running = $fleet | Where-Object { $_.Status -eq "RUNNING" }
    if (-not $running) { return }
    Write-Host "  ── Active Agents ──────────────────────────────────────" -ForegroundColor Cyan
    foreach ($a in $running) {
        $roleIcon = switch ($a.Role) {
            "orchestrator" { "⚙" }
            "coder"        { "✏" }
            "reviewer"     { "✓" }
            default        { "●" }
        }
        Write-Host "  $roleIcon $($a.AgentId) (PID $($a.PID)) — $($a.Role), $($a.Elapsed)" -ForegroundColor DarkGray
    }
}

function Get-TaskCounts {
    $InterclawDir = if ($PSScriptRoot) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { $PWD }
    $rootCoderFiles = @(Get-ChildItem "$InterclawDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' })
    $rootCoder = $rootCoderFiles.Count

    $reviewFiles = @(Get-ChildItem "$InterclawDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' })
    $review = $reviewFiles.Count

    $handoff = @(Get-ChildItem "$InterclawDir/Tasks/Handoff/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }).Count

    $working = @(Get-ChildItem "$InterclawDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' })

    $lockedCoder = 0
    $lockedReviewer = 0
    $coderAgents = @{}
    $reviewerAgents = @{}
    $streamDirs = @(Get-ChildItem "$InterclawDir/Tasks/Working/stream-*" -Directory -ErrorAction SilentlyContinue)
    $activeStreams = $streamDirs.Count
    $blockRe = '(?m)^\*\*Status\*\*:\s*blocked\b'
    $blocked = @($rootCoderFiles | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match $blockRe }).Count +
               @($reviewFiles | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match $blockRe }).Count

    foreach ($f in $working) {
        # Extract agent ID from directory name (Phase B: working subdir = agent ID)
        $agentId = $f.Directory.Name
        if ($agentId -match 'coder-(\d+-\d+)') {
            $lockedCoder++
            $coderAgents[$Matches[1]] = $true
        }
        if ($agentId -match 'reviewer-(\d+-\d+)') {
            $lockedReviewer++
            $reviewerAgents[$Matches[1]] = $true
        }
    }

    return [PSCustomObject]@{
        RootCoder        = $rootCoder
        Review           = $review
        Handoff          = $handoff
        Working          = $working.Count
        LockedCoder      = $lockedCoder
        LockedReviewer   = $lockedReviewer
        Blocked          = $blocked
        CoderWorkload    = $rootCoder + $lockedCoder
        ReviewerWorkload = $review + $lockedReviewer
        CoderAgents      = $coderAgents
        ReviewerAgents   = $reviewerAgents
        ActiveStreams    = $activeStreams
    }
}
