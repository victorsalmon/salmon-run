function Get-WorktreeCiRun {
    <#
    .SYNOPSIS
        Queries the latest Worktree Actions CI runs for a repository.
    .DESCRIPTION
        Returns objects with run_number, status, and head_sha for the latest
        -Count CI runs.
    .PARAMETER Owner
        Repository owner/organization on the Worktree / Gitea-compatible host.
    .PARAMETER Repo
        Repository name on the Worktree / Gitea-compatible host.
    .PARAMETER Count
        Maximum number of runs to return. Defaults to 3.
    .PARAMETER Token
        Worktree API token. If omitted, resolved via Get-WorktreeToken.
    .PARAMETER WorktreeHost
        Optional Worktree / Gitea-compatible host. Defaults to the configured
        WORKTREE_HOST (from ~/.salmon/.env or $env:WORKTREE_HOST), falling back
        to https://worktree.example.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [int]$Count = 3,

        [string]$Token,

        [string]$WorktreeHost
    )

    $resolvedToken = if ($Token) { $Token } else { Get-WorktreeToken }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw "Get-WorktreeCiRun: no worktree token available. Set WORKTREE_REPO_RW_ACCESS_TOKEN or pass -Token."
    }

    $hostName = if ($WorktreeHost) { $WorktreeHost } else { Get-WorktreeHost }
    $headers = @{
        'Authorization' = "token $resolvedToken"
        'Accept'        = 'application/json'
    }
    $uri = "$hostName/api/v1/repos/$Owner/$Repo/actions/tasks"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        $runs = if ($response.workflow_runs) { $response.workflow_runs } else { @() }
        return $runs | Select-Object -First $Count | ForEach-Object {
            [pscustomobject]@{
                RunNumber = $_.run_number
                Status    = $_.status
                HeadSha   = if ($_.head_sha) { $_.head_sha.Substring(0, [Math]::Min(7, $_.head_sha.Length)) } else { '' }
            }
        }
    } catch {
        throw "Get-WorktreeCiRun: failed to query worktree CI for $Owner/$Repo`: $_"
    }
}

