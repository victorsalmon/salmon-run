function Get-WorktreeHost {
    <#
    .SYNOPSIS
        Resolves the Worktree / Gitea-compatible host to use for API and Git URLs.
    .DESCRIPTION
        Checks, in order:
        1. The $env:WORKTREE_HOST environment variable.
        2. A WORKTREE_HOST entry in ~/.salmon/.env (or %SALMON_RUN_HOME%/.env).
        3. The public-safe default https://worktree.example.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:WORKTREE_HOST)) {
        return $env:WORKTREE_HOST
    }

    $salmonHome = if (Get-Command Get-SalmonHome -ErrorAction SilentlyContinue) {
        Get-SalmonHome
    } else {
        if (-not [string]::IsNullOrWhiteSpace($env:SALMON_RUN_HOME)) {
            $env:SALMON_RUN_HOME
        } else {
            Join-Path $HOME '.salmon'
        }
    }

    $envPath = Join-Path $salmonHome '.env'
    if (Test-Path $envPath -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadLines($envPath)) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

            # Strip inline comment after unquoted #
            $commentIndex = $trimmed.IndexOf(' #')
            if ($commentIndex -gt 0) { $trimmed = $trimmed.Substring(0, $commentIndex).TrimEnd() }

            if ($trimmed -notmatch '^WORKTREE_HOST\s*=\s*(.+)$') { continue }

            $value = $Matches[1].Trim()

            # Remove wrapping quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return 'https://worktree.example'
}
