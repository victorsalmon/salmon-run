<#
.SYNOPSIS
    Resolves the host port for an agent role and instance index.
.PARAMETER Role
    Agent role string (e.g. ORCH, VERI, BASE).
.PARAMETER Index
    Zero-based instance index for multi-instance roles.
.OUTPUTS
    Integer port number.
#>
function Get-AgentHostPort {
    [OutputType([int])]
    param([string]$Role, [int]$Index = 0)
    if (-not $script:AgentRolePorts) { return $null }
    $table = $script:AgentRolePorts[$Role.ToLower()]
    if (-not $table) { throw "Unknown role for port lookup: $Role" }
    if ($Index -ge $table.Max) { throw "$Role port index $Index exceeds max $($table.Max)" }
    return $table.Base + $Index
}
