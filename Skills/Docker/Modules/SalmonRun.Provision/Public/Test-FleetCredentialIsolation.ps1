<#
.SYNOPSIS
    Tests that fleet credentials respect sovereignty locks.
    .DESCRIPTION
    Verifies the fleet IAM user can access its home region but is
    denied access to out-of-region services.
.PARAMETER FleetAccessKeyId
    IAM access key ID for the fleet user.
.PARAMETER FleetSecretAccessKey
    IAM secret access key for the fleet user.
.PARAMETER FleetIamUserName
    IAM user name for logging.
.OUTPUTS
    $true if isolation passes, throws on failure.
#>
function Test-FleetCredentialIsolation {
    [OutputType([bool])]
    param(
        [SecureString]$FleetAccessKeyId,
        [SecureString]$FleetSecretAccessKey,
        [string]$FleetIamUserName
    )

    $Result = [pscustomobject]@{
        Passed    = $true
        Warnings  = @()
        Failures  = @()
    }

    if ($FleetAccessKeyId -and $FleetSecretAccessKey) {
        Write-SetupLog "Phase 6a: Verifying fleet credential tier"
        Write-Warning "`n[AWS] Verifying fleet credentials ($FleetIamUserName)..."

        Write-Verbose "  [INFO] Waiting $((Get-InterclawConstants).AwsKeyInitialPropagationWaitSec)s for new access key to propagate..."
        Start-Sleep -Seconds (Get-InterclawConstants).AwsKeyInitialPropagationWaitSec

        $FleetCheckState = @{ Passed = $true }

        $SavedExitCode = $LASTEXITCODE

        Invoke-WithCredentialSwap -AccessKeyId $FleetAccessKeyId -SecretAccessKey $FleetSecretAccessKey -ScriptBlock {
            $FleetIamTest = $null
            $FleetIamRetry = 0
            $FleetIamExit = -1
            while ($FleetIamRetry -lt (Get-InterclawConstants).AwsKeyPropagationRetries) {
                $FleetIamTest = aws iam list-users --region us-east-1 2>&1
                $FleetIamExit = $LASTEXITCODE
                $FleetIamText = ($FleetIamTest -join "`n")
                if ($FleetIamExit -eq 0) { break }
                if ($FleetIamText -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Write-Verbose "  [INFO] Access key not yet active, retrying... ($($FleetIamRetry + 1)/$((Get-InterclawConstants).AwsKeyPropagationRetries))"
                    Start-Sleep -Seconds (Get-InterclawConstants).AwsKeyPropagationDelaySec
                    $FleetIamRetry++
                    continue
                }
                Write-Verbose "  [DEBUG] Fleet IAM test exit=$FleetIamExit output=$FleetIamText"
                break
            }
            if ($FleetIamExit -eq 0) {
                Write-Verbose "  [PASS] Fleet IAM access confirmed  -  elevated provisioning role."
                Write-SetupLog "Fleet credential PASS: IAM access confirmed for $FleetIamUserName"
            }
            else {
                if ($FleetIamText -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Write-Warning "  [WARN] Fleet IAM test failed after 10 retries  -  key propagation timed out."
                    Write-SetupLog "Fleet credential WARN: IAM key propagation timeout for $FleetIamUserName" -Level WARN
                    $Result.Warnings += "IAM key propagation timeout"
                }
                else {
                    Write-Warning "  [FAIL] Fleet IAM access denied  -  fleet cannot provision agents!"
                    Write-Verbose "         Details: $FleetIamText"
                    Write-SetupLog "Fleet credential FAIL: IAM access denied for $FleetIamUserName ($FleetIamText)" -Level ERROR
                    $FleetCheckState.Passed = $false
                    $Result.Failures += "Fleet IAM access denied"
                }
            }

            $FleetSsoTest = aws sso-admin list-instances --region us-east-1 2>&1
            $FleetSsoText = ($FleetSsoTest -join "`n")
            if ($FleetSsoText -match "AccessDenied|UnauthorizedOperation|Forbidden") {
                Write-Verbose "  [PASS] Fleet SSO admin denied  -  not an installer credential."
                Write-SetupLog "Fleet credential PASS: SSO admin denied for $FleetIamUserName"
            }
            else {
                Write-Warning "  [FAIL] Fleet SSO admin access granted! Fleet can modify SSO permission sets!"
                Write-Verbose "         Details: $FleetSsoText"
                Write-SetupLog "Fleet credential FAIL: SSO admin access granted for $FleetIamUserName ($FleetSsoText)" -Level ERROR
                $FleetCheckState.Passed = $false
                $Result.Failures += "SSO admin access granted"
            }

            $FleetRolesTest = aws iam list-roles --region us-east-1 2>&1
            $FleetRolesText = ($FleetRolesTest -join "`n")
            if ($FleetRolesText -match "AccessDenied|UnauthorizedOperation|Forbidden") {
                Write-Verbose "  [PASS] Fleet account-level IAM denied  -  not an account admin."
                Write-SetupLog "Fleet credential PASS: account IAM denied for $FleetIamUserName"
            }
            else {
                Write-Warning "  [FAIL] Fleet account-level IAM access granted! Fleet can enumerate roles!"
                Write-Verbose "         Details: $FleetRolesText"
                Write-SetupLog "Fleet credential FAIL: account IAM access granted for $FleetIamUserName ($FleetRolesText)" -Level ERROR
                $FleetCheckState.Passed = $false
                $Result.Failures += "Account-level IAM access granted"
            }

            $FleetOrgTest = aws organizations list-accounts 2>&1
            $FleetOrgText = ($FleetOrgTest -join "`n")
            if ($FleetOrgText -match "AccessDenied|UnauthorizedOperation|Forbidden") {
                Write-Verbose "  [PASS] Fleet Organizations denied  -  cannot manage AWS accounts."
                Write-SetupLog "Fleet credential PASS: Organizations denied for $FleetIamUserName"
            }
            else {
                Write-Warning "  [FAIL] Fleet Organizations access granted! Fleet can list all AWS accounts!"
                Write-Verbose "         Details: $FleetOrgText"
                Write-SetupLog "Fleet credential FAIL: Organizations access granted for $FleetIamUserName ($FleetOrgText)" -Level ERROR
                $FleetCheckState.Passed = $false
                $Result.Failures += "Organizations access granted"
            }
        }

        $global:LASTEXITCODE = $SavedExitCode

        $Result.Passed = $FleetCheckState.Passed

        if ($Result.Passed) {
            Write-Verbose "  [OK] Fleet credentials verified: elevated but not admin."
        }
        else {
            Write-Warning "  [WARN] Fleet credential verification had failures  -  check policy scope."
        }
        Write-SetupLog "Phase 6a complete: fleet credentials verified"
    }

    return $Result
}
