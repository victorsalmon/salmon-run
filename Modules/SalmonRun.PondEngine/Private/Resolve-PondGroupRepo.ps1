function Resolve-PondGroupRepo {
    <#
    .SYNOPSIS
        Resolves the target code repository for a pond group.
    .DESCRIPTION
        Reads the plan's **TargetRepo**, **Target**, or **Repo** header first.
        If the header is absent or the path does not exist, it falls back to the
        namespace->repo map in the pond context config. The final fallback is
        Context.RepoDir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PondGroup]$Group,

        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    if (-not [string]::IsNullOrWhiteSpace($Group.RepoPath)) {
        return
    }

    $planPath = if ($Group.Files -and $Group.Files.Count -gt 0) { $Group.Files[0].FullName } else { $null }
    $repoPath = $null
    $nsAlias = $null

    if ($planPath -and (Test-Path -LiteralPath $planPath)) {
        $content = Get-Content -LiteralPath $planPath -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match($content, '(?im)^\*\*(TargetRepo|Target|Repo)\*\*:\s*(?<value>[^\r\n]+)')
        if ($m.Success) {
            $raw = $m.Groups['value'].Value.Trim()
            if (-not ($raw -in @('n/a', 'none'))) {
                $nsAlias = $raw
                # Strip trailing annotations like (existing) or (new).
                $repoPath = $raw -replace '\s*\([^)]*\)\s*$', ''
                # Bare values are aliases, never cwd-relative paths. Only path-shaped values
                # may resolve directly; aliases continue through the coordinator namespace map.
                if ($repoPath -match '[/\\:]' -or $repoPath -match '\.(git|ca|com)$') {
                    if (-not [System.IO.Path]::IsPathRooted($repoPath)) {
                        $repoPath = Join-Path (Get-SalmonRunRepoRoot) $repoPath
                    }
                } else {
                    $repoPath = $null
                }
            }
        }
    }

    # If the repo path we have is not a valid git repo, try the namespace map.
    $map = @{}
    if ($Context.Config -and ($Context.Config.PSObject.Properties['NamespaceRepoMap'] -or ($Context.Config | Get-Member -Name 'NamespaceRepoMap' -MemberType NoteProperty))) {
        $map = $Context.Config.NamespaceRepoMap
    }
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        # Prefer the explicit TargetRepo alias, then the full group namespace,
        # then the first hyphenated segment of the namespace.
        $nsFirstSegment = ''
        if ($Group.Namespace -match '^([^-]+)') {
            $nsFirstSegment = $Matches[1]
        }
        $keys = @($nsAlias, $Group.Namespace, $nsFirstSegment) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        foreach ($key in $keys) {
            if ($map -and $map.ContainsKey($key)) {
                $repoPath = $map[$key]
                break
            }
        }
    }

    # Fall back to the context default.
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        $repoPath = if ($Context.RepoDir) { $Context.RepoDir } else { Get-SalmonRunRepoRoot }
    }

    $repoPath = [System.IO.Path]::GetFullPath($repoPath)
    $Group.RepoPath = $repoPath
}
