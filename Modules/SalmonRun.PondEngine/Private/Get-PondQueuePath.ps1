<#
.SYNOPSIS
    Resolves the on-disk queue path for a pond.
.DESCRIPTION
    Uses the pond's Folder property. If it starts with 'Tasks/', the
    'Tasks/' prefix is stripped and the remainder is joined to the
    canonical task root (e.g. ~/.salmon/Tasks). Otherwise the Folder is
    treated as a queue name under the task root.
#>
function Get-PondQueuePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $folder = $Pond.Folder
    if ($folder -match '^Tasks[/\\](.+)$') {
        $folder = $Matches[1]
    }
    return Join-Path $Context.TaskRoot $folder
}
