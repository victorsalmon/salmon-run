function Select-GitHubToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('read', 'write', 'push', 'fleet_read')]
        [string]$Operation,

        [hashtable]$SecretEnv,

        [string]$SsoProfile
    )

    $tokenType = if ($Operation -eq 'read') { 'CodingRead' }
                 elseif ($Operation -eq 'write' -or $Operation -eq 'push') { 'CodingWrite' }
                 elseif ($Operation -eq 'fleet_read') { 'FleetRead' }

    return Get-GitHubToken -TokenType $tokenType -SecretEnv $SecretEnv -SsoProfile $SsoProfile
}
