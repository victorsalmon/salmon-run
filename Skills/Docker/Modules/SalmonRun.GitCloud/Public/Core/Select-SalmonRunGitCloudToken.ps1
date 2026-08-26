function Select-SalmonRunGitCloudToken {
    <#
    .SYNOPSIS
        Selects the appropriate Git-hosting token for a high-level operation.
    .DESCRIPTION
        Maps a high-level Git operation (read/write/push/clone/fetch) to a
        token type and resolves it via Get-SalmonRunGitCloudToken.
    .PARAMETER Operation
        The Git operation being performed.
    .PARAMETER SecretEnv
        Optional hashtable of pre-resolved secrets.
    .PARAMETER EnvVarName
        Explicit env var name override.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('read', 'write', 'push', 'clone', 'fetch')]
        [string]$Operation,

        [hashtable]$SecretEnv,

        [string]$EnvVarName
    )

    $tokenType = switch ($Operation) {
        'read'   { 'READ' }
        'clone'  { 'READ' }
        'fetch'  { 'READ' }
        'write'  { 'WRITE' }
        'push'   { 'PUSH' }
        default  { 'READ' }
    }

    return Get-SalmonRunGitCloudToken -TokenType $tokenType -SecretEnv $SecretEnv -EnvVarName $EnvVarName
}
