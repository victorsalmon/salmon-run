function Get-SalmonRunGitCloudRemoteUrl {
    <#
    .SYNOPSIS
        Resolves a canonical Git HTTPS remote URL for a provider, owner, and repo.
    .DESCRIPTION
        Returns an HTTPS URL without embedded credentials. Callers that need
        authenticated pushes should combine this with a token-based credential
        helper such as the Push-* provider functions in this module.
    .PARAMETER Provider
        Git host: GitHub or Worktree.
    .PARAMETER Owner
        Repository owner/organization.
    .PARAMETER Repo
        Repository name.
    .PARAMETER WorktreeHost
        Optional Worktree / Gitea-compatible host. Defaults to the configured
        WORKTREE_HOST (from ~/.salmon/.env or $env:WORKTREE_HOST), falling back
        to https://worktree.example.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GitHub', 'Worktree')]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [string]$WorktreeHost
    )

    switch ($Provider) {
        'GitHub'   { return "https://github.com/$Owner/$Repo.git" }
        'Worktree' {
            $hostName = if ($WorktreeHost) { $WorktreeHost } else { Get-WorktreeHost }
            return "$hostName/$Owner/$Repo.git"
        }
        default    { throw "Unknown GitCloud provider: $Provider" }
    }
}

