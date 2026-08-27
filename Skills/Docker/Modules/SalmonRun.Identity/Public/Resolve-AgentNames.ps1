# ==============================================================================
# Public: Resolve-AgentNames
# ==============================================================================
# Prompts for optional custom agent names and builds a role-to-name map.
# First name wins for duplicate roles.
#
# Extracted from 0setup.ps1:325-343
# ==============================================================================
<#
.SYNOPSIS
    Prompts for optional custom agent names and builds a role-to-name map.
.PARAMETER AgentNumber
    Number of agents to assign names for.
.PARAMETER RoleArray
    Array of agent role strings in order.
.PARAMETER AgentNames
    Optional pre-defined agent name strings.
#>
function Resolve-AgentNames {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [int]$AgentNumber,

        [Parameter(Mandatory)]
        [string[]]$RoleArray,

        [Parameter()]
        [string[]]$AgentNames
    )

    $NameArray = @()
    if ($AgentNames -and $AgentNames.Count -gt 0) {
        $NameArray = $AgentNames
    } else {
        $NameConfigPrompt = Get-ConfigValue "AGENT_NAMES" "Custom names (comma-separated, e.g. Alice,Bob,Charlie)" ""
        if (-not [string]::IsNullOrWhiteSpace($NameConfigPrompt)) {
            $CleanedNames = $NameConfigPrompt -replace '^\[', '' -replace '\]$', '' -replace '"', ''
            $NameArray = @(($CleanedNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }))
        }
    }
    Write-SetupLog "Custom names: $($NameArray -join ', ')"

    $RoleNameMap = @{}
    for ($i = 0; $i -lt [Math]::Min($NameArray.Count, $AgentNumber); $i++) {
        $Role = $RoleArray[$i]
        if (-not $RoleNameMap.ContainsKey($Role)) {
            $RoleNameMap[$Role] = $NameArray[$i]
        }
    }
    Write-SetupLog "Role name map: $($RoleNameMap.GetEnumerator() -join ', ')"

    return $RoleNameMap
}
