function Get-SalmonRunGitCloudToken {
    <#
    .SYNOPSIS
        Resolves a Git-hosting token for the requested purpose.
    .DESCRIPTION
        Looks up a Git-hosting token from, in order:
        1. The supplied -SecretEnv hashtable.
        2. The environment variable specified by -EnvVarName.
        3. A default environment variable derived from -TokenType (e.g. SALMON_RUN_GITCLOUD_TOKEN_READ).
        4. The generic fallback SALMON_RUN_GITCLOUD_TOKEN.
        No credentials are written to logs.
    .PARAMETER TokenType
        Purpose of the token, e.g. 'READ', 'WRITE', 'PUSH', 'WORKTREE', 'GITHUB'.
    .PARAMETER SecretEnv
        Optional hashtable of pre-resolved secrets; keys are env var names.
    .PARAMETER EnvVarName
        Explicit env var name to read. If omitted, a default is derived from TokenType.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TokenType,

        [hashtable]$SecretEnv,

        [string]$EnvVarName
    )

    if ([string]::IsNullOrWhiteSpace($EnvVarName)) {
        $EnvVarName = "SALMON_RUN_GITCLOUD_TOKEN_$($TokenType.ToUpper())"
    }

    $value = $null
    if ($SecretEnv -and $SecretEnv.ContainsKey($EnvVarName)) {
        $value = $SecretEnv[$EnvVarName]
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [System.Environment]::GetEnvironmentVariable($EnvVarName)
    }

    if ([string]::IsNullOrWhiteSpace($value) -and $EnvVarName -ne 'SALMON_RUN_GITCLOUD_TOKEN') {
        $value = [System.Environment]::GetEnvironmentVariable('SALMON_RUN_GITCLOUD_TOKEN')
    }

    # Fall back to the Salmon Run .env resolver if the token was not in env/SecretEnv.
    if ([string]::IsNullOrWhiteSpace($value)) {
        $credCmd = Get-Command 'Get-SalmonRunCredential' -ErrorAction SilentlyContinue
        if ($credCmd) {
            try {
                $value = & $credCmd -Name $EnvVarName
            } catch {
                Write-Verbose "Get-SalmonRunGitCloudToken: credential resolver failed for '$EnvVarName': $_"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($value) -and $EnvVarName -ne 'SALMON_RUN_GITCLOUD_TOKEN') {
        $credCmd = Get-Command 'Get-SalmonRunCredential' -ErrorAction SilentlyContinue
        if ($credCmd) {
            try {
                $value = & $credCmd -Name 'SALMON_RUN_GITCLOUD_TOKEN'
            } catch {
                Write-Verbose "Get-SalmonRunGitCloudToken: credential resolver failed for 'SALMON_RUN_GITCLOUD_TOKEN': $_"
            }
        }
    }

    return $value
}
