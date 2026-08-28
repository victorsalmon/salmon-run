function Invoke-PondLanePipeline {
    <#
    .SYNOPSIS
        Validates or executes a pond pipeline inside PondEngine-owned scope.
    .DESCRIPTION
        Centralizes string-to-function resolution for parent and child lanes so
        private task implementations are never resolved by an external caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,

        [PondContext]$Context,

        [switch]$SkipClaim,

        [switch]$ValidateOnly
    )

    foreach ($task in $Pond.Tasks) {
        if ($SkipClaim -and $task.Name -eq 'Claim') { continue }

        $taskFunction = Get-Command $task.Function -CommandType Function -ErrorAction SilentlyContinue
        if (-not $taskFunction) {
            throw "POND_TASK_NOT_FOUND pond=$($Pond.Name) task=$($task.Name) function=$($task.Function)"
        }

        if ($ValidateOnly) { continue }
        if (-not $Context) {
            throw 'Invoke-PondLanePipeline requires Context unless ValidateOnly is set.'
        }
        if (-not $Context.Continue) { break }

        $Context = & $taskFunction -Pond $Pond -Task $task -Context $Context
    }

    if (-not $ValidateOnly) { return $Context }
}
