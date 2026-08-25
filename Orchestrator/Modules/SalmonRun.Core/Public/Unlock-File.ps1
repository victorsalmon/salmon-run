<#
.SYNOPSIS
    Unlocks one or more files by removing their lock files.
.DESCRIPTION
    Removes the .lock files for the specified filenames from Tasks/Locks/.
    Silently continues if a lock file does not exist.
    Alias: Release-FileLock
.PARAMETER FileNames
    One or more lock file names (without .lock extension) to release.
#>
function Unlock-File {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string[]]$FileNames
    )

    $repoRoot = Get-SalmonRunRepoRoot
    $locksDir = Join-Path $repoRoot "Tasks" "Locks"

    foreach ($name in $FileNames) {
        $lockPath = Join-Path $locksDir "$name.lock"
        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
    }
}
