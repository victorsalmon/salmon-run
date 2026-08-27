<#
.SYNOPSIS
    Builds the Docker Swarm service name for an agent role.
.PARAMETER Role
    Agent role (e.g. ORCH, VERI, BASE).
.PARAMETER Index
    Instance index; appended as suffix when >0.
.OUTPUTS
    String service name (e.g. oc-base or oc-base-1).
#>
function Get-AgentServiceName {
    [OutputType([string])]
    param([string]$Role, [int]$Index = 0)
    $suffix = if ($Index -gt 0) { "-$Index" } else { "" }
    return "oc-$($Role.ToLower())$suffix"
}
