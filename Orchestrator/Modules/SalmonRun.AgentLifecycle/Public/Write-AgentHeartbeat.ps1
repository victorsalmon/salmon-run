<#
.SYNOPSIS
    Writes a timestamped heartbeat file for the given agent.
.DESCRIPTION
    Creates the Tasks/Logs/agents/ directory if missing and writes the current
    UTC timestamp to <AgentId>.heartbeat. Used by liveness checks to detect
    stale agents.
.PARAMETER AgentId
    Unique agent identifier used as the heartbeat filename stem.
.OUTPUTS
    The full path to the heartbeat file, or $null on failure.
#>
function Write-AgentHeartbeat {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId
    )
    $repoRoot = Get-InterclawRepoRoot
    $agentDir = Join-Path $repoRoot "Tasks/Logs/agents"
    try {
        $null = New-Item -ItemType Directory -Path $agentDir -Force
        $hbPath = Join-Path $agentDir "$AgentId.heartbeat"
        [datetime]::UtcNow.ToString('o') | Write-AtomicFile -Path $hbPath -Encoding utf8
        return $hbPath
    } catch {
        Write-SetupLog "Failed to write heartbeat for $AgentId : $_" -Level DEBUG -Agent core -Phase init
        return $null
    }
}


