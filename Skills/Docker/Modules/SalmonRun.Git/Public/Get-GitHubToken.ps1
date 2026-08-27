function Get-GitHubToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('FleetRead', 'CodingRead', 'CodingWrite')]
        [string]$TokenType,

        [hashtable]$SecretEnv,

        [string]$SsoProfile
    )

    $envVar = if ($TokenType -eq 'FleetRead') { 'FLEET_GITHUB_TOKEN_READALL' }
              elseif ($TokenType -eq 'CodingRead') { 'GITHUB_TOKEN_READALL' }
              elseif ($TokenType -eq 'CodingWrite') { 'GITHUB_TOKEN_PUSHSELECT' }

    $value = if ($SecretEnv -and $SecretEnv.ContainsKey($envVar)) { $SecretEnv[$envVar] }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [System.Environment]::GetEnvironmentVariable($envVar)
    }
    if ([string]::IsNullOrWhiteSpace($value) -and $SsoProfile) {
        try {
            $value = Get-SecretFromAws -KeyName $envVar -SsoProfile $SsoProfile -ErrorAction Stop
        } catch {
            Write-SetupLog "WARNING: Failed to fetch $envVar from AWS SM: $($_.Exception.Message)" -Level WARN
        }
    }

    return $value
}
