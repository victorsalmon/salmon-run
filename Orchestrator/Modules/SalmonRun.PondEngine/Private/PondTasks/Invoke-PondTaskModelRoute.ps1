function Invoke-PondTaskModelRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: resolve model/harness for the current group
    return $Context
}
