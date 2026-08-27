<#
.SYNOPSIS
Returns unique active agent roles from the running Docker Swarm stack.
#>
function Get-ActiveAgentRoles {
    [OutputType([pscustomobject[]])]
    param()
    $StackName = Get-StackName
    $ServiceList = docker stack services $StackName --format "{{.Name}}" 2>$null
    $Agents = [System.Collections.Generic.List[object]]::new()
    foreach ($Svc in $ServiceList) {
        if ($Svc -match 'oc-base(?:-(\d+))?') {
            $role = 'BASE'
            $idx = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
            $shortName = 'oc-' + $role.ToLower() + $(if ($idx -and $idx -ne 0) { "-$idx" } else { '' })
            $Agents.Add(@{
                Role       = $role
                Index      = $idx
                ShortName  = $shortName
            })
        }
    }
    $Seen = @{}
    $Unique = [System.Collections.Generic.List[object]]::new()
    foreach ($A in ($Agents | Sort-Object { "$($_.Role)-$($_.Index)" })) {
        $Key = "$($A.Role)-$($A.Index)"
        if (-not $Seen.ContainsKey($Key)) {
            $Seen[$Key] = $true
            $Unique.Add($A)
        }
    }
    return ,$Unique.ToArray()
}
