<#
.SYNOPSIS
    Cleans up orphaned IAM users for a given project.
.DESCRIPTION
    Lists IAM users matching <Project>-* and removes those not in the
    protected instances list. Preserves fleet and secondary instance users.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Invoke-OrphanIamCleanup {
    [OutputType([void])]
    param(
        $AgentContext,
        [string[]]$AdditionalProtectedInstanceIds
    )

    # ==============================================================================
    # PHASE 4a: IAM Cleanup  -  remove orphaned users for decommissioned containers
    # ==============================================================================
    # The provisioning agent handles IAM cleanup regardless of role.
    # Multiple agents can run cleanup idempotently.
    #
    # PROTECTION RULES:
    #   1. EXISTING_INSTANCE_ID contains all known legitimate instance IDs.
    #      Any IAM user matching an ID in this list is NEVER deleted.
    #   2. The current instance being provisioned is also protected.
    #   3. The fleet user (<Project>-FLEET) is NEVER deleted  -  it is reused
    #      across all deployments and only has its keys rotated in Phase 6.
    $ProjectCode = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $RoleCode = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }
    $CurrentInstanceId = if ($AgentContext) { $AgentContext.InstanceId } else { $env:INTERCLAW_INSTANCE_ID }

        Write-Warning "`n[AWS] Checking for orphaned IAM users (project: $ProjectCode)..."

        $EscapedProject = [regex]::Escape($ProjectCode)

        # Build protection set from Docker Swarm active services + current instance
        $ProtectedInstanceIds = @{}
        $svcResult = Invoke-NativeCommand { docker service ls --filter "name=oc-" --format "{{.Name}}" 2>&1 }
        $svcOutput = $svcResult.Output
        if ($svcOutput) {
            $svcNames = @($svcOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            foreach ($svcName in $svcNames) {
                $inspectResult = Invoke-NativeCommand { docker service inspect $svcName 2>&1 }
                $inspectJson = $inspectResult.Output
                if ($inspectJson) {
                    try {
                        $inspectObj = $inspectJson | ConvertFrom-Json
                        $envs = $inspectObj[0].Spec.TaskTemplate.ContainerSpec.Env
                        foreach ($env in $envs) {
                            if ($env -match '^INTERCLAW_INSTANCE_ID=(\d+)$') {
                                $ProtectedInstanceIds[$Matches[1]] = $true
                                break
                            }
                        }
                    } catch { Write-SetupLog "ERROR: OrphanIamCleanup docker service inspect failed: $_" -Level WARN }
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($CurrentInstanceId)) {
            $ProtectedInstanceIds[$CurrentInstanceId] = $true
        }

        if ($AdditionalProtectedInstanceIds) {
            foreach ($id in $AdditionalProtectedInstanceIds) {
                $ProtectedInstanceIds[$id] = $true
            }
        }

        Write-SetupLog "Phase 4a: Protected instance IDs: $($ProtectedInstanceIds.Keys -join ', ')"

        $UsersResult = Invoke-AwsCommand { aws iam list-users --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
        if ($UsersResult.Success -and -not [string]::IsNullOrWhiteSpace($UsersResult.Output)) {
            $AllIamUsers = ($UsersResult.Output | ConvertFrom-Json).Users
            $ProjectIamUsers = @($AllIamUsers | Where-Object { $_.UserName -match "^${EscapedProject}-(FLEET|ORCH|VERI|BASE|REKOGNITIONFALLBACK)-?" })

            $CleanedCount = 0

            foreach ($IamUser in $ProjectIamUsers) {
                $UserName = $IamUser.UserName

                # RULE 3: Fleet user is never deleted by cleanup
                if ($UserName -match "^${EscapedProject}-FLEET$") {
                    Write-Verbose "  [KEEP] $UserName  -  fleet user is permanent (keys rotated in Phase 6)"
                    continue
                }

                # CODE and WORK roles are excluded  -  CODE has no IAM users, WORK is deprecated
                if ($UserName -match "^${EscapedProject}-(ORCH|VERI|BASE)-(\d+)$") {
                    $UserRole = $Matches[1]
                    $UserInstanceId = $Matches[2]

                    # RULE 1 & 2: Protected instances are never deleted
                    if ($ProtectedInstanceIds.ContainsKey($UserInstanceId)) {
                        Write-Verbose "  [KEEP] $UserName - instance $UserInstanceId is in protected list"
                        continue
                    }

                    Write-Warning "  [CLEANUP] Removing orphaned IAM user: $UserName ($UserRole instance $UserInstanceId)"
                    Write-SetupLog "Removing orphaned IAM user: $UserName (instance $UserInstanceId not in protected list)"

                    $KeysResult = Invoke-AwsCommand { aws iam list-access-keys --user-name "$UserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
                    if ($KeysResult.Success -and -not [string]::IsNullOrWhiteSpace($KeysResult.Output)) {
                        $UserAccessKeys = @(($KeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
                        foreach ($AccessKey in $UserAccessKeys) {
                            if ($AccessKey.Status -eq "Active") {
                                Write-Verbose "    Disabling access key: $($AccessKey.AccessKeyId)"
                                Invoke-AwsCommand { aws iam update-access-key --user-name "$UserName" --access-key-id $AccessKey.AccessKeyId --status Inactive --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null } | Out-Null
                            }
                            Write-Verbose "    Deleting access key: $($AccessKey.AccessKeyId)"
                            $DelKeyResult = Invoke-AwsCommand { aws iam delete-access-key --user-name "$UserName" --access-key-id $AccessKey.AccessKeyId --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
                            if ($DelKeyResult.Success) {
                                Write-Verbose "    [OK] Deleted key: $($AccessKey.AccessKeyId)"
                            }
                            else {
                                Write-Warning "    [WARN] Failed to delete key: $($AccessKey.AccessKeyId)"
                                Write-SetupLog "Failed to delete access key $($AccessKey.AccessKeyId) for $UserName" -Level WARN
                            }
                        }
                    }

                    $PoliciesResult = Invoke-AwsCommand { aws iam list-user-policies --user-name "$UserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
                    if ($PoliciesResult.Success -and -not [string]::IsNullOrWhiteSpace($PoliciesResult.Output)) {
                        $UserPolicyNames = @(($PoliciesResult.Output | ConvertFrom-Json).PolicyNames)
                        foreach ($PolicyName in $UserPolicyNames) {
                            Write-Verbose "    Deleting inline policy: $PolicyName"
                            $DelPolResult = Invoke-AwsCommand { aws iam delete-user-policy --user-name "$UserName" --policy-name "$PolicyName" --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
                            if ($DelPolResult.Success) {
                                Write-Verbose "    [OK] Deleted policy: $PolicyName"
                            }
                            else {
                                Write-Warning "    [WARN] Failed to delete policy: $PolicyName"
                                Write-SetupLog "Failed to delete policy $PolicyName for $UserName" -Level WARN
                            }
                        }
                    }

                    $DelUserResult = Invoke-AwsCommand { aws iam delete-user --user-name "$UserName" --profile "$env:AWS_SSO_PROFILE" 2>$null | Out-Null }
                    if ($DelUserResult.Success) {
                        Write-Verbose "  [OK] Deleted IAM user: $UserName"
                        Write-SetupLog "Deleted orphaned IAM user: $UserName"
                        $CleanedCount++
                    }
                    else {
                        Write-Warning "  [WARN] Failed to delete IAM user: $UserName"
                        Write-SetupLog "Failed to delete orphaned IAM user: $UserName" -Level WARN
                    }
                }
            }

            if ($CleanedCount -gt 0) {
                Write-Verbose "  [OK] Cleaned up $CleanedCount orphaned IAM user(s)."
            }
            else {
                Write-Verbose "  [OK] No orphaned IAM users found."
            }
        }
        else {
            Write-Warning "  [WARN] Could not list IAM users for cleanup."
            Write-SetupLog "Phase 4a: Could not list IAM users (aws iam list-users failed)" -Level WARN
        }

        # Fleet user is NEVER deleted  -  it is permanent and only has keys rotated in Phase 6
        $FleetUserName = "${ProjectCode}-FLEET"
        $FleetUserResult = Invoke-AwsCommand { aws iam get-user --user-name "$FleetUserName" --profile "$env:AWS_SSO_PROFILE" --output json 2>$null }
        if ($FleetUserResult.Success) {
            Write-Verbose "  [KEEP] Fleet IAM user $FleetUserName is permanent (never deleted by cleanup)."
        }
        else {
            Write-Verbose "  [INFO] Fleet IAM user $FleetUserName does not exist yet  -  will be created in Phase 6."
        }

        Write-SetupLog "Phase 4a complete: orphaned IAM users cleaned up"
}
