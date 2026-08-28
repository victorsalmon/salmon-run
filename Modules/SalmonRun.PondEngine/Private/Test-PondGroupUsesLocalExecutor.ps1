function Test-PondGroupUsesLocalExecutor {
    <#
    .SYNOPSIS
        Returns true when every plan in a group explicitly selects Local.
    .DESCRIPTION
        Local is the in-process deterministic harness used for packaging and
        regression tests. It must not require a git worktree or child process.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [PondGroup]$Group
    )

    if (-not $Group.Files -or $Group.Files.Count -eq 0) { return $false }

    foreach ($file in $Group.Files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch '(?im)^\*\*Challenge\*\*:\s*Local\s*$') {
            return $false
        }
    }

    return $true
}
