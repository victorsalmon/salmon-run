<#
.SYNOPSIS
Verifies that the current AWS SSO session is still valid.
#>
function Test-AwsSessionValidity {
    [OutputType([void])]
    param(
        [string]$SsoProfile
    )
    Write-Verbose "  [PREFLIGHT] Checking AWS session validity..."
    $result = Invoke-AwsCommand {
        aws sts get-caller-identity --profile "$SsoProfile" --output json 2>&1
    }
    if (-not $result.Success) {
        throw "AWS SSO session expired or invalid. Re-run 0config.ps1 to refresh: $($result.Output)"
    }
    Write-Verbose "  [OK] AWS session valid."
}
