function Invoke-PondTaskArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: compress and archive plans older than configured age
    return $Context
}
