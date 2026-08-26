function Invoke-PondTaskPrepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: per-file prep (reset lock headers, preserve evidence, etc.)
    return $Context
}
