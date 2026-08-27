function Push-GitHubRepository {
    <#
    .SYNOPSIS
        Pushes the current Git repository to GitHub using token-based HTTPS auth.
    .DESCRIPTION
        Resolves the remote URL and current branch, then invokes a git push with
        a temporary GIT_ASKPASS helper. If -Branch is omitted, the current branch
        is used.
    .PARAMETER Owner
        Repository owner/organization.
    .PARAMETER Repo
        Repository name.
    .PARAMETER Branch
        Branch to push. Defaults to the current branch (git branch --show-current).
    .PARAMETER Token
        GitHub token. If omitted, resolved via Get-GitHubToken.
    .PARAMETER EnvVarName
        Optional env var name override for token resolution.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [string]$Branch,

        [string]$Token,

        [string]$EnvVarName
    )

    $resolvedToken = if ($Token) { $Token } else { Get-GitHubToken -EnvVarName $EnvVarName }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw "Push-GitHubRepository: no GitHub token available. Set GITHUB_TOKEN or pass -Token."
    }

    $remoteUrl = Get-SalmonRunGitCloudRemoteUrl -Provider GitHub -Owner $Owner -Repo $Repo
    $pushBranch = if ($Branch) { $Branch } else { (git branch --show-current 2>$null) }
    if ([string]::IsNullOrWhiteSpace($pushBranch)) {
        throw "Push-GitHubRepository: could not determine current branch. Run from a git checkout."
    }

    return Invoke-SalmonRunGitCloudPush -RemoteUrl $remoteUrl -RefSpec $pushBranch -Token $resolvedToken
}
