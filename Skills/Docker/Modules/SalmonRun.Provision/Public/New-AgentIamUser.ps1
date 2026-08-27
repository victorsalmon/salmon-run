<#
.SYNOPSIS
    Creates an IAM user for an agent instance with Bedrock access policy.
.DESCRIPTION
    Creates <Project>-<Role>-<Instance> IAM user with access keys and
    an attached Bedrock/CW policy. Returns the credentials.
.PARAMETER Index
    Instance index for multi-instance role naming.
.OUTPUTS
    Hashtable with AccessKeyId and SecretAccessKey.
#>
function New-AgentIamUser {
    [OutputType([hashtable])]
    param(
        [int]$Index = 0,
        $AgentContext
    )

    function Test-IamKeyPropagation {
        param(
            [string]$AccessKeyId,
            [string]$ProfileName
        )
        try {
            $Result = aws iam get-access-key-last-used --access-key-id $AccessKeyId --profile $ProfileName --no-cli-pager 2>&1
            if ($LASTEXITCODE -eq 0) {
                $Parsed = $Result | ConvertFrom-Json
                return $null -ne $Parsed.UserName
            }
            return $false
        } catch {
            return $false
        }
    }

    $ProjectCode = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $RoleCode = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }
    $InstanceID = if ($AgentContext) { $AgentContext.InstanceId } else { $env:INTERCLAW_INSTANCE_ID }
    if ($AgentContext -and -not $PSBoundParameters.ContainsKey('Index')) { $Index = $AgentContext.Index }
    $SecretPrefix = Get-AgentSecretPrefix -Project $ProjectCode -Role $RoleCode -Index $Index
    $SovereigntyTier = if ($AgentContext) { $AgentContext.SovereigntyTier } elseif ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "canada" }

    Write-SetupLog "Phase 4b: Creating per-agent IAM user"
    # 4b. Create a least-privilege IAM user for this agent
    # The setup phase runs with elevated SSO credentials; runtime agents get only their own narrow IAM key
    $IamUserName = "${ProjectCode}-${RoleCode}-${InstanceID}"
    Write-Warning "`n[AWS] Creating IAM user: $IamUserName"

    $UserCreatedNow = $false
    $ExistingUser = Invoke-AwsCommand { aws iam get-user --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
    if ($ExistingUser.Success) {
        Write-Verbose "  [OK] IAM user already exists: $IamUserName"
        Write-SetupLog "IAM user already exists: $IamUserName"
    }
    else {
        $createAttempt = 0
        $createMaxRetries = 3
        $createSuccess = $false
        while ($createAttempt -lt $createMaxRetries -and -not $createSuccess) {
            $createAttempt++
            $CreateUserResult = Invoke-AwsCommand { aws iam create-user --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json }
            if ($CreateUserResult.Success) {
                $createSuccess = $true
            } else {
                if ($createAttempt -lt $createMaxRetries) {
                    $delay = Get-BackoffDelay -Attempt $createAttempt -Schedule @(5, 15, 30)
                    Write-Verbose "  [RETRY] IAM user creation attempt $createAttempt failed, retrying in ${delay}s"
                    Start-Sleep -Seconds $delay
                }
            }
        }
        if (-not $createSuccess) {
            throw "Failed to create IAM user $IamUserName after $createMaxRetries attempts"
        }
        else {
            Write-Verbose "  [OK] Created IAM user: $IamUserName"
            Write-SetupLog "Created IAM user: $IamUserName"
            $UserCreatedNow = $true
        }
    }

    try {
        # Always update the policy to the latest version (idempotent)
        if ($IamUserName) {
            $RolePrefix = "agent-base"
            $SovPolicyMap = @{
                "canada" = "${RolePrefix}-canada.json"
                "usa"    = "${RolePrefix}-usa.json"
                "global" = "${RolePrefix}-global.json"
                default  = "${RolePrefix}-canada.json"
            }
            $PolicyFileName = $SovPolicyMap[$SovereigntyTier]
            if (-not $PolicyFileName) { $PolicyFileName = "${RolePrefix}-canada.json" }
            $RepoRoot = Get-InterclawRepoRoot
            $PolicyPath = Join-Path $RepoRoot "Infrastructure" "Policies" $PolicyFileName
            if (Test-Path $PolicyPath) {
                $PolicyDocument = Get-Content $PolicyPath -Raw
                $PutPolicyResult = $null
                $tmpPolicyFile = Join-Path $env:TEMP "oc-policy-$([System.IO.Path]::GetRandomFileName()).json"
                try {
                    Set-Content -Path $tmpPolicyFile -Value $PolicyDocument -Encoding UTF8 -NoNewline
                    $policyRetryDelays = @(5, 10, 15)
                    for ($ppAttempt = 1; $ppAttempt -le 3; $ppAttempt++) {
                        $PutPolicyResult = Invoke-AwsCommand { aws iam put-user-policy --user-name $IamUserName --policy-name "Agent-SovereignPolicy" --policy-document "file://$($tmpPolicyFile -replace '\\', '/')" --profile $env:AWS_SSO_PROFILE 2>&1 }
                        if ($PutPolicyResult.Success) { break }
                        if ($ppAttempt -lt 3) {
                            $delay = $policyRetryDelays[$ppAttempt - 1]
                            Write-SetupLog "put-user-policy attempt $ppAttempt/3 failed: $($PutPolicyResult.Output) - retrying in ${delay}s" -Level WARN
                            Start-Sleep -Seconds $delay
                        }
                    }
                } finally {
                    if (Test-Path $tmpPolicyFile) { Remove-Item $tmpPolicyFile -Force -ErrorAction SilentlyContinue }
                }
                if ($PutPolicyResult.Success) {
                    Write-Verbose "  [OK] Updated sovereignty policy ($PolicyFileName) on $IamUserName"
                    Write-SetupLog "Updated $PolicyFileName policy on $IamUserName"
                }
                else {
                    throw "Policy update failed for $IamUserName"
                }
            }
            else {
                Write-Warning "  [WARN] Sovereignty policy file not found: $PolicyPath"
                Write-SetupLog "Sovereignty policy file not found: $PolicyPath" -Level WARN
            }
        }

        # Create or rotate access key for the IAM user.
        # On re-deploy, detect whether the credential pipeline was already validated
        # (existing keys > 60s old) to skip redundant isolation tests.
        $AgentAccessKeyId = $null
        $AgentSecretAccessKey = $null
        $KeysAlreadyPropagated = $false

        if ($IamUserName) {
            $iamMutex = $null
            try {
                $iamMutexName = "Global\InterclawIamUserMutex_$($IamUserName -replace '[^a-zA-Z0-9_]', '_')"
                $iamMutex = New-Object System.Threading.Mutex($false, $iamMutexName)
                $mutexAcquired = $iamMutex.WaitOne(120000, $false)  # 120s timeout
                if (-not $mutexAcquired) {
                    throw "Failed to acquire IAM mutex for $IamUserName within 120s"
                }
            } catch {
                if ($iamMutex) { $iamMutex.Dispose() }
                throw "IAM mutex error for ${IamUserName}: $_"
            }

            try {
            $ExistingKeysResult = Invoke-AwsCommand { aws iam list-access-keys --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
            $ExistingKeyMetadata = @()
            if ($ExistingKeysResult.Success -and -not [string]::IsNullOrWhiteSpace($ExistingKeysResult.Output)) {
                $ExistingKeyMetadata = @($($ExistingKeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
            }

            if ($ExistingKeyMetadata.Count -gt 0) {
                $YoungestKey = $ExistingKeyMetadata | Sort-Object CreateDate -Descending | Select-Object -First 1
                $keyDate = $YoungestKey.CreateDate
                if ($keyDate) {
                    $KeyPropagated = Test-IamKeyPropagation -AccessKeyId $YoungestKey.AccessKeyId -ProfileName $env:AWS_SSO_PROFILE
                    if ($KeyPropagated) {
                        $KeysAlreadyPropagated = $true
                        Write-SetupLog "Existing keys for $IamUserName are propagated (API confirmed)  -  will skip isolation tests"
                    } else {
                        Write-SetupLog "Existing keys for $IamUserName not yet propagated  -  will run isolation tests after rotation"
                    }
                } else {
                    Write-SetupLog "Existing keys for $IamUserName have no CreateDate  -  assuming new"
                }
            }

            $Rotate = $env:ROTATE_PREEXISTING_KEYS -eq "true"
            if ($ExistingKeyMetadata.Count -gt 0 -and -not $Rotate) {
                $YoungestKey = $ExistingKeyMetadata | Sort-Object CreateDate -Descending | Select-Object -First 1
                $AgentAccessKeyId = $YoungestKey.AccessKeyId
                Write-Verbose "  [SKIP] Reusing existing access key: $AgentAccessKeyId (set ROTATE_PREEXISTING_KEYS=true to rotate)"
                Write-SetupLog "Reusing existing access key for $IamUserName (ROTATE_PREEXISTING_KEYS=$env:ROTATE_PREEXISTING_KEYS)"
                # Read the existing secret from Docker Swarm bundle (IAM API never returns
                # SecretAccessKey after creation  -  only create-access-key returns it once).
                $BundleName = "${SecretPrefix}_$((Get-BundleManifest).Agent.Suffix)"
                $SvcName = "$($ProjectCode)_oc-$($RoleCode.ToLower())"
                $BundleData = Read-ContainerSecretBundle -BundleName $BundleName -ServiceName $SvcName
                if ($BundleData) {
                    if ($BundleData.aws_secret -and $BundleData.aws_id -eq $AgentAccessKeyId) {
                        $AgentSecretAccessKey = $BundleData.aws_secret
                        Write-Verbose "  [OK] Retrieved aws_secret from Swarm bundle: $BundleName"
                        Write-SetupLog "Retrieved existing secret for $IamUserName from Swarm bundle"
                    } else {
                        Write-SetupLog "Swarm bundle for $IamUserName has mismatched or missing aws_id  -  will rotate keys" -Level INFO
                    }
                } else {
                    Write-Verbose "  [INFO] Could not read existing Swarm bundle  -  will rotate keys"
                    Write-SetupLog "Swarm bundle read failed for $IamUserName  -  will rotate keys" -Level INFO
                }
                if (-not $AgentSecretAccessKey) {
                    Write-Verbose "  [INFO] No existing Swarm bundle with matching key  -  rotating IAM keys"
                    Write-SetupLog "No Swarm bundle with matching key for $IamUserName  -  rotating" -Level INFO
                    $Rotate = $true
                }
            }

            if ($Rotate -or $ExistingKeyMetadata.Count -eq 0) {
                foreach ($OldKey in $ExistingKeyMetadata) {
                    Write-Verbose "  [INFO] Deleting old access key: $($OldKey.AccessKeyId)"
                    $null = Invoke-AwsCommand { aws iam delete-access-key --user-name $IamUserName --access-key-id $OldKey.AccessKeyId --profile $env:AWS_SSO_PROFILE }
                }

                $accessKeyRetryDelays = @(5, 10, 15, 20, 25)
                $NewKeyResult = $null
                for ($akAttempt = 0; $akAttempt -le 5; $akAttempt++) {
                    $NewKeyResult = Invoke-AwsCommand { aws iam create-access-key --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
                    if ($NewKeyResult.Success -and -not [string]::IsNullOrWhiteSpace($NewKeyResult.Output)) {
                        break
                    }
                    if ($akAttempt -lt 5) {
                        $delay = $accessKeyRetryDelays[$akAttempt]
                        Write-Verbose "  [RETRY] create-access-key attempt $($akAttempt + 1) failed, retrying in ${delay}s (IAM eventual consistency)"
                        Start-Sleep -Seconds $delay
                    }
                }
                if ($NewKeyResult.Success -and -not [string]::IsNullOrWhiteSpace($NewKeyResult.Output)) {
                    $NewKey = $NewKeyResult.Output | ConvertFrom-Json
                    $AgentAccessKeyId = $NewKey.AccessKey.AccessKeyId
                    $AgentSecretAccessKey = $NewKey.AccessKey.SecretAccessKey
                    Write-Verbose "  [OK] Created access key for $IamUserName : $AgentAccessKeyId"
                    Write-SetupLog "Created access key for $IamUserName : $AgentAccessKeyId"
                }
                else {
                    throw "Access key creation failed for $IamUserName after 5 retries with IAM eventual consistency backoff"
                }
            }
            } finally {
                if ($iamMutex) { $iamMutex.Dispose() }
            }
        }

        Write-SetupLog "Phase 5: Injecting agent bundle secret"
        $BundleName = "${SecretPrefix}_$((Get-BundleManifest).Agent.Suffix)"
        $BundleEntries = @{}

        if ($AgentAccessKeyId -and $AgentSecretAccessKey) {
            $BundleEntries["aws_id"] = $AgentAccessKeyId
            $BundleEntries["aws_secret"] = $AgentSecretAccessKey
        }
        else {
            throw "IAM user creation failed for $SecretPrefix — no access keys generated. Cannot proceed without least-privilege credentials."
        }

        if ([string]::IsNullOrWhiteSpace($env:INTERCLAW_GATEWAY_TOKEN)) {
            throw "INTERCLAW_GATEWAY_TOKEN is not set  -  cannot create agent bundle without gateway token. Ensure secret hydration completed successfully."
        }
        $BundleEntries["gateway_token"] = $env:INTERCLAW_GATEWAY_TOKEN

        if (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_BOT_TOKEN)) {
            $BundleEntries["TELEGRAM_BOT_TOKEN"] = $env:TELEGRAM_BOT_TOKEN
        }
        if (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_OWNER_USERNAME)) {
            $BundleEntries["telegram_owner_username"] = $env:TELEGRAM_OWNER_USERNAME
        }
        if (-not [string]::IsNullOrWhiteSpace($env:TELEGRAM_OWNER_USERID)) {
            $BundleEntries["telegram_owner_userid"] = $env:TELEGRAM_OWNER_USERID
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GCP_MAESTRO_ID)) {
            $BundleEntries["gcp_maestro_id"] = $env:GCP_MAESTRO_ID
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GCP_MAESTRO_CLIENTID)) {
            $BundleEntries["gcp_maestro_clientid"] = $env:GCP_MAESTRO_CLIENTID
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GCP_MAESTRO_SECRET)) {
            $BundleEntries["gcp_maestro_secret"] = $env:GCP_MAESTRO_SECRET
        }

        $BundleEntries["openrouter_api_key"] = if ($env:OPENROUTER_API_KEY) { $env:OPENROUTER_API_KEY } else { $env:OPENROUTER_CODE_KEY }

        Set-ContainerSecretBundle -BundleName $BundleName -Entries $BundleEntries -Label "${SecretPrefix}_secrets_bundle"
        if ($Rotate) {
            Write-Verbose "  [OK] Agent bundle updated with rotated keys: $BundleName ($($BundleEntries.Count) entries)"
            Write-SetupLog "Agent bundle updated with rotated keys: $BundleName ($($BundleEntries.Count) entries)"
        } else {
            Write-Verbose "  [OK] Agent bundle already current: $BundleName ($($BundleEntries.Count) entries)"
            Write-SetupLog "Agent bundle already current: $BundleName ($($BundleEntries.Count) entries)"
        }

        Write-SetupLog "Phase 5 complete: agent bundle injected"
    }
    catch {
        if ($UserCreatedNow) {
            Invoke-AgentIamRollback -UserName $IamUserName
        }
        throw "Failed to provision IAM user '$IamUserName': $_"
    }

    $ssId = if ($AgentAccessKeyId) { $ss = [SecureString]::new(); $AgentAccessKeyId.ToCharArray() | ForEach-Object { $ss.AppendChar($_) }; $ss } else { $null }
    $ssSecret = if ($AgentSecretAccessKey) { $ss = [SecureString]::new(); $AgentSecretAccessKey.ToCharArray() | ForEach-Object { $ss.AppendChar($_) }; $ss } else { $null }
    return @{
        AccessKeyId = $ssId
        SecretAccessKey = $ssSecret
        IamUserName = $IamUserName
        KeysAlreadyPropagated = $KeysAlreadyPropagated
    }
}

