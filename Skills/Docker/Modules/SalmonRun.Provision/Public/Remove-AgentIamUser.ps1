<#
.SYNOPSIS
Deletes an IAM user and all associated access keys and inline policies.

.DESCRIPTION
Removes an IAM user by first deactivating and deleting all access keys,
then removing all inline policies, and finally deleting the user. Each step
logs success or failure independently. The final user deletion is a soft-fail
to allow partial cleanup.

.PARAMETER ProjectCode
The project code used in the IAM user name prefix (<ProjectCode>-<Role>-<InstanceId>).

.PARAMETER Role
The agent role code used in the IAM user name.

.PARAMETER InstanceId
The instance ID used in the IAM user name.
#>
function Remove-AgentIamUser {
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectCode,
        [Parameter(Mandatory = $true)]
        [string]$Role,
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $IamUserName = "${ProjectCode}-${Role}-${InstanceId}"

    # Check if the IAM user exists
    $UserResult = Invoke-AwsCommand { aws iam get-user --user-name "$IamUserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
    if (-not $UserResult.Success) {
        Write-SetupLog "IAM user $IamUserName not found  -  nothing to clean up"
        return
    }

    Write-Warning "  [CLEANUP] Found IAM user for removed container: $IamUserName"
    Write-SetupLog "Cleaning up IAM user $IamUserName for removed container"

    # Delete access keys
    $KeysResult = Invoke-AwsCommand { aws iam list-access-keys --user-name "$IamUserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
    if ($KeysResult.Success -and -not [string]::IsNullOrWhiteSpace($KeysResult.Output)) {
        $AccessKeys = @(($KeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
        foreach ($Key in $AccessKeys) {
            if ($Key.Status -eq "Active") {
                Invoke-AwsCommand { aws iam update-access-key --user-name "$IamUserName" --access-key-id $Key.AccessKeyId --status Inactive --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null } | Out-Null
            }
            $DelKeyResult = Invoke-AwsCommand { aws iam delete-access-key --user-name "$IamUserName" --access-key-id $Key.AccessKeyId --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
            if ($DelKeyResult.Success) {
                Write-Verbose "    [OK] Deleted access key: $($Key.AccessKeyId)"
                Write-SetupLog "Deleted access key $($Key.AccessKeyId) for $IamUserName"
            }
            else {
                Write-Warning "    [WARN] Failed to delete access key: $($Key.AccessKeyId)"
                Write-SetupLog "Failed to delete access key $($Key.AccessKeyId) for $IamUserName" -Level WARN
            }
        }
    }

    # Delete inline policies
    $PoliciesResult = Invoke-AwsCommand { aws iam list-user-policies --user-name "$IamUserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
    if ($PoliciesResult.Success -and -not [string]::IsNullOrWhiteSpace($PoliciesResult.Output)) {
        $PolicyNames = @(($PoliciesResult.Output | ConvertFrom-Json).PolicyNames)
        foreach ($PolicyName in $PolicyNames) {
            $DelPolResult = Invoke-AwsCommand { aws iam delete-user-policy --user-name "$IamUserName" --policy-name "$PolicyName" --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
            if ($DelPolResult.Success) {
                Write-Verbose "    [OK] Deleted inline policy: $PolicyName"
                Write-SetupLog "Deleted inline policy $PolicyName for $IamUserName"
            }
            else {
                Write-Warning "    [WARN] Failed to delete inline policy: $PolicyName"
                Write-SetupLog "Failed to delete inline policy $PolicyName for $IamUserName" -Level WARN
            }
        }
    }

    # Delete the user (soft-fail)
    $DelUserResult = Invoke-AwsCommand { aws iam delete-user --user-name "$IamUserName" --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
    if ($DelUserResult.Success) {
        Write-Verbose "  [OK] Deleted IAM user: $IamUserName"
        Write-SetupLog "Deleted IAM user: $IamUserName"
    }
    else {
        Write-Warning "  [WARN] Could not delete IAM user: $IamUserName  -  manual cleanup may be required"
        Write-SetupLog "Failed to delete IAM user $IamUserName" -Level WARN
    }
}
