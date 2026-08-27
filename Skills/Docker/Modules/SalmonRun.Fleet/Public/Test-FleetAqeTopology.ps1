<#
.SYNOPSIS
    Records that the retired AQE sidecar topology check was skipped.
#>
function Test-FleetAqeTopology {
    [OutputType([array])]
    param([array]$AgentRoles)

    Write-Verbose "`n[11] AQE Topology Analysis"
    @(
        Test-Step -Name "AQE topology analysis" -Passed $true `
            -Detail "Skipped: mcp_aqe was retired; use the /aqe skill and local quality scripts." -PassThru
    )
}
