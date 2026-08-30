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

    # A resolved repository is a hard stream constraint. During stream bootstrap,
    # the configured worktree path is authoritative even though it does not exist
    # yet and therefore cannot resolve through Git. Once paths exist, canonical
    # common-directory identity keeps every worktree of one repository together.
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $requestedFullPath = try { [System.IO.Path]::GetFullPath($RepoPath).TrimEnd([char[]]'\/') } catch { $RepoPath.TrimEnd([char[]]'\/') }
        $requestedKey = Get-PondRepositoryKey -RepoPath $RepoPath
        foreach ($stream in $Context.Streams) {
            $streamFullPath = try { [System.IO.Path]::GetFullPath($stream.Path).TrimEnd([char[]]'\/') } catch { $stream.Path.TrimEnd([char[]]'\/') }
            $isConfiguredStreamPath = $streamFullPath -eq $requestedFullPath
            if (-not $isConfiguredStreamPath) {
                $streamRepo = if ($stream.PSObject.Properties['BaseRepo'] -and -not [string]::IsNullOrWhiteSpace($stream.BaseRepo)) { $stream.BaseRepo } else { $stream.Path }
                if ((Get-PondRepositoryKey -RepoPath $streamRepo) -ne $requestedKey) { continue }
            }
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
