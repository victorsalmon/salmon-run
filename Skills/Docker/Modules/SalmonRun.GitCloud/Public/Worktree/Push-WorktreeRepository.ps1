function Push-WorktreeRepository {
    <#
    .SYNOPSIS
        Pushes the current Git repository to worktree.ca.
    .DESCRIPTION
        Resolves the remote URL and current branch, then invokes a git push with
        a temporary GIT_ASKPASS helper. The worktree quarantine pack limit can be
        avoided by setting -SplitThreshold to a positive number of changed files;
        the function then pushes commit-by-commit in small batches.
    .PARAMETER Owner
        Repository owner/organization on worktree.ca.
    .PARAMETER Repo
        Repository name on worktree.ca.
    .PARAMETER Branch
        Branch to push. Defaults to the current branch.
    .PARAMETER Token
        worktree.ca API token. If omitted, resolved via Get-WorktreeToken.
    .PARAMETER EnvVarName
        Optional env var name override for token resolution.
    .PARAMETER SplitThreshold
        If the working tree has more modified files than this threshold, the
        current commit range is split into smaller sequential commits and pushed
        one batch at a time. Set to 0 (default) to disable batching.
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

        [string]$EnvVarName,

        [int]$SplitThreshold = 0
    )

    $resolvedToken = if ($Token) { $Token } else { Get-WorktreeToken -EnvVarName $EnvVarName }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw "Push-WorktreeRepository: no worktree token available. Set WORKTREE_REPO_RW_ACCESS_TOKEN or pass -Token."
    }

    $remoteUrl = Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner $Owner -Repo $Repo
    $pushBranch = if ($Branch) { $Branch } else { (git branch --show-current 2>$null) }
    if ([string]::IsNullOrWhiteSpace($pushBranch)) {
        throw "Push-WorktreeRepository: could not determine current branch. Run from a git checkout."
    }

    if ($SplitThreshold -gt 0) {
        $status = (git status --short 2>$null) | Measure-Object
        if ($status.Count -gt $SplitThreshold) {
            Write-Warning "Push-WorktreeRepository: worktree quarantine limit likely; splitting into smaller pushes."
            return Split-WorktreeRepositoryPush -RemoteUrl $remoteUrl -Branch $pushBranch -Token $resolvedToken -SplitThreshold $SplitThreshold
        }
    }

    return Invoke-WorktreeGitPush -RemoteUrl $remoteUrl -Branch $pushBranch -Token $resolvedToken
}
