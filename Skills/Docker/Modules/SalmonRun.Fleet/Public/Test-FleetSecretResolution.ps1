<#
.SYNOPSIS
    Checks that Docker secrets are resolved and no missing env vars in agent logs.
#>
function Test-FleetSecretResolution {
    [OutputType([array])]
    param([array]$AgentRoles, [string]$StackName, [array]$StackServices)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[6] Secret Resolution"
    foreach ($Agent in $AgentRoles) {
        $SvcName = Get-AgentServiceName -Role $Agent.Role -Index $Agent.Index
        $ContainerId = docker ps --filter "name=oc-" --format "{{.ID}}" 2>$null | Where-Object { $null -ne (docker inspect $_ --format "{{.Name}}" 2>$null) -and (docker inspect $_ --format "{{.Name}}" 2>$null) -match "$SvcName\." }
        $Logs = if ($ContainerId) { docker logs $ContainerId --tail 20 2>&1 } else { $FullSvcName = $StackServices | ForEach-Object { ($_ -split "`t")[0] } | Where-Object { $_ -match "${StackName}_${SvcName}`$" }; if ($FullSvcName) { docker service logs $FullSvcName --tail 20 2>$null } else { "" } }
        $ErrDetail = if ($Logs -match "missing env var `"([^`"]+)`"") { $Matches[1] } elseif ($Logs -match "SecretRefResolutionError") { "Secret resolution error" } else { $null }
        $r = Test-Step -Name "Agent $SvcName secret resolution" -Passed:(-not $ErrDetail) -Detail $(if ($ErrDetail) { "Unresolved: $ErrDetail" } else { "no missing env vars detected" }) -PassThru; if ($r) { $results.Add($r) }
        $ConfigErr = [regex]::Match($Logs, "Config[^:]*:?\s*(.*)", 'RightToLeft')
        $r = Test-Step -Name "Agent $SvcName config validation" -Passed:(-not $ConfigErr.Success) -Detail $(if ($ConfigErr.Success) { $ConfigErr.Groups[1].Value.Trim() } else { "config valid" }) -PassThru; if ($r) { $results.Add($r) }
    }
    return $results.ToArray()
}
