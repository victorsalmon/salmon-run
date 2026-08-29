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
        [PondContext]$Context,

        [string]$RepoPath = ''
    )

    # A resolved repository is a hard stream constraint. Worktree paths differ
    # from base-repository paths, so compare their canonical Git common-directory identity.
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $requestedKey = Get-PondRepositoryKey -RepoPath $RepoPath
        foreach ($stream in $Context.Streams) {
            $streamRepo = if ($stream.PSObject.Properties['BaseRepo'] -and -not [string]::IsNullOrWhiteSpace($stream.BaseRepo)) { $stream.BaseRepo } else { $stream.Path }
            if ((Get-PondRepositoryKey -RepoPath $streamRepo) -ne $requestedKey) { continue }
            foreach ($lane in $stream.Lanes.Values) {
                if ($lane.Role -eq $Pond.Role -and $lane.Idle) {
                    $lane.Idle = $false
                    return $lane
                }
            }
        }
        return $null
    }

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
