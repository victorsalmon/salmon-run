<#
.SYNOPSIS
Verifies that required IAM permissions are available for provisioning.
.PARAMETER SsoProfile
The AWS SSO profile to use for API calls.
.PARAMETER SecretsRegion
The AWS region where secrets are stored.
.PARAMETER ProjectCode
The project code used for IAM user naming.
#>
function Test-AwsIamPermissions {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$SsoProfile,
        [string]$SecretsRegion,
        [string]$ProjectCode
    )
    Write-Verbose "  [PREFLIGHT] Checking IAM permissions..."

    $iamListResult = Invoke-AwsCommand {
        aws iam list-users --max-items 1 --profile "$SsoProfile" --output json 2>&1
    }
    if (-not $iamListResult.Success) {
        throw "Missing iam:ListUsers permission: $($iamListResult.Output)"
    }
    Write-Verbose "  [OK] iam:ListUsers"

    $checkUserName = "${ProjectCode}-Preflight-Check"
    $iamCreateResult = Invoke-AwsCommand {
        aws iam create-user --user-name $checkUserName --profile "$SsoProfile" --output json 2>&1
    }
    if ($iamCreateResult.Success) {
        aws iam delete-user --user-name $checkUserName --profile "$SsoProfile" 2>&1 | Out-Null
        Write-Verbose "  [OK] iam:CreateUser ($checkUserName)"
    } else {
        throw "Missing iam:CreateUser permission  -  cannot create per-agent IAM users: $($iamCreateResult.Output)"
    }

    $smResult = Invoke-AwsCommand {
        aws secretsmanager describe-secret --secret-id "Interclaw/FRAD/Orchestrator" --profile "$SsoProfile" --region "$SecretsRegion" --output json 2>&1
    }
    if (-not $smResult.Success) {
        throw "Missing secretsmanager:DescribeSecret for Interclaw/FRAD/Orchestrator: $($smResult.Output)"
    }
    Write-Verbose "  [OK] secretsmanager:DescribeSecret (Interclaw/FRAD/Orchestrator)"

    $brResult = Invoke-AwsCommand {
        aws bedrock list-inference-profiles --region "$SecretsRegion" --profile "$SsoProfile" --max-items 1 --output json 2>&1
    }
    if (-not $brResult.Success) {
        Write-Warning "  [WARN] bedrock:ListInferenceProfiles ($SecretsRegion)  -  setup will continue but provisioning may fail if Bedrock is unavailable"
        Write-SetupLog "Missing bedrock:ListInferenceProfiles in ${SecretsRegion}: $($brResult.Output)" -Level WARN
    } else {
        Write-Verbose "  [OK] bedrock:ListInferenceProfiles ($SecretsRegion)"
    }

    Write-Verbose "  [OK] All IAM permissions verified."
}
