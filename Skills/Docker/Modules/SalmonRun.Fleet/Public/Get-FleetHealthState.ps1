<#
.SYNOPSIS
    Returns the current Fleet health state hashtable.
#>
function Get-FleetHealthState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:FleetHealthState
}
