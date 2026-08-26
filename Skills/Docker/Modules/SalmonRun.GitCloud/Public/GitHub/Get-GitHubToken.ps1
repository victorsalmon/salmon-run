function Get-GitHubToken {
    <#
    .SYNOPSIS
        Resolves a GitHub token.
    .DESCRIPTION
        Reads from the env var GITHUB_TOKEN by default, with an optional
        TokenType suffix (e.g. GITHUB_TOKEN_READ). Accepts an override
        hashtable for pre-resolved secrets.
    .PARAMETER TokenType
        Token purpose (e.g. READ, WRITE, PUSH).
    .PARAMETER SecretEnv
        Optional hashtable of pre-resolved secrets.
    .PARAMETER EnvVarName
        Explicit env var name override.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$TokenType = 'READ',

        [hashtable]$SecretEnv,

        [string]$EnvVarName
    )

    if ([string]::IsNullOrWhiteSpace($EnvVarName)) {
        $EnvVarName = "GITHUB_TOKEN_$($TokenType.ToUpper())"
    }

    $value = $null
    if ($SecretEnv -and $SecretEnv.ContainsKey($EnvVarName)) {
        $value = $SecretEnv[$EnvVarName]
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [System.Environment]::GetEnvironmentVariable($EnvVarName)
    }

    if ([string]::IsNullOrWhiteSpace($value) -and $EnvVarName -ne 'GITHUB_TOKEN') {
        $value = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
    }

    return $value
}

Set-Alias -Name Get-GitCloudGitHubToken -Value Get-GitHubToken
