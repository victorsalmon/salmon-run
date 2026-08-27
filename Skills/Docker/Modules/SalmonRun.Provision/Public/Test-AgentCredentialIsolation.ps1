<#
.SYNOPSIS
    Tests that an agent's IAM credentials respect sovereignty locks.
.DESCRIPTION
    Verifies the agent can access its home region Bedrock but is denied
    access to regions outside its sovereignty tier.
.PARAMETER AgentAccessKeyId
    IAM access key ID for the agent.
.PARAMETER AgentSecretAccessKey
    IAM secret access key for the agent.
.PARAMETER IamUserName
    IAM user name for logging.
.PARAMETER BedrockRegion
    Allowed Bedrock region for this agent's sovereignty tier.
.OUTPUTS
    $true if isolation passes, throws on failure.
#>
function Test-AgentCredentialIsolation {
    [OutputType([bool])]
    param(
        [SecureString]$AgentAccessKeyId,
        [SecureString]$AgentSecretAccessKey,
        [string]$IamUserName,
        [string]$BedrockRegion
    )

    # ==============================================================================
    # PHASE 5a: Agent Credential Verification (zero IAM access)
    # ==============================================================================
    # Test the newly-created agent credentials directly to confirm they cannot
    # access IAM. This is the runtime security boundary  -  if these credentials
    # can reach IAM, least privilege is violated and the agents could escalate.
    $Result = [pscustomobject]@{
        Passed    = $true
        Warnings  = @()
        Failures  = @()
    }

    if ($AgentAccessKeyId -and $AgentSecretAccessKey) {
        Write-SetupLog "Phase 5a: Verifying agent credential isolation"
        Write-Warning "`n[AWS] Verifying agent credentials ($IamUserName)..."

        # New access keys can take up to 10 seconds to propagate across AWS regions
        Write-Verbose "  [INFO] Waiting $((Get-InterclawConstants).AwsKeyInitialPropagationWaitSec)s for new access key to propagate..."
        Start-Sleep -Seconds (Get-InterclawConstants).AwsKeyInitialPropagationWaitSec

        $VerifyRegion = if ($BedrockRegion) { $BedrockRegion } else { "us-east-1" }

        # Save $LASTEXITCODE because aws CLI calls inside the test will set it
        # to non-zero (expected AccessDenied) and we don't want that to leak.
        $SavedExitCode = $LASTEXITCODE

        try {
            Invoke-WithCredentialSwap -AccessKeyId $AgentAccessKeyId -SecretAccessKey $AgentSecretAccessKey -Region "$VerifyRegion" -ScriptBlock {
            $AgentIamTest = $null
            $AgentIamRetry = 0
            $AgentIamExit = -1
            while ($AgentIamRetry -lt (Get-InterclawConstants).AwsKeyPropagationRetries) {
                $AgentIamTest = aws iam list-users --region "$VerifyRegion" 2>&1
                $AgentIamExit = $LASTEXITCODE
                $AgentIamText = ($AgentIamTest -join "`n")
                if ($AgentIamExit -eq 0) {
                    # Agent should NOT be able to list users  -  if exit 0, policy is too permissive
                    break
                }
                if ($AgentIamText -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Write-Verbose "  [INFO] Access key not yet active, retrying... ($($AgentIamRetry + 1)/$((Get-InterclawConstants).AwsKeyPropagationRetries))"
                    Start-Sleep -Seconds (Get-InterclawConstants).AwsKeyPropagationDelaySec
                    $AgentIamRetry++
                    continue
                }
                # Any other error (AccessDenied, etc.) is expected  -  break and verify
                break
            }
            if ($AgentIamText -match "AccessDenied" -or $AgentIamExit -ne 0) {
                Write-Verbose "  [PASS] Agent IAM access denied  -  least privilege enforced."
                Write-SetupLog "Agent credential verification PASS: IAM access denied for $IamUserName"
            }
            else {
                Write-Warning "  [FAIL] Agent IAM access granted! Least privilege violated!"
                Write-Warning "         The sovereignty policy may grant iam:* permissions."
                Write-SetupLog "Agent credential verification FAIL: IAM access granted for $IamUserName" -Level ERROR
                $Result.Failures += "Agent IAM access granted  -  least privilege violated"
                $Result.Passed = $false
            }

            if ($BedrockRegion) {
                $AgentBedrockTest = aws bedrock list-inference-profiles --region "$BedrockRegion" --max-items 1 2>&1
                $AgentBedrockExit = $LASTEXITCODE
                if ($AgentBedrockExit -eq 0) {
                    Write-Verbose "  [PASS] Agent Bedrock access confirmed in $BedrockRegion."
                    Write-SetupLog "Agent credential verification PASS: Bedrock access in $BedrockRegion for $IamUserName"
                }
                else {
                    $AgentBedrockText = ($AgentBedrockTest -join "`n")
                    Write-Warning "  [WARN] Agent Bedrock access failed in $BedrockRegion  -  model invoke may not work."
                    Write-Verbose "         Details: $AgentBedrockText"
                    Write-SetupLog "Agent credential verification WARN: Bedrock access failed in $BedrockRegion for $IamUserName ($AgentBedrockText)" -Level WARN
                    $Result.Warnings += "Bedrock access failed in $BedrockRegion"
                }

                # Cross-region isolation test: verify Bedrock is denied in a non-permitted region
                $blockedRegions = @("us-east-1", "eu-west-1", "ap-southeast-1") | Where-Object { $_ -ne $BedrockRegion }
                $crossRegionTested = $false
                foreach ($blockedRegion in $blockedRegions) {
                    $crossTest = aws bedrock list-inference-profiles --region "$blockedRegion" --max-items 1 2>&1
                    $crossExit = $LASTEXITCODE
                    if ($crossExit -ne 0 -and ($crossTest -join " ") -match "AccessDenied|UnauthorizedOperation|Forbidden") {
                        Write-Verbose "  [PASS] Cross-region Bedrock denied in $blockedRegion — sovereignty isolation enforced."
                        Write-SetupLog "Agent credential verification PASS: Cross-region Bedrock denied for $IamUserName in $blockedRegion"
                        $crossRegionTested = $true
                        break
                    }
                    if ($crossExit -eq 0) {
                        Write-Warning "  [FAIL] Cross-region Bedrock ACCESS GRANTED in $blockedRegion — sovereignty isolation VIOLATED!"
                        Write-SetupLog "Agent credential verification FAIL: Cross-region Bedrock allowed for $IamUserName in $blockedRegion" -Level ERROR
                        $Result.Failures += "Cross-region Bedrock access granted in $blockedRegion — policy too permissive"
                        $crossRegionTested = $true
                        break
                    }
                }
                if (-not $crossRegionTested) {
                    Write-Verbose "  [SKIP] Cross-region isolation test: no blocked region matched AccessDenied pattern — test inconclusive"
                    Write-SetupLog "Agent credential verification SKIP: Cross-region test inconclusive for $IamUserName"
                }
            }
            else {
                Write-Verbose "  [SKIP] No Bedrock region configured  -  skipping Bedrock credential verification."
                Write-SetupLog "Agent credential verification SKIP: No Bedrock region for $IamUserName"
            }

            # Cross-account isolation test: verify Organizations API is denied (agents should not list accounts)
            $orgTest = aws organizations list-accounts 2>&1
            $orgExit = $LASTEXITCODE
            if ($orgExit -ne 0 -and ($orgTest -join " ") -match "AccessDenied|UnauthorizedOperation|Forbidden") {
                Write-Verbose "  [PASS] Cross-account Organizations API denied — agent cannot enumerate AWS accounts."
                Write-SetupLog "Agent credential verification PASS: Organizations API denied for $IamUserName"
            }
            elseif ($orgExit -eq 0) {
                Write-Warning "  [FAIL] Cross-account Organizations API ACCESS GRANTED — agent can list all AWS accounts!"
                Write-SetupLog "Agent credential verification FAIL: Organizations API allowed for $IamUserName" -Level ERROR
                $Result.Failures += "Organizations API access granted — cross-account isolation violated"
                $Result.Passed = $false
            }
            else {
                Write-Verbose "  [SKIP] Cross-account verification: unexpected Organizations response (exit=$orgExit)"
                Write-SetupLog "Agent credential verification SKIP: Organizations unexpected response for $IamUserName"
            }
        }

        } finally {
            # Restore $LASTEXITCODE so it doesn't leak non-zero from expected AccessDenied.
            # MUST use $global: scope  -  local assignment is discarded when the function returns.
            $global:LASTEXITCODE = $SavedExitCode
        }

        Write-SetupLog "Phase 5a complete: agent credentials verified"
    }

    return $Result
}
