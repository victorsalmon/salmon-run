# Invoke-FleetHeartbeatCheck
# Enumerates all Git repos under C:\Repos and checks Tasks/Logs/agents/
# for stale or missing heartbeats. Returns a list of unhealthy agents.

function Invoke-FleetHeartbeatCheck {
    param(
        [int]$HeartbeatStaleThresholdSeconds = 120,
        [string]$ReposRoot = "C:\Repos"
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $now = [datetime]::UtcNow

    $repos = Get-ChildItem -LiteralPath $ReposRoot -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName ".git")
    }

    foreach ($repo in $repos) {
        $agentDir = Join-Path $repo.FullName "Tasks\Logs\agents"
        if (-not (Test-Path $agentDir)) { continue }

        $pidFiles = Get-ChildItem "$agentDir\*.pid" -File -ErrorAction SilentlyContinue
        $heartbeatFiles = Get-ChildItem "$agentDir\*.heartbeat" -File -ErrorAction SilentlyContinue

        $pidMap = @{}
        foreach ($pf in $pidFiles) {
            $pidMap[$pf.BaseName] = $pf
        }

        $hbMap = @{}
        foreach ($hf in $heartbeatFiles) {
            $hbMap[$hf.BaseName] = $hf
        }

        $allAgentIds = ($pidMap.Keys + $hbMap.Keys) | Sort-Object -Unique

        foreach ($agentId in $allAgentIds) {
            $hasPid = $pidMap.ContainsKey($agentId)
            $hasHb = $hbMap.ContainsKey($agentId)
            $pidAlive = $false
            $hbAgeSeconds = $null
            $hbStale = $false
            $pidValue = $null

            if ($hasPid) {
                try {
                    $raw = (Get-Content -LiteralPath $pidMap[$agentId].FullName -Raw -ErrorAction Stop).Trim()
                    if ($raw -match '^\d+$') {
                        $pidValue = [int]$raw
                        $pidAlive = [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
                    }
                } catch {}
            }

            if ($hasHb) {
                try {
                    $hbContent = (Get-Content -LiteralPath $hbMap[$agentId].FullName -Raw -ErrorAction Stop).Trim()
                    if ($hbContent) {
                        $hbTime = [datetime]::Parse($hbContent, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                        $hbAgeSeconds = [int]($now - $hbTime).TotalSeconds
                        $hbStale = $hbAgeSeconds -gt $HeartbeatStaleThresholdSeconds
                    }
                } catch {}
            }

            $isUnhealthy = $false
            if ($hasPid -and -not $pidAlive) { $isUnhealthy = $true }
            elseif ($hasPid -and $pidAlive -and (-not $hasHb -or $hbStale)) { $isUnhealthy = $true }
            elseif (-not $hasPid -and $hasHb) { $isUnhealthy = $true }

            if ($isUnhealthy) {
                $results.Add([PSCustomObject]@{
                    RepoName  = $repo.Name
                    AgentId   = $agentId
                    RepoPath  = $repo.FullName
                    HasPidFile = $hasPid
                    Pid       = $pidValue
                    PidAlive  = $pidAlive
                    HasHeartbeat = $hasHb
                    HeartbeatAgeSeconds = $hbAgeSeconds
                    HeartbeatStale = $hbStale
                    Status    = if ($hasPid -and -not $pidAlive) { "process-dead" }
                                elseif ($hasPid -and $pidAlive -and -not $hasHb) { "missing-heartbeat" }
                                elseif ($hasPid -and $pidAlive -and $hbStale) { "heartbeat-stale" }
                                elseif (-not $hasPid -and $hasHb) { "orphan-heartbeat" }
                                else { "unknown" }
                })
            }
        }
    }

    $summary = [PSCustomObject]@{
        TotalRepos      = $repos.Count
        UnhealthyCount  = $results.Count
        UnhealthyAgents = $results.ToArray()
        Timestamp       = $now.ToString('o')
    }

    return $summary
}
