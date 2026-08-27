<#
.SYNOPSIS
Checks whether coding keys (OPENCODE_GO1_KEY) are present in the project secret.
.PARAMETER ProjectCode
The project code used for secret naming.
.PARAMETER SsoProfile
The AWS SSO profile to use for API calls.
.PARAMETER SecretsRegion
The AWS region where secrets are stored.
#>
function Test-CodingKeyPresence {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ProjectCode,
        [string]$SsoProfile,
        [string]$SecretsRegion
    )
    Write-Verbose "  [PREFLIGHT] Checking coding key presence..."

    $key1 = Get-SecretFromAws -KeyName "OPENCODE_GO1_KEY" -SsoProfile $SsoProfile
    $hasKeys = -not [string]::IsNullOrWhiteSpace($key1)
    if (-not $hasKeys) {
        Write-Warning "  [WARN] No coding keys found  -  mcp_opencode containers will be disabled."
        Write-SetupLog "Coding key check: OPENCODE_GO1_KEY not found in project secret" -Level WARN
    } else {
        Write-Verbose "  [OK] Coding keys available."
    }
    return $hasKeys
}
