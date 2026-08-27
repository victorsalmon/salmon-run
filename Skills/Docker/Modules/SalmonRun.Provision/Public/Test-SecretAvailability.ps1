<#
.SYNOPSIS
Checks whether required AWS Secrets Manager secrets exist.
.PARAMETER ProjectCode
The project code used for secret naming.
.PARAMETER SsoProfile
The AWS SSO profile to use for API calls.
.PARAMETER SecretsRegion
The AWS region where secrets are stored.
#>
function Test-SecretAvailability {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ProjectCode,
        [string]$SsoProfile,
        [string]$SecretsRegion
    )
    Write-Verbose "  [PREFLIGHT] Checking secret availability..."

    $orchestratorResult = Invoke-AwsCommand {
        aws secretsmanager describe-secret --secret-id "Interclaw/FRAD/Orchestrator" --profile "$SsoProfile" --region "$SecretsRegion" --output json 2>&1
    }
    $orchestratorFound = $orchestratorResult.Success

    $provisioningResult = Invoke-AwsCommand {
        aws secretsmanager describe-secret --secret-id "Interclaw/FRAD/Provisioning" --profile "$SsoProfile" --region "$SecretsRegion" --output json 2>&1
    }
    $provisioningFound = $provisioningResult.Success

    $missing = @()
    if (-not $orchestratorFound) {
        $missing += "Interclaw/FRAD/Orchestrator"
        Write-SetupLog "Secret not found: Interclaw/FRAD/Orchestrator" -Level WARN
    }
    if (-not $provisioningFound) {
        $missing += "Interclaw/FRAD/Provisioning"
        Write-SetupLog "Secret not found: Interclaw/FRAD/Provisioning" -Level WARN
    }

    if ($missing.Count -gt 0) {
        Write-Warning "  [WARN] Missing secrets: $($missing -join ', ')"
    } else {
        Write-Verbose "  [OK] All required secrets available."
    }

    return [pscustomobject]@{
        ProjectSecretFound    = $orchestratorFound
        InstallationSecretFound = $provisioningFound
        MissingSecretNames    = $missing
    }
}
