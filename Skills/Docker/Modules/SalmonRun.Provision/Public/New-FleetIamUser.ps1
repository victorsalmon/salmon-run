<#
.SYNOPSIS
    Creates an IAM user for the fleet sidecar.
.DESCRIPTION
    Creates <Project>-FLEET IAM user with restricted permissions
    for docker service management. Returns the credentials.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    Hashtable with AccessKeyId and SecretAccessKey.
#>
function New-FleetIamUser {
    [OutputType([hashtable])]
    param(
        $AgentContext
    )

    $ProjectCode = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $RoleCode = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }
    $SovereigntyTier = if ($AgentContext) { $AgentContext.SovereigntyTier } elseif ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "canada" }
    $FleetIamUserName = "${ProjectCode}-FLEET"

    # ==============================================================================
    # PHASE 6: Fleet IAM User (elevated credentials for rebuild capability)
    # ==============================================================================
    # The provisioning agent creates the fleet IAM user regardless of role.
        $FleetExistingUser = Invoke-AwsCommand { aws iam get-user --user-name $FleetIamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
        if ($FleetExistingUser.Success) {
            Write-Verbose "  [OK] Fleet IAM user already exists: $FleetIamUserName"
            Write-SetupLog "Fleet IAM user already exists: $FleetIamUserName"
        }
        else {
            $CreateFleetResult = Invoke-AwsCommand { aws iam create-user --user-name $FleetIamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
            if (-not $CreateFleetResult.Success) {
                Write-Warning "  [WARN] Could not create fleet IAM user $FleetIamUserName."
                Write-SetupLog "Fleet IAM user creation failed for $FleetIamUserName" -Level WARN
                $FleetIamUserName = $null
            }
            else {
                Write-Verbose "  [OK] Created fleet IAM user: $FleetIamUserName"
                Write-SetupLog "Created fleet IAM user: $FleetIamUserName"
            }
        }

        # Always update the policy to the latest version (idempotent)
        if ($FleetIamUserName) {
            $FleetPolicyMap = @{
                "canada" = "fleet-canada.json"
                "usa"    = "fleet-usa.json"
                "global" = "fleet-global.json"
            }
            $FleetPolicyFileName = $FleetPolicyMap[$SovereigntyTier]
            if (-not $FleetPolicyFileName) { $FleetPolicyFileName = "fleet-canada.json" }
            $FleetRepoRoot = Get-InterclawRepoRoot
            $FleetPolicyPath = Join-Path $FleetRepoRoot "Infrastructure" "Policies" $FleetPolicyFileName
            if (Test-Path $FleetPolicyPath) {
                $FleetPolicyDoc = Get-Content $FleetPolicyPath -Raw
                $tmpPolicyFile = Join-Path $env:TEMP "oc-policy-$([System.IO.Path]::GetRandomFileName()).json"
                try {
                    Set-Content -Path $tmpPolicyFile -Value $FleetPolicyDoc -Encoding UTF8 -NoNewline
                    $PutFleetPolicyResult = $null
                    for ($ppAttempt = 1; $ppAttempt -le 3; $ppAttempt++) {
                        $PutFleetPolicyResult = Invoke-AwsCommand { aws iam put-user-policy --user-name $FleetIamUserName --policy-name "Fleet-MaintenancePolicy" --policy-document "file://$($tmpPolicyFile -replace '\\', '/')" --profile $env:AWS_SSO_PROFILE 2>&1 }
                        if ($PutFleetPolicyResult.Success) { break }
                        if ($ppAttempt -lt 3) {
                            Write-SetupLog "fleet put-user-policy attempt $ppAttempt/3 failed: $($PutFleetPolicyResult.Output)" -Level WARN
                            Start-Sleep -Seconds ($ppAttempt * 5)
                        }
                    }
                } finally {
                    if (Test-Path $tmpPolicyFile) { Remove-Item $tmpPolicyFile -Force -ErrorAction SilentlyContinue }
                }
                if ($PutFleetPolicyResult.Success) {
                    Write-Verbose "  [OK] Updated $FleetPolicyFileName policy on $FleetIamUserName"
                    Write-SetupLog "Updated $FleetPolicyFileName policy on $FleetIamUserName"
                }
                else {
                    Write-Warning "  [WARN] Could not update $FleetPolicyFileName policy on $FleetIamUserName"
                    Write-SetupLog "Fleet policy update failed for ${FleetIamUserName}: $($PutFleetPolicyResult.Output)" -Level WARN
                }
            }
            else {
                Write-SetupLog "Fleet policy file not found: $FleetPolicyPath" -Level ERROR
            }
        }

        $FleetKeysAlreadyPropagated = $false
        if ($FleetIamUserName) {
            $FleetKeysResult = Invoke-AwsCommand { aws iam list-access-keys --user-name $FleetIamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
            $FleetExistingKeys = @()
            if ($FleetKeysResult.Success -and -not [string]::IsNullOrWhiteSpace($FleetKeysResult.Output)) {
                $FleetExistingKeys = @($($FleetKeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
                $YoungestKey = $FleetExistingKeys | Sort-Object CreateDate -Descending | Select-Object -First 1
                $keyDate = $YoungestKey.CreateDate
                if ($YoungestKey -and $keyDate) {
                    $KeyAge = ([DateTime]::UtcNow - ([DateTime]$keyDate)).TotalSeconds
                    if ($KeyAge -gt 60) {
                        $FleetKeysAlreadyPropagated = $true
                        Write-SetupLog "Existing fleet keys are ${KeyAge}s old  -  will skip isolation tests"
                    }
                }
            }
            $Rotate = $env:ROTATE_PREEXISTING_KEYS -eq "true"
            Write-Verbose "Fleet key rotation: $Rotate (existing keys: $($FleetExistingKeys.Count))"
            if ($FleetExistingKeys.Count -gt 0 -and -not $Rotate) {
                $YoungestKey = $FleetExistingKeys | Sort-Object CreateDate -Descending | Select-Object -First 1
                $FleetAccessKeyId = $YoungestKey.AccessKeyId
                Write-Verbose "  [SKIP] Reusing existing fleet access key: $FleetAccessKeyId (set ROTATE_PREEXISTING_KEYS=true to rotate)"
                Write-SetupLog "Reusing existing fleet key for $FleetIamUserName (ROTATE_PREEXISTING_KEYS=$env:ROTATE_PREEXISTING_KEYS)"
                $FleetBundleName = (Get-BundleManifest).Fleet.BundleName
                $BundleData = Read-ContainerSecretBundle -BundleName $FleetBundleName -ErrorAction SilentlyContinue
                if ($BundleData -and $BundleData.fleet_aws_secret -and $BundleData.fleet_aws_id -eq $FleetAccessKeyId) {
                    $FleetSecretAccessKey = $BundleData.fleet_aws_secret
                    Write-Verbose "  [OK] Retrieved fleet_aws_secret from Swarm bundle"
                    Write-SetupLog "Retrieved existing fleet secret from Swarm bundle"
                }
                else {
                    Write-Verbose "  [INFO] Swarm bundle missing or mismatched  -  rotating fleet keys instead"
                    Write-SetupLog "Swarm bundle read failed for $FleetIamUserName  -  rotating" -Level INFO
                    $Rotate = $true
                }
            }
            if ($Rotate -or $FleetExistingKeys.Count -eq 0) {
                foreach ($OldFleetKey in $FleetExistingKeys) {
                    Write-Verbose "  [INFO] Deleting old fleet access key: $($OldFleetKey.AccessKeyId)"
                    $null = Invoke-AwsCommand { aws iam delete-access-key --user-name $FleetIamUserName --access-key-id $OldFleetKey.AccessKeyId --profile $env:AWS_SSO_PROFILE 2>$null }
                }
                $FleetNewKeyResult = Invoke-AwsCommand { aws iam create-access-key --user-name $FleetIamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
                if ($FleetNewKeyResult.Success -and -not [string]::IsNullOrWhiteSpace($FleetNewKeyResult.Output)) {
                    $FleetNewKey = $FleetNewKeyResult.Output | ConvertFrom-Json
                    $FleetAccessKeyId = $FleetNewKey.AccessKey.AccessKeyId
                    $FleetSecretAccessKey = $FleetNewKey.AccessKey.SecretAccessKey
                    Write-Verbose "  [OK] Created fleet access key: $FleetAccessKeyId"
                    Write-SetupLog "Created fleet access key: $FleetAccessKeyId"
                }
                else {
                    Write-Warning "  [WARN] Could not create fleet access key"
                    Write-SetupLog "Fleet access key creation failed" -Level WARN
                }
            }
        }

        $FleetBundleName = (Get-BundleManifest).Fleet.BundleName
        $FleetBundleEntries = @{}

        if ($FleetAccessKeyId -and $FleetSecretAccessKey) {
            $FleetBundleEntries["fleet_aws_id"] = $FleetAccessKeyId
            $FleetBundleEntries["fleet_aws_secret"] = $FleetSecretAccessKey
        }
        else {
            Write-Warning "  [WARN] Fleet AWS credentials not created  -  on-demand rebuild will be unavailable."
            Write-Verbose "  The fleet container can still run health checks and daily updates."
            Write-SetupLog "Fleet AWS credentials not created  -  rebuild capability unavailable" -Level WARN
        }

        # Inject FLEET_GITHUB_TOKEN_READALL into the bundle (per ADR-0043)
        $fleetGitToken = [System.Environment]::GetEnvironmentVariable("FLEET_GITHUB_TOKEN_READALL")
        if ([string]::IsNullOrWhiteSpace($fleetGitToken) -and $env:AWS_SSO_PROFILE) {
            $fleetGitToken = Get-SecretFromAws -KeyName "FLEET_GITHUB_TOKEN_READALL" -SsoProfile $env:AWS_SSO_PROFILE -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($fleetGitToken)) {
            $FleetBundleEntries["FLEET_GITHUB_TOKEN_READALL"] = $fleetGitToken
        }

        Set-ContainerSecretBundle -BundleName $FleetBundleName -Entries $FleetBundleEntries -Label "fleet_secrets_bundle"
        Write-Verbose "  [OK] Fleet bundle created: $FleetBundleName ($($FleetBundleEntries.Count) entries)"
        if ($FleetBundleEntries.Count -gt 0) {
            Write-SetupLog "Fleet bundle created: $FleetBundleName ($($FleetBundleEntries.Count) entries)"
        } else {
            Write-SetupLog "Fleet bundle created empty  -  IAM credentials were unavailable" -Level WARN
        }

        Write-SetupLog "Phase 6 complete: fleet IAM user provisioned"

        return @{
            AccessKeyId = $FleetAccessKeyId
            SecretAccessKey = $FleetSecretAccessKey
            IamUserName = $FleetIamUserName
            KeysAlreadyPropagated = $FleetKeysAlreadyPropagated
        }
}






