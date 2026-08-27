<#
.SYNOPSIS
    Sets up AWS Bedrock CLI profiles for each agent role and model type.
.DESCRIPTION
    Creates named AWS CLI profiles (<Project>-<Role>-<Instance>-<ModelType>)
    configured with the agent's IAM credentials for Bedrock access.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Invoke-BedrockProfileSetup {
    [OutputType([void])]
    param(
        $AgentContext
    )

    Write-SetupLog "Phase 4: Configuring Bedrock inference profiles"
    # 4. Bedrock Inference Profile Creation

    $RoleCode = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }

    # CODE containers use direct API keys (OpenRouter) '" skip Bedrock entirely
    if ($RoleCode -eq "CODE") {
        Write-SetupLog "Skipping Bedrock profile setup for CODE role"
        return
    }

    Write-Information "`n[AWS] Configuring Bedrock inference profiles..."

    $SovereigntyTier = if ($AgentContext) { $AgentContext.SovereigntyTier } elseif ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "canada" }
    $ProjectCode = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $InstanceID = if ($AgentContext) { $AgentContext.InstanceId } else { $env:INTERCLAW_INSTANCE_ID }
    $ProfileName = "${ProjectCode}-${RoleCode}-${InstanceID}"

    # Select provider catalog based on sovereignty tier
    $CatalogMap = @{
        "canada" = "canada-ORCHESTRATOR.json"
        "usa"    = "usa-ORCHESTRATOR.json"
        "global" = "global-ORCHESTRATOR.json"
    }
    $CatalogFileName = $CatalogMap[$SovereigntyTier]
    if (-not $CatalogFileName) { $CatalogFileName = "canada-ORCHESTRATOR.json" }
    $RepoRoot = Get-InterclawRepoRoot
    $ProviderCatalogPath = Join-Path $RepoRoot "Infrastructure" "ORCHESTRATOR" "providers" $CatalogFileName
    if (-not (Test-Path $ProviderCatalogPath)) {
            Write-Warning "  [!] Provider catalog not found: $ProviderCatalogPath - skipping inference profile creation."
    }
    else {
        $ProviderCatalog = Get-Content $ProviderCatalogPath -Raw | ConvertFrom-Json

        # Navigate the nested catalog structure: models.providers.amazon-bedrock
        $BedrockProvider = $null
        $BedrockRegion = $null
        $BedrockModels = @()

        if ($ProviderCatalog.models -and $ProviderCatalog.models.providers) {
            $bedrockProp = $ProviderCatalog.models.providers.PSObject.Properties["amazon-bedrock"]
            if ($bedrockProp) {
                $BedrockProvider = $bedrockProp.Value
                if ($BedrockProvider.baseUrl) {
                    $BedrockRegion = if ($BedrockProvider.baseUrl -match 'bedrock-runtime\.([a-z0-9-]+)\.amazonaws\.com') { $Matches[1] } else { $BedrockProvider.region }
                } else {
                    $BedrockRegion = $BedrockProvider.region
                }
                $BedrockModels = @($BedrockProvider.models)
            }
        }

        if (-not $BedrockRegion -or $BedrockModels.Count -eq 0) {
                Write-Verbose "  [SKIP] No Bedrock provider found in catalog for this tier - skipping inference profile creation."
            Write-SetupLog "No Bedrock provider in catalog, skipping inference profiles"
        }
        else {
            Write-Verbose "  [AWS] Bedrock region: $BedrockRegion, models: $($BedrockModels.Count)"

            $ProfilesResult = Invoke-AwsCommand {
                aws bedrock list-inference-profiles `
                    --region $BedrockRegion `
                    --profile $env:AWS_SSO_PROFILE `
                    --output json 2>$null
            }

            $ExistingProfileNames = @()
            if ($ProfilesResult.Success -and -not [string]::IsNullOrWhiteSpace($ProfilesResult.Output)) {
                $Parsed = $ProfilesResult.Output | ConvertFrom-Json
                $ExistingProfileNames = @($Parsed.inferenceProfileSummaries | ForEach-Object { $_.name })
            }

            $SsoProfile = $env:AWS_SSO_PROFILE

            Write-ParallelSectionHeader -Title "Bedrock Inference Profiles" -Workers ($BedrockModels | ForEach-Object { "$($_.name) ($($_.type))" })

            $bedrockResults = $BedrockModels | ForEach-Object -Parallel {
                $Model = $_
                $ProfileName = $using:ProfileName
                $ExistingProfileNames = $using:ExistingProfileNames
                $BedrockRegion = $using:BedrockRegion
                $SsoProfile = $using:SsoProfile

                $ModelSuffix = $Model.type
                $InferenceProfileName = "${ProfileName}-${ModelSuffix}"
                $ModelArn = "arn:aws:bedrock:${BedrockRegion}::foundation-model/$($Model.id)"

                if ($InferenceProfileName -in $ExistingProfileNames) {
                    Write-Output "SKIP:$InferenceProfileName (already exists)"
                    return
                }

                # Pre-flight: verify the model actually exists in this region
                $ModelCheckBlock = { & aws bedrock get-foundation-model --model-identifier $using:Model.id --region $using:BedrockRegion --profile $using:SsoProfile --cli-read-timeout 30 --cli-connect-timeout 10 --output json 2>&1 }
                $ModelCheck = Invoke-BedrockCallWithTimeout -ScriptBlock $ModelCheckBlock -TimeoutSeconds 120 -Description "Check model availability"
                if (-not $ModelCheck.Success) {
                    Write-Output "SKIP:$InferenceProfileName (model not found in $BedrockRegion)"
                    return
                }

                # Build the full request payload as JSON to avoid PowerShell argument-passing quirks.
                # Tags are omitted because the SSO role has an explicit deny on bedrock:TagResource.
                # Sanitize description to comply with AWS regex: ([0-9a-zA-Z:.][ _-]?)+
                $SafeModelName = $Model.name -replace '[^0-9a-zA-Z:._\-]', ' '
                $SafeModelType = $Model.type -replace '[^0-9a-zA-Z:._\-]', ' '
                $RequestPayload = @{
                    inferenceProfileName = $InferenceProfileName
                    description = "Interclaw ${SafeModelType} profile ${SafeModelName} for ${ProfileName}"
                    modelSource = @{
                        copyFrom = $ModelArn
                    }
                } | ConvertTo-Json -Depth 3

                $RequestTemp = [System.IO.Path]::GetTempFileName()
                Set-Content -Path $RequestTemp -Value $RequestPayload -Encoding UTF8 -NoNewline

                $requestJson = $RequestPayload
                try {
                    $CreateBlock = { & aws bedrock create-inference-profile --cli-input-json $using:requestJson --region $using:BedrockRegion --profile $using:SsoProfile --cli-read-timeout 30 --cli-connect-timeout 10 --output json 2>&1 }
                    $CreateResult = Invoke-BedrockCallWithTimeout -ScriptBlock $CreateBlock -TimeoutSeconds 120 -Description "Create Bedrock profile: $InferenceProfileName"
                }
                finally {
                    Remove-Item $RequestTemp -Force -ErrorAction SilentlyContinue
                }

                $CreateOutput = $CreateResult.Output
                if ($CreateResult.Success -and $CreateOutput -and -not ($CreateOutput -match '^\s*\{')) {
                    $CreateOutput = $CreateOutput | Select-String '^\s*\{' | Select-Object -First 1
                }

                if ($CreateResult.Success -and -not [string]::IsNullOrWhiteSpace($CreateOutput)) {
                    try {
                        $ProfileObj = $CreateOutput | ConvertFrom-Json
                        Write-Output "OK:$InferenceProfileName"
                        Write-Output "ARN:$($ProfileObj.inferenceProfileArn)"
                    } catch {
                        Write-Output "WARN:$InferenceProfileName (created but response not JSON)"
                    }
                }
                else {
                    $IsUnsupported = $CreateOutput -match 'does not support On Demand inference|ValidationException|ResourceNotFoundException'
                    if ($IsUnsupported) {
                        Write-Output "SKIP:$InferenceProfileName (inference profiles not supported for this model)"
                    }
                    else {
                        Write-Output "FAIL:$InferenceProfileName ($($Model.name))"
                    }
                }
            } -ThrottleLimit 3

            $bedrockSummary = [System.Collections.Generic.List[object]]::new()
            foreach ($line in $bedrockResults) {
                if ($line -match '^OK:') {
                    $name = $line -replace '^OK:', ''
                    Write-Verbose "  [OK] Created: $name"
                    Write-SetupLog "Created inference profile: $name"
                    $bedrockSummary.Add(@{ Name = $name; Status = "OK"; Detail = "Created" })
                } elseif ($line -match '^ARN:') {
                    $arn = $line -replace '^ARN:', ''
                    Write-Verbose "       ARN: $arn"
                } elseif ($line -match '^SKIP:') {
                    $reason = $line -replace '^SKIP:', ''
                    Write-Verbose "  [SKIP] $reason"
                    Write-SetupLog "Skipped inference profile: $reason" -Level WARN
                    $cleanedName = $reason -replace ' \(.*$', ''
                    $bedrockSummary.Add(@{ Name = $cleanedName; Status = "SKIP"; Detail = $reason })
                } elseif ($line -match '^WARN:') {
                    $detail = $line -replace '^WARN:', ''
                    Write-Warning "  [WARN] $detail"
                    Write-SetupLog "Created inference profile but response not JSON: $detail" -Level WARN
                    $bedrockSummary.Add(@{ Name = $detail; Status = "WARN"; Detail = "Response not JSON" })
                } elseif ($line -match '^FAIL:') {
                    $detail = $line -replace '^FAIL:', ''
                    Write-Warning "  [!] Failed to create: $detail"
                    Write-SetupLog "Failed to create inference profile: $detail" -Level WARN
                    $bedrockSummary.Add(@{ Name = $detail; Status = "FAIL"; Detail = "Creation failed" })
                }
            }
            Write-ParallelSectionSummary -Title "Bedrock Inference Profiles" -Results $bedrockSummary
        }
    }

    Write-SetupLog "Phase 4 complete: Bedrock inference profiles configured"
    return $BedrockRegion
}

function Invoke-BedrockCallWithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 60,
        [string]$Description = "Bedrock API call"
    )
    $Job = Start-Job -ScriptBlock $ScriptBlock
    $Completed = Wait-Job -Job $Job -Timeout $TimeoutSeconds

    if (-not $Completed) {
        Stop-Job -Job $Job
        $Output = Receive-Job -Job $Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force
        Write-SetupLog "TIMEOUT: $Description exceeded ${TimeoutSeconds}s" -Level WARN
        return @{ Success = $false; Error = "Timeout after ${TimeoutSeconds}s" }
    }

    $Output = Receive-Job -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force
    return @{ Success = $true; Output = $Output }
}
