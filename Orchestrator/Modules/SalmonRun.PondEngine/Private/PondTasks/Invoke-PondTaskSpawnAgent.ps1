function Invoke-PondTaskSpawnAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: spawn agent subprocess for the current group
    return $Context
}
