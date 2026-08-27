<#
.SYNOPSIS
    Creates a dedicated IAM user for the rekognition-fallback (api-proxy S3/Rekognition).
.DESCRIPTION
    Creates <Project>-REKOGNITIONFALLBACK IAM user with minimal S3 PutObject and
    Rekognition DetectLabels permissions. Access keys are persisted as Docker
    Swarm secrets (proxy_aws_id / proxy_aws_secret) for the api-proxy to consume
    at deploy time.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    Hashtable with AccessKeyId and SecretAccessKey.
#>
function New-RekognitionFallbackIamUser {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for Docker Swarm secrets')]
    [OutputType([hashtable])]
    param(
        $AgentContext
    )

    $ProjectCode = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $RoleCode = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }
    $SovereigntyTier = if ($AgentContext) { $AgentContext.SovereigntyTier } elseif ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "global" }
    $Toggle = $env:INSTALL_REKOGNITION_FALLBACK
    if ($Toggle -ne "true") {

        Write-SetupLog "Phase 6b: Rekognition-fallback IAM user skipped (INSTALL_REKOGNITION_FALLBACK=$Toggle)"
        return @{ AccessKeyId = $null; SecretAccessKey = $null; IamUserName = $null }
    }

    Write-SetupLog "Phase 6b: Creating rekognition-fallback IAM user"
    Write-Warning "`n[AWS] Creating rekognition-fallback IAM user..."

    $IamUserName = "${ProjectCode}-REKOGNITIONFALLBACK"
    $AccessKeyId = $null
    $SecretAccessKey = $null

    $ExistingUser = Invoke-AwsCommand { aws iam get-user --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
    if ($ExistingUser.Success) {
        Write-Verbose "  [OK] Rekognition-fallback IAM user already exists: $IamUserName"
        Write-SetupLog "Rekognition-fallback IAM user already exists: $IamUserName"
    }
    else {
        $CreateResult = Invoke-AwsCommand { aws iam create-user --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>&1 }
        if (-not $CreateResult.Success) {
            Write-Warning "  [WARN] Could not create rekognition-fallback IAM user $IamUserName."
            Write-SetupLog "Rekognition-fallback IAM user creation failed for $IamUserName. Error: $($CreateResult.Output)" -Level WARN
            return @{ AccessKeyId = $null; SecretAccessKey = $null; IamUserName = $null }
        }
        else {
            Write-Verbose "  [OK] Created rekognition-fallback IAM user: $IamUserName"
            Write-SetupLog "Created rekognition-fallback IAM user: $IamUserName"
        }
    }

    if ($IamUserName) {
        $PolicyFileName = "rekognition-fallback-${SovereigntyTier}.json"
        $RepoRoot = Get-InterclawRepoRoot
        $PolicyPath = Join-Path $RepoRoot "Infrastructure" "Policies" $PolicyFileName
        if (Test-Path $PolicyPath) {
            $PolicyDoc = Get-Content $PolicyPath -Raw
            $tmpPolicyFile = Join-Path $env:TEMP "oc-policy-$([System.IO.Path]::GetRandomFileName()).json"
            try {
                Set-Content -Path $tmpPolicyFile -Value $PolicyDoc -Encoding UTF8 -NoNewline
                $PutPolicyResult = $null
                for ($ppAttempt = 1; $ppAttempt -le 3; $ppAttempt++) {
                    $PutPolicyResult = Invoke-AwsCommand { aws iam put-user-policy --user-name $IamUserName --policy-name "RekognitionFallback-Policy" --policy-document "file://$($tmpPolicyFile -replace '\\', '/')" --profile $env:AWS_SSO_PROFILE 2>&1 }
                    if ($PutPolicyResult.Success) { break }
                    if ($ppAttempt -lt 3) {
                        Write-SetupLog "rekognition-fallback put-user-policy attempt $ppAttempt/3 failed: $($PutPolicyResult.Output)" -Level WARN
                        Start-Sleep -Seconds ($ppAttempt * 5)
                    }
                }
            } finally {
                if (Test-Path $tmpPolicyFile) { Remove-Item $tmpPolicyFile -Force -ErrorAction SilentlyContinue }
            }
            if ($PutPolicyResult.Success) {
                Write-Verbose "  [OK] Updated $PolicyFileName policy on $IamUserName"
                Write-SetupLog "Updated $PolicyFileName policy on $IamUserName"
            }
            else {
                Write-Warning "  [WARN] Could not update $PolicyFileName policy on $IamUserName"
                Write-SetupLog "Rekognition-fallback policy update failed for ${IamUserName}: $($PutPolicyResult.Output)" -Level WARN
            }
        }
        else {
            Write-Warning "  [WARN] Rekognition-fallback policy file not found: $PolicyPath"
            Write-SetupLog "Rekognition-fallback policy file not found: $PolicyPath" -Level WARN
        }
    }

    if ($IamUserName) {
        $KeysResult = Invoke-AwsCommand { aws iam list-access-keys --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
        $ExistingKeyMetadata = @()
        if ($KeysResult.Success -and -not [string]::IsNullOrWhiteSpace($KeysResult.Output)) {
            $ExistingKeyMetadata = @($($KeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
        }

        $Rotate = $env:ROTATE_PREEXISTING_KEYS -eq "true"
        if ($ExistingKeyMetadata.Count -gt 0 -and -not $Rotate) {
            $YoungestKey = $ExistingKeyMetadata | Sort-Object CreateDate -Descending | Select-Object -First 1
            $AccessKeyId = $YoungestKey.AccessKeyId
            Write-Verbose "  [SKIP] Reusing existing rekognition-fallback access key: $AccessKeyId (set ROTATE_PREEXISTING_KEYS=true to rotate)"
            Write-SetupLog "Reusing existing access key for $IamUserName (ROTATE_PREEXISTING_KEYS=$env:ROTATE_PREEXISTING_KEYS)"
            $BundleData = Read-ContainerSecretBundle -BundleName "proxy_secrets_bundle" -ServiceName "is-bookkeeping"
            if ($BundleData -and $BundleData.proxy_aws_secret -and $BundleData.proxy_aws_id -eq $AccessKeyId) {
                $SecretAccessKey = $BundleData.proxy_aws_secret
                Write-Verbose "  [OK] Retrieved proxy_aws_secret from Swarm bundle: proxy_secrets_bundle"
                Write-SetupLog "Retrieved existing secret for $IamUserName from Swarm bundle"
            }
            if (-not $SecretAccessKey) {
                Write-Verbose "  [INFO] No existing Swarm bundle with matching key  -  will rotate keys"
                Write-SetupLog "Swarm bundle read failed for $IamUserName  -  rotating" -Level INFO
                $Rotate = $true
            }
        }

        if ($Rotate -or $ExistingKeyMetadata.Count -eq 0) {
            foreach ($OldKey in $ExistingKeyMetadata) {
                Write-Verbose "  [INFO] Deleting old rekognition-fallback access key: $($OldKey.AccessKeyId)"
                Invoke-AwsCommand { aws iam delete-access-key --user-name $IamUserName --access-key-id $OldKey.AccessKeyId --profile $env:AWS_SSO_PROFILE 2>$null | Out-Null } | Out-Null
            }

            $NewKeyResult = Invoke-AwsCommand { aws iam create-access-key --user-name $IamUserName --profile $env:AWS_SSO_PROFILE --output json 2>$null }
            if ($NewKeyResult.Success -and -not [string]::IsNullOrWhiteSpace($NewKeyResult.Output)) {
                $NewKey = $NewKeyResult.Output | ConvertFrom-Json
                $AccessKeyId = $NewKey.AccessKey.AccessKeyId
                $SecretAccessKey = $NewKey.AccessKey.SecretAccessKey
                Write-Verbose "  [OK] Created rekognition-fallback access key: $AccessKeyId"
                Write-SetupLog "Created rekognition-fallback access key: $AccessKeyId"
            }
            else {
                Write-Warning "  [WARN] Could not create rekognition-fallback access key"
                Write-SetupLog "Rekognition-fallback access key creation failed" -Level WARN
                return @{ AccessKeyId = $null; SecretAccessKey = $null; IamUserName = $null }
            }
        }
    }

    if ($AccessKeyId -and $SecretAccessKey) {
        Set-SwarmSecretSafe -SecretName "proxy_aws_id" -SecretValue (ConvertTo-SecureString $AccessKeyId -AsPlainText -Force) -Label "proxy_aws_id"
        Set-SwarmSecretSafe -SecretName "proxy_aws_secret" -SecretValue (ConvertTo-SecureString $SecretAccessKey -AsPlainText -Force) -Label "proxy_aws_secret"
        Write-Verbose "  [OK] Rekognition-fallback AWS keys persisted as Docker Swarm secrets"
        Write-SetupLog "Rekognition-fallback AWS keys stored as swarm secrets: proxy_aws_id, proxy_aws_secret"
    }
    else {
        Write-Warning "  [WARN] Rekognition-fallback AWS credentials not created  -  proxy rekognition features will be unavailable."
        Write-SetupLog "Rekognition-fallback AWS credentials not created" -Level WARN
    }

    Write-SetupLog "Phase 6b complete: rekognition-fallback IAM user provisioned"

    return @{
        AccessKeyId = $AccessKeyId
        SecretAccessKey = $SecretAccessKey
        IamUserName = $IamUserName
    }
}
