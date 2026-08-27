<#
.SYNOPSIS
    One cycle of orchestrator state check — queues, agents, outcomes.
    Called by the opencode orchestrator agent via bash each cycle.
.DESCRIPTION
    Returns a JSON object with queue counts, running agent statuses,
    completed/stale agents since last check, and connascence groups.
    The agent reads the JSON and decides what to do next (spawn, rescue, exit).

    Also writes a sticky human-readable status file at Tasks/Logs/orchestrator-live.json
    so the user can check at any time.

.PARAMETER LastCompletedFile
    Path to a file that stores the set of agents completed in prior cycles.
    The script reads this file, checks which agents are now complete beyond it,
    and writes back the updated set. This lets the agent track "new since last cycle".
    Defaults to Tasks/Logs/.orchestrator-cycle-state.json.
#>

param(
    [ValidateNotNullOrEmpty()]
    [string]$LastCompletedFile = (Join-Path (Split-Path -Parent $PSScriptRoot) "..\..\Tasks\Logs\.orchestrator-cycle-state.json")
)

$ErrorActionPreference = "Stop"

$InterclawDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$LogsDir = Join-Path $InterclawDir "Tasks\Logs"
$AgentsDir = Join-Path $LogsDir "agents"
$WorkingDir = Join-Path $InterclawDir "Tasks\Working"
$CodeDir = Join-Path $InterclawDir "Tasks\Code"
$ReviewDir = Join-Path $InterclawDir "Tasks\Review"

# ─── Load helpers ──────────────────────────────────────────────────────────
$fleetScript = Join-Path $PSScriptRoot "..\..\Orchestration\LocalOrchestrator-FleetStatus.ps1"
if (Test-Path $fleetScript) { . $fleetScript }

# ─── Read previous cycle state ─────────────────────────────────────────────
$prevCompleted = @()
$prevRunning = @()
if (Test-Path $LastCompletedFile) {
    try {
        $prev = Get-Content $LastCompletedFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($prev) {
            $prevCompleted = @($prev.completed)
            $prevRunning = @($prev.running)
        }
    } catch {
        Write-Host "[CYCLE] Failed to parse cycle state '$LastCompletedFile': $_" -ForegroundColor DarkGray
    }
}

# ─── 1. Queue counts ──────────────────────────────────────────────────────
$countsRaw = Get-TaskCounts
$counts = @{
    rootCoder        = $countsRaw.RootCoder
    review           = $countsRaw.Review
    working          = $countsRaw.Working
    lockedCoder      = $countsRaw.LockedCoder
    lockedReviewer   = $countsRaw.LockedReviewer
    coderWorkload    = $countsRaw.CoderWorkload
    reviewerWorkload = $countsRaw.ReviewerWorkload
    activeStreams    = $countsRaw.ActiveStreams
}

# ─── 2. Agent fleet status ─────────────────────────────────────────────────
$fleet = Get-AgentFleetStatus
$running = @($fleet | Where-Object { $_.Status -eq "RUNNING" })
$stale = @($fleet | Where-Object { $_.Status -eq "STALE" })
$complete = @($fleet | Where-Object { $_.Status -eq "COMPLETE" })
$currentRunningIds = @($running | ForEach-Object { $_.AgentId })

# ─── 3. Detect newly completed / stale since last cycle ───────────────────
$newlyCompleted = @($stale | Where-Object { $_.AgentId -notin $prevCompleted -and $_.AgentId -notin $prevRunning })
$newlyRunning = @($running | Where-Object { $_.AgentId -notin $prevRunning -and $_.AgentId -notin $prevCompleted })

# ─── 4. Write cycle state for next call ───────────────────────────────────
$nextState = @{
    completed = @($stale | ForEach-Object { $_.AgentId }) + @($complete | ForEach-Object { $_.AgentId })
    running   = $currentRunningIds
    cycleTime = (Get-Date -Format "o")
} | ConvertTo-Json -Compress
Set-Content -Path $LastCompletedFile -Value $nextState -Encoding utf8 -NoNewline

# ─── 5. Build output ──────────────────────────────────────────────────────
$agentTable = $running | ForEach-Object {
    $elapsedStr = if ($_.Elapsed -match '^\d+$') {
        $sec = [int]$_.Elapsed
        if ($sec -ge 60) { "$([math]::Floor($sec / 60))m$($sec % 60)s" } else { "${sec}s" }
    } else { $_.Elapsed }
    @{
        agentId = $_.AgentId
        pid     = $_.PID
        role    = $_.Role
        mode    = $_.Mode
        elapsed = $elapsedStr
    }
}

$output = @{
    cycle          = @{
        timestamp = (Get-Date -Format "o")
    }
    queues         = $counts
    running        = $agentTable
    runningCount   = $running.Count
    staleCount     = $stale.Count
    newSinceLast   = @{
        completed = @($newlyCompleted | ForEach-Object { @{ agentId = $_.AgentId; pid = $_.PID; role = $_.Role } })
        stale     = @($stale | Where-Object { $_.AgentId -notin $prevCompleted -and $_.AgentId -notin $prevRunning } | ForEach-Object { @{ agentId = $_.AgentId; pid = $_.PID; role = $_.Role } })
    }
    hasCapacity    = $counts.coderWorkload -gt 0
    allEmpty       = ($counts.rootCoder -eq 0 -and $counts.review -eq 0 -and $counts.working -eq 0)
}

$json = $output | ConvertTo-Json -Compress -Depth 5

# Write sticky status for user inspection
$stickyPath = Join-Path $LogsDir "orchestrator-live.json"
$output | ConvertTo-Json -Depth 5 | Set-Content -Path $stickyPath -Encoding utf8

$json
