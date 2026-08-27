<#
.SYNOPSIS
    Checks whether a deploy phase's dependency prerequisites are met.
.DESCRIPTION
    Verifies that all required predecessor phases appear in the completed
    phases list. Returns $true if dependencies are satisfied or none exist.
#>
function Test-DeployPhasePrerequisites {
    param(
        [string]$PhaseName,
        [hashtable]$PhaseDependencies,
        [string[]]$CompletedPhases
    )
    if (-not $PhaseDependencies.ContainsKey($PhaseName)) { return $true }
    $deps = $PhaseDependencies[$PhaseName]
    if ($deps.Count -eq 0) { return $true }
    $missing = $deps | Where-Object { $CompletedPhases -notcontains $_ }
    if ($missing) {
        Write-Information -MessageData "  [SKIP] Phase '$PhaseName' requires: $($missing -join ', ')" -Tags "WARN"
        return $false
    }
    return $true
}
