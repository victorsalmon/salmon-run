function Get-WorktreeToken {
    <#
    .SYNOPSIS
        Resolves a Worktree / Gitea-compatible API token.
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

    # Fall back to the Salmon Run .env resolver.
    if ([string]::IsNullOrWhiteSpace($value)) {
        $credCmd = Get-Command 'Get-SalmonRunCredential' -ErrorAction SilentlyContinue
        if ($credCmd) {
            try {
                $value = & $credCmd -Name $EnvVarName
            } catch {
                Write-Verbose "Get-WorktreeToken: credential resolver failed for '$EnvVarName': $_"
            }
        }
    }

    return $value
}

Set-Alias -Name Get-GitCloudWorktreeToken -Value Get-WorktreeToken
