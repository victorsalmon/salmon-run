<#
.SYNOPSIS
    Finds and reserves a free lane for the given pond/role.
#>
function Get-FreePondLane {
    [CmdletBinding()]
    [OutputType([PondLane])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    foreach ($stream in $Context.Streams) {
        foreach ($lane in $stream.Lanes.Values) {
            if ($lane.Role -eq $Pond.Role -and $lane.Idle) {
                $lane.Idle = $false
                return $lane
            }
        }
    }
    return $null
}