function Invoke-AgentIamRollback {
    param([string]$UserName)
    Write-SetupLog "Rolling back partially-provisioned IAM user: $UserName" -Level WARN

    $rbMutex = $null
    try {
        $rbMutexName = "Global\InterclawIamUserMutex_$($UserName -replace '[^a-zA-Z0-9_]', '_')"
        $rbMutex = New-Object System.Threading.Mutex($false, $rbMutexName)
        $rbAcquired = $rbMutex.WaitOne(120000, $false)
        if (-not $rbAcquired) {
            Write-SetupLog "Could not acquire IAM mutex for rollback of $UserName within 120s — proceeding anyway" -Level WARN
        }
    } catch {
        Write-SetupLog "IAM mutex acquisition failed for rollback of ${UserName}: $_" -Level WARN
    }

    try {
    $Keys = aws iam list-access-keys --user-name $UserName --query "AccessKeyMetadata[].AccessKeyId" --output text --no-cli-pager 2>$null
    if ($Keys) {
        foreach ($Key in ($Keys -split '\s+' | Where-Object { $_ })) {
            aws iam delete-access-key --user-name $UserName --access-key-id $Key --no-cli-pager 2>$null
        }
    }
    $Policies = aws iam list-user-policies --user-name $UserName --query "PolicyNames" --output text --no-cli-pager 2>$null
    if ($Policies) {
        foreach ($Policy in ($Policies -split '\s+' | Where-Object { $_ })) {
            aws iam delete-user-policy --user-name $UserName --policy-name $Policy --no-cli-pager 2>$null
        }
    }
    aws iam delete-user --user-name $UserName --no-cli-pager 2>$null
    Write-SetupLog "Rollback complete: $UserName removed" -Level INFO
    } finally {
        if ($rbMutex) { $rbMutex.Dispose() }
    }
}
