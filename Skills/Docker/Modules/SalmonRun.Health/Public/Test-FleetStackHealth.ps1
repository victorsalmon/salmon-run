<#
.SYNOPSIS
    Validates basic Docker Swarm stack health: daemon, services, replicas.
#>
function Test-FleetStackHealth {
    [OutputType([array])]
    param([string]$StackName, [array]$AgentRoles, [array]$StackServices)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[1] Basic Stack Health"
    $r = Test-Step -Name "Docker daemon running" -Passed:($null -ne (docker info 2>$null | Select-String "Server Version")) -PassThru; if ($r) { $results.Add($r) }
    $r = Test-Step -Name "Stack name resolved" -Passed $true -Detail $StackName -PassThru; if ($r) { $results.Add($r) }
    $ServiceCount = ($StackServices | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    $r = Test-Step -Name "Stack services found" -Passed:($ServiceCount -ge $AgentRoles.Count) -Detail "$ServiceCount services" -PassThru; if ($r) { $results.Add($r) }
    $r = Test-Step -Name "Swarm node active" -Passed:($null -ne (docker node ls --format "{{.ID}}" 2>$null)) -PassThru; if ($r) { $results.Add($r) }

    Write-Verbose "`n[2] Service Health"
    foreach ($SvcLine in $StackServices) {
        if ([string]::IsNullOrWhiteSpace($SvcLine)) { continue }
        $Parts = $SvcLine -split "`t"
        $Current = if ($Parts[1] -match "^(\d+)/") { [int]$Matches[1] } else { 0 }
        $Desired = if ($Parts[1] -match "/(\d+)$") { [int]$Matches[1] } else { 0 }
        $r = Test-Step -Name "$($Parts[0]) replicas" -Passed:($Current -ge $Desired -and $Desired -gt 0) -Detail "$($Parts[1]) ($($Parts[2]))" -PassThru; if ($r) { $results.Add($r) }
    }
    return $results.ToArray()
}
