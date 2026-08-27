<#
.SYNOPSIS
    Builds the Docker Swarm secret prefix for an agent.
.PARAMETER Project
    Project code (e.g. FRAD).
.PARAMETER Role
    Agent role (e.g. ORCH, VERI).
.PARAMETER Index
    Instance index; appended to role when >0.
.OUTPUTS
    String secret prefix (e.g. FRAD_ORCH or FRAD_VERI-1).
#>
function Get-AgentSecretPrefix {
    [OutputType([string])]
    param([string]$Project, [string]$Role, [int]$Index = 0)
    $roleId = if ($Index -gt 0) { "$($Role.ToUpper())-$Index" } else { $Role.ToUpper() }
    return "${Project}_${roleId}"
}
