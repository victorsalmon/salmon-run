function Invoke-PondTaskTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    # TODO: move result files to next pond (OnSuccess or OnFailure)
    return $Context
}
