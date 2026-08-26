function Get-WorktreeToken {
    <#
    .SYNOPSIS
        Resolves a worktree.ca API token.
    .DESCRIPTION
        Reads from the env var WORKTREE_REPO_RW_ACCESS_TOKEN by default.
        Accepts an override hashtable for pre-resolved secrets.
    .PARAMETER SecretEnv
        Optional hashtable of pre-resolved secrets.
    .PARAMETER EnvVarName
        Explicit env var name override.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [hashtable]$SecretEnv,

        [string]$EnvVarName = 'WORKTREE_REPO_RW_ACCESS_TOKEN'
    )

    $value = $null
    if ($SecretEnv -and $SecretEnv.ContainsKey($EnvVarName)) {
        $value = $SecretEnv[$EnvVarName]
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [System.Environment]::GetEnvironmentVariable($EnvVarName)
    }

    return $value
}

Set-Alias -Name Get-GitCloudWorktreeToken -Value Get-WorktreeToken
