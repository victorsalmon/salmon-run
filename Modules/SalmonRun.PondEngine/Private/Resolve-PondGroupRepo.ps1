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

    if ($planPath -and (Test-Path -LiteralPath $planPath)) {
        $content = Get-Content -LiteralPath $planPath -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match($content, '(?im)^\*\*(TargetRepo|Target|Repo)\*\*:\s*(?<value>[^\r\n]+)')
        if ($m.Success) {
            $raw = $m.Groups['value'].Value.Trim()
            if (-not ($raw -in @('n/a', 'none'))) {
                $repoPath = $raw
                # Strip trailing annotations like (existing) or (new).
                $repoPath = $repoPath -replace '\s*\([^)]*\)\s*$', ''
                # If it looks like a namespace alias (no path separators or .git), leave it for mapping.
                if ($repoPath -match '[/\\:]' -or $repoPath -match '\.(git|ca|com)$') {
                    if (-not [System.IO.Path]::IsPathRooted($repoPath)) {
                        $repoPath = Join-Path (Get-SalmonRunRepoRoot) $repoPath
                    }
                }
            }
        }
    }

    # If no explicit target repo, use the namespace map.
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        $map = @{}
        if ($Context.Config -and ($Context.Config.PSObject.Properties['NamespaceRepoMap'] -or ($Context.Config | Get-Member -Name 'NamespaceRepoMap' -MemberType NoteProperty))) {
            $map = $Context.Config.NamespaceRepoMap
        }
        $ns = $Group.Namespace
        if ($map -and -not [string]::IsNullOrWhiteSpace($ns) -and $map.ContainsKey($ns)) {
            $repoPath = $map[$ns]
        }
    }

    # Fall back to the context default.
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        $repoPath = if ($Context.RepoDir) { $Context.RepoDir } else { Get-SalmonRunRepoRoot }
    }

    $Group.RepoPath = $repoPath
}
