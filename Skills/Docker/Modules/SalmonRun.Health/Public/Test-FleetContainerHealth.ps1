<#
.SYNOPSIS
    Checks agent containers are running, healthy, and have no crash history.
.PARAMETER AgentRoles
    Array of agent role objects with Role and Index properties.
#>
function Test-FleetContainerHealth {
    [OutputType([array])]
    param([array]$AgentRoles)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[5] Agent Container Health"
    foreach ($Agent in $AgentRoles) {
        $SvcName = Get-AgentServiceName -Role $Agent.Role -Index $Agent.Index
        $ContainerLine = docker ps --filter "name=oc-" --format "{{.ID}}|{{.Names}}|{{.Status}}" 2>$null | Where-Object { $_ -match "$SvcName\." }
        if (-not $ContainerLine) {
            $r = Test-Step -Name "Agent $SvcName container running" -Passed $false -Detail "No container found" -PassThru; if ($r) { $results.Add($r) }
            continue
        }
        $StatusParts = $ContainerLine -split "\|"
        $r = Test-Step -Name "Agent $SvcName container status" -Passed:($StatusParts[2] -match "Up|healthy") -Detail $StatusParts[2] -PassThru; if ($r) { $results.Add($r) }
        $ExitCount = @(docker ps --all --filter "name=oc-" --format "{{.Names}}|{{.Status}}" 2>$null | Where-Object { $_ -match "$SvcName\." -and $_ -match "Exited" }).Count
        $r = Test-Step -Name "Agent $SvcName crash history" -Passed:($ExitCount -eq 0) -Detail $(if ($ExitCount -gt 0) { "$ExitCount previous exited container(s) (crash loop)" } else { "no previous crashes" }) -PassThru; if ($r) { $results.Add($r) }
    }
    return $results.ToArray()
}
