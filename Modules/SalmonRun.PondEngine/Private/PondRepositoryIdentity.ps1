function Get-PondRepositoryKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoPath)

    $identityPath = $RepoPath
    if (Test-Path -LiteralPath $RepoPath) {
        $commonDir = (& git -C $RepoPath rev-parse --git-common-dir 2>$null) -as [string]
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commonDir)) {
            $candidate = if ([IO.Path]::IsPathRooted($commonDir)) { $commonDir } else { Join-Path $RepoPath $commonDir }
            $resolvedCommon = (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue)?.Path
            if (-not [string]::IsNullOrWhiteSpace($resolvedCommon)) { $identityPath = $resolvedCommon }
        }
    }
    $resolved = (Resolve-Path -LiteralPath $identityPath -ErrorAction SilentlyContinue)?.Path
    if (-not [string]::IsNullOrWhiteSpace($resolved)) { $identityPath = $resolved }
    $normalized = [IO.Path]::GetFullPath($identityPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).ToLowerInvariant()
    return "repo:$normalized"
}