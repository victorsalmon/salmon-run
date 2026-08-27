<#
.SYNOPSIS
    Compares AQE agent count against actual Docker Swarm services to detect drift.
#>
function Test-FleetSwarmReality {
    [OutputType([array])]
    param(
        [array]$AgentRoles,
        [array]$HealthResults
    )
    <#
    .NOTES
        Timeout chain: Up to 2 sequential Invoke-RestMethod calls, each -TimeoutSec 10.
        Worst-case chain sum: 20s. Called from Invoke-FleetHealthCheck (sequential, no cumulative timeout).
    #>
    if (-not $HealthResults) { $HealthResults = @($script:Results) }
    Write-Verbose "`n[12] Swarm Reality Check"
    $results = [System.Collections.Generic.List[object]]::new()
    $monitorToken = Get-Content "/run/secrets/fleet_aqe_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if ([string]::IsNullOrWhiteSpace($monitorToken)) {
        $monitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    }
    $authHeaders = @{}
    if ($monitorToken) { $authHeaders["Authorization"] = "Bearer $monitorToken" }
    try {
        $BridgeBase = "http://mcp_aqe:$(Get-ServicePort -Service "mcp_aqe")"
        $AgentListResp = Invoke-RestMethod -Uri "${BridgeBase}/tools/agent_list" -Method POST -Body "{}" -ContentType "application/json" -Headers $authHeaders -TimeoutSec 10
        $AqeAgentCount = if ($AgentListResp.agents) { $AgentListResp.agents.Count } else { 0 }
        $SwarmAgentLines = docker service ls --filter "name=oc-" --format "{{.Name}}" 2>$null
        $SwarmAgentCount = ($SwarmAgentLines | Where-Object { $_ -match 'oc-base' }).Count

        if ($AqeAgentCount -eq 0 -and $SwarmAgentCount -gt 0) {
            Write-FleetLog "Swarm reality mismatch: AQE reports 0 agents but $SwarmAgentCount real services exist" -Level WARN
            $results.Add((Test-Step -Name "AQE agent count vs Swarm services" -Passed $false -Detail "AQE: $AqeAgentCount, Swarm: $SwarmAgentCount" -PassThru))
        } elseif ($AqeAgentCount -gt 0 -and $SwarmAgentCount -eq 0) {
            Write-FleetLog "Swarm reality mismatch: AQE reports $AqeAgentCount agents but no real services found" -Level WARN
            $results.Add((Test-Step -Name "AQE agent count vs Swarm services" -Passed $false -Detail "AQE: $AqeAgentCount, Swarm: $SwarmAgentCount" -PassThru))
        } else {
            $results.Add((Test-Step -Name "AQE agent count vs Swarm services" -Passed $true -Detail "AQE: $AqeAgentCount, Swarm: $SwarmAgentCount" -PassThru))
        }

        try {
            $FleetHealthResp = Invoke-RestMethod -Uri "${BridgeBase}/tools/fleet_health" -Method POST -Body "{}" -ContentType "application/json" -Headers $authHeaders -TimeoutSec 10
            $AqeHealthStatus = if ($FleetHealthResp.status) { $FleetHealthResp.status } else { "unknown" }
            $ActualHealthChecks = @($AgentRoles).Count
            if ($ActualHealthChecks -gt 0 -and $AqeHealthStatus -ne "unknown") {
                $AllHealthy = ($HealthResults | Where-Object { -not $_.Passed }).Count -eq 0
                $ActualStatus = if ($AllHealthy) { "healthy" } else { "degraded" }
                $results.Add((Test-Step -Name "AQE fleet health vs reality" -Passed:($AqeHealthStatus -eq $ActualStatus) -Detail "AQE: $AqeHealthStatus, Actual: $ActualStatus" -PassThru))
            } else {
                $results.Add((Test-Step -Name "AQE fleet health vs reality" -Passed $true -Detail "AQE: $AqeHealthStatus $(if ($ActualHealthChecks -eq 0) { '(no actual services to compare)' } else { '(non-blocking  -  status not comparable)' })" -PassThru))
            }
        } catch {
            $results.Add((Test-Step -Name "AQE fleet health vs reality" -Passed $true -Detail "fleet_health unreachable (non-blocking)" -PassThru))
        }
    } catch {
        $results.Add((Test-Step -Name "AQE agent_list" -Passed $true -Detail "bridge unreachable (non-blocking)" -PassThru))
        Write-FleetLog "AQE bridge unreachable during swarm reality check" -Level WARN
    }
    return $results.ToArray()
}
