function Invoke-PondTaskClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: claim plan files and move into a lane/stream directory
    return $Context
}
