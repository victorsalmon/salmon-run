<#
.SYNOPSIS
    Verifies required Docker overlay networks exist for the stack.
#>
function Test-FleetNetworkConnectivity {
    [OutputType([array])]
    param([string]$StackName)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[7] Network Connectivity"
    foreach ($NetName in @((Get-NetworkNames).ServiceNet, (Get-NetworkNames).OrchestrationNet)) {
        $r = Test-Step -Name "Network $NetName" -Passed:(@(docker network ls --format "{{.Name}}" 2>$null) -contains $NetName) -PassThru; if ($r) { $results.Add($r) }
    }
    return $results.ToArray()
}
