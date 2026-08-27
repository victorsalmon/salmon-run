<#
.SYNOPSIS
    Tests whether an agent process is alive based on PID and heartbeat files.
.DESCRIPTION
    Reads the agent's PID and heartbeat files from Tasks/Logs/agents/. Checks
    if the process is running and whether the heartbeat is within the stale
    threshold. Returns a detailed status object.
.PARAMETER AgentId
    Unique agent identifier to check.
.PARAMETER HeartbeatStaleThresholdSeconds
    Age in seconds beyond which a heartbeat is considered stale. Default 120.
.OUTPUTS
    PSCustomObject with AgentId, Pid, ProcessAlive, HasPidFile, HasHeartbeat,
    HeartbeatAgeSeconds, HeartbeatStale, and Stale properties.
#>
function Test-AgentAlive {
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId,
        [int]$HeartbeatStaleThresholdSeconds = 120
    )
    if (-not $PSBoundParameters.ContainsKey('HeartbeatStaleThresholdSeconds') -and (Get-Command Get-InterclawConstants -ErrorAction SilentlyContinue)) {
        $HeartbeatStaleThresholdSeconds = (Get-InterclawConstants).AgentHeartbeatStaleThresholdSeconds
    }

    $taskRoot = Get-SalmonTaskRoot
    $agentDir = Join-Path $taskRoot "Logs/agents"
    $pidPath = Join-Path $agentDir "$AgentId.pid"
    $hbPath = Join-Path $agentDir "$AgentId.heartbeat"

    $result = [PSCustomObject]@{
        AgentId               = $AgentId
        Pid                   = $null
        ProcessAlive          = $false
        HasPidFile            = $false
        HasHeartbeat          = $false
        HeartbeatAgeSeconds   = $null
        HeartbeatStale        = $false
        Stale                 = $false
    }

    if (Test-Path $pidPath) {
        $result.HasPidFile = $true
        try {
            $pidContent = (Get-Content $pidPath -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($pidContent)) {
                $parsedPid = Convert-PidSafe -Value $pidContent
                $result.Pid = $parsedPid
                $result.ProcessAlive = [bool](Get-Process -Id $parsedPid -ErrorAction SilentlyContinue)
            }
        } catch {
            Write-Debug "Test-AgentAlive: PID parse error for $AgentId : $_"
        }
    }

    if (Test-Path $hbPath) {
        $result.HasHeartbeat = $true
        try {
            $hbContent = (Get-Content $hbPath -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($hbContent)) {
                $hbUtc = [datetime]::Parse($hbContent, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $result.HeartbeatAgeSeconds = ([datetime]::UtcNow - $hbUtc).TotalSeconds
                $result.HeartbeatStale = $result.HeartbeatAgeSeconds -gt $HeartbeatStaleThresholdSeconds
            }
        } catch {
            Write-Debug "Test-AgentAlive: heartbeat parse error for $AgentId : $_"
        }
    }

    if ($result.HasPidFile -and $result.ProcessAlive) {
        # A live process is the ground-truth liveness signal. A stale heartbeat
        # means the agent is busy (e.g. running a long test suite without
        # heartbeats), not dead — it must not trigger file rescue.
        $result.Stale = $false
    } elseif ($result.HasPidFile -and -not $result.ProcessAlive) {
        $result.Stale = $true
    } elseif (-not $result.HasPidFile -and -not $result.HasHeartbeat) {
        # No evidence either way — not our agent.
        $result.Stale = $false
    } else {
        $result.Stale = $true
    }

    return $result
}


