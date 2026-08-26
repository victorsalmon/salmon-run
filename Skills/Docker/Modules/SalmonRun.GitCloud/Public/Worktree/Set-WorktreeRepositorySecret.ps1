function Set-WorktreeRepositorySecret {
    <#
    .SYNOPSIS
        Sets or updates a repository secret on worktree.ca.
    .DESCRIPTION
        Uses the worktree Actions secrets API to store a named secret value.
        The token must have write access to the repository.
    .PARAMETER Owner
        Repository owner/organization on worktree.ca.
    .PARAMETER Repo
        Repository name on worktree.ca.
    .PARAMETER Name
        Name of the secret to set.
    .PARAMETER Value
        Secret value.
    .PARAMETER Token
        worktree.ca API token. If omitted, resolved via Get-WorktreeToken.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value,

        [string]$Token
    )

    $resolvedToken = if ($Token) { $Token } else { Get-WorktreeToken }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw "Set-WorktreeRepositorySecret: no worktree token available. Set WORKTREE_REPO_RW_ACCESS_TOKEN or pass -Token."
    }

    $headers = @{
        'Authorization'  = "token $resolvedToken"
        'Accept'         = 'application/json'
        'Content-Type'   = 'application/json'
    }
    $body = @{ data = $Value } | ConvertTo-Json -Compress
    $uri = "https://worktree.ca/api/v1/repos/$Owner/$Repo/actions/secrets/$Name"

    try {
        $null = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; Owner = $Owner; Repo = $Repo; Name = $Name }
    } catch {
        throw "Set-WorktreeRepositorySecret: failed to set secret $Name for $Owner/$Repo`: $_"
    }
}
