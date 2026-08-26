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
        [string]$Repo
    )

    switch ($Provider) {
        'GitHub'   { return "https://github.com/$Owner/$Repo.git" }
        'Worktree' { return "https://worktree.ca/$Owner/$Repo.git" }
        default    { throw "Unknown GitCloud provider: $Provider" }
    }
}
