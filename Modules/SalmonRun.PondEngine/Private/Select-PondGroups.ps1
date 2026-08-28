<#
.SYNOPSIS
    Selects which pond groups can be dispatched given current stream capacity.
.DESCRIPTION
    Counts free lanes for the pond's role across all streams, applies the
    pond's MinGuarantee, and returns up to ParallelCount groups.
#>
function Select-PondGroups {
    [CmdletBinding()]
    [OutputType([PondGroup[]])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondGroup[]]$Groups,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $freeLanes = 0
    foreach ($stream in $Context.Streams) {
        foreach ($lane in $stream.Lanes.Values) {
            if ($lane.Role -eq $Pond.Role -and $lane.Idle) { $freeLanes++ }
        }
    }

    # Free lanes already account for active work across all streams.  Respect the
    # pond's per-iteration throttle and the number of candidate groups.
    $maxNew = if ($Pond.Operators.MaxNewPerIteration -gt 0) { $Pond.Operators.MaxNewPerIteration } else { $freeLanes }
    $limit = [math]::Min($freeLanes, $maxNew)
    $limit = [math]::Min($limit, $Groups.Count)

    if ($limit -le 0) { return @() }

    # Prefer groups whose namespace is not already in use
    $available = @($Groups | Where-Object { -not $Context.UsedNamespaces.ContainsKey($_.Namespace) })
    if ($available.Count -eq 0) { return @() }

    return @($available | Select-Object -First $limit)
}
