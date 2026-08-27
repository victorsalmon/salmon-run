<#
.SYNOPSIS
    Monitors running subagents via heartbeat/PID files and displays a status table.
.DESCRIPTION
    Polls the Tasks/Logs/agents/ directory for PID and heartbeat files,
    checks whether each agent process is still alive, and renders a table
    showing agent ID, role, elapsed time, last heartbeat age, and liveness.

    Designed to be called from the Orchestrate Mode after dispatching
    subagents, or run ad-hoc to check on fleet agents.

.PARAMETER AgentDir
    Directory containing agent PID and heartbeat files. Defaults to
    Tasks/Logs/agents/ under the repo root.
.PARAMETER RepoRoot
    Root of the repository. Defaults to script parent's parent.
.PARAMETER PollSeconds
    How many seconds between refresh cycles. Default 10.
.PARAMETER MaxCycles
    Maximum number of poll cycles. Default 12 (2 minutes at 10s).
    Use 0 for infinite (Ctrl+C to stop).
.PARAMETER PassThru
    Return status objects instead of rendering the table.
.EXAMPLE
    .\Skills\\Orchestration\Invoke-MonitorSubagents.ps1
.EXAMPLE
    .\Skills\\Orchestration\Invoke-MonitorSubagents.ps1 -PollSeconds 5 -MaxCycles 6
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [string]$AgentDir = (Join-Path $RepoRoot "Tasks\Logs\agents"),
    [int]$PollSeconds = 10,
    [int]$MaxCycles = 12,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

function Get-AgentStatus {
    $agents = @()
    $pidFiles = Get-ChildItem -Path $AgentDir -Filter "*.pid" -ErrorAction SilentlyContinue
    $heartbeatFiles = Get-ChildItem -Path $AgentDir -Filter "*.heartbeat" -ErrorAction SilentlyContinue

    # Index heartbeats by agent ID (strip .heartbeat suffix)
    $heartbeatMap = @{}
    foreach ($hb in $heartbeatFiles) {
        $agentId = $hb.BaseName  # filename without extension
        try {
            $hbTime = [datetime]::ParseExact((Get-Content $hb.FullName -Raw).Trim(), 'o', $null)
            $heartbeatMap[$agentId] = $hbTime
        } catch {
            $heartbeatMap[$agentId] = $null
        }
    }

    foreach ($pf in $pidFiles) {
        $agentId = $pf.BaseName
        $pidStr = (Get-Content $pf.FullName -Raw).Trim()
        $procId = 0
        $isAlive = $false
        $elapsed = $null

        if ([int]::TryParse($pidStr, [ref]$procId)) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $isAlive = $null -ne $proc
            if ($isAlive -and $proc) {
                $elapsed = [math]::Round(((Get-Date) - $proc.StartTime).TotalMinutes, 1)
            }
        }

        $hbTime = $heartbeatMap[$agentId]
        $hbAge = if ($hbTime) { [math]::Round(((Get-Date) - $hbTime).TotalMinutes, 1) } else { $null }

        # Derive role from agent ID pattern (first part before - or number)
        $role = if ($agentId -match '^(\w+)-\d') { $matches[1] } else { 'unknown' }

        $agents += [PSCustomObject]@{
            AgentId        = $agentId
            Role           = $role
            Pid            = $pid
            IsAlive        = $isAlive
            ElapsedMinutes = $elapsed
            HeartbeatAgeMinutes = $hbAge
            Status         = if (-not $isAlive) { 'STALE' } elseif ($elapsed -ge 45) { 'TIMEOUT' } else { 'RUNNING' }
        }
    }

    return $agents | Sort-Object Status, Role, AgentId
}

function Write-AgentTable {
    param($Agents)
    if (-not $Agents -or $Agents.Count -eq 0) {
        Write-Host "No agents found in $AgentDir" -ForegroundColor Yellow
        return
    }

    $rows = $Agents | ForEach-Object {
        $elapsedStr = if ($null -ne $_.ElapsedMinutes) { "$($_.ElapsedMinutes)m" } else { '-' }
        $hbStr = if ($null -ne $_.HeartbeatAgeMinutes) { "$($_.HeartbeatAgeMinutes)m" } else { '-' }
        [PSCustomObject]@{
            AgentId  = $_.AgentId
            Role     = $_.Role.PadRight(10)
            Pid      = $_.Pid.ToString().PadRight(7)
            Status   = $_.Status.PadRight(9)
            Elapsed  = $elapsedStr.PadRight(8)
            Heartbeat = $hbStr.PadRight(8)
        }
    }

    Write-Host "`nSubagent Status  (polled $(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host "".PadRight(60, '─')
    Write-Host ("{0,-30} {1,-10} {2,-7} {3,-9} {4,-8} {5,-8}" -f 'Agent ID', 'Role', 'PID', 'Status', 'Elapsed', 'HB Age')
    Write-Host "".PadRight(60, '─')
    foreach ($r in $rows) {
        $color = switch ($r.Status.Trim()) {
            'RUNNING' { 'Green' }
            'STALE'   { 'Red' }
            'TIMEOUT' { 'Yellow' }
            default   { 'Gray' }
        }
        Write-Host ("{0,-30} {1,-10} {2,-7} {3,-9} {4,-8} {5,-8}" -f $r.AgentId, $r.Role, $r.Pid, $r.Status, $r.Elapsed, $r.Heartbeat) -ForegroundColor $color
    }
    Write-Host "".PadRight(60, '─')
}

# If PassThru, just return objects once
if ($PassThru) {
    return Get-AgentStatus
}

# Otherwise, poll in a loop
$cycle = 0
while ($MaxCycles -eq 0 -or $cycle -lt $MaxCycles) {
    if ($cycle -gt 0) { Start-Sleep -Seconds $PollSeconds }
    $agents = Get-AgentStatus
    Clear-Host
    Write-Host "Poll cycle $($cycle + 1)/$($MaxCycles -eq 0 ? '∞' : $MaxCycles)" -ForegroundColor DarkGray
    Write-AgentTable $agents
    $cycle++
}

Write-Host "`nMonitoring complete." -ForegroundColor DarkGray
