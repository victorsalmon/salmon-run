<#
.SYNOPSIS
    Records that the retired AQE-to-Swarm comparison was skipped.
#>
function Test-FleetSwarmReality {
    [OutputType([array])]
    param(
        [array]$AgentRoles,
        [array]$HealthResults
    )

    Write-Verbose "`n[12] Swarm Reality Check"
    @(
        Test-Step -Name "AQE-to-Swarm reality check" -Passed $true `
            -Detail "Skipped: mcp_aqe was retired; no AQE sidecar state is available for comparison." -PassThru
    )
}
