function Get-PondRepositoryKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoPath)

    if (-not (Get-Variable -Name PondRepositoryKeyCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:PondRepositoryKeyCache = @{}
    }

    $inputPath = [IO.Path]::GetFullPath($RepoPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $cacheKey = $inputPath.ToLowerInvariant()
    if ($script:PondRepositoryKeyCache.ContainsKey($cacheKey)) {
        return $script:PondRepositoryKeyCache[$cacheKey]
    }

    $identityPath = $inputPath
    $resolvedFromGit = $false
    if (Test-Path -LiteralPath $inputPath) {
        $commonDir = (& git -C $inputPath rev-parse --git-common-dir 2>$null) -as [string]
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commonDir)) {
            $candidate = if ([IO.Path]::IsPathRooted($commonDir)) { $commonDir } else { Join-Path $inputPath $commonDir }
            $resolvedCommon = (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue)?.Path
            if (-not [string]::IsNullOrWhiteSpace($resolvedCommon)) {
                $identityPath = $resolvedCommon
                $resolvedFromGit = $true
            }
        }
    }

    $resolvedIdentity = (Resolve-Path -LiteralPath $identityPath -ErrorAction SilentlyContinue)?.Path
    if (-not [string]::IsNullOrWhiteSpace($resolvedIdentity)) { $identityPath = $resolvedIdentity }
    $normalized = [IO.Path]::GetFullPath($identityPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ).ToLowerInvariant()
    $repositoryKey = "repo:$normalized"

    # Cache only Git-confirmed identities. A nonexistent planned worktree may
    # acquire a different common-directory identity after it is created.
    if ($resolvedFromGit) { $script:PondRepositoryKeyCache[$cacheKey] = $repositoryKey }
    return $repositoryKey
}