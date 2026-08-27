<#
.SYNOPSIS
    Runs sovereignty validation tests for the configured tier.
.DESCRIPTION
    Tests Bedrock access in the home region and verifies out-of-region
    access is denied. For global tier, skips regional lock checks.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Test-Sovereignty {
    [OutputType([void])]
    param()
    $SovereigntyTier = if ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "canada" }

    Write-SetupLog "1KeyTest started  -  SovereigntyTier=$SovereigntyTier"
    Write-Warning "`n[CHECK] Starting Security & Connectivity Tests (Tier: $SovereigntyTier)..."

    $SsoProfile = $env:AWS_SSO_PROFILE
    $AllTestsPassed = $true

    # --- SOVEREIGNTY TESTS (skipped for Global) ---
    if ($SovereigntyTier -eq "global") {
        Write-Verbose "   [SKIP] Sovereignty tests: Global tier  -  no regional lock enforced."
        Write-SetupLog "Global tier: skipping sovereignty tests"
    }
    elseif ($SovereigntyTier -eq "canada") {
        # Canada: positive test on ca-central-1, negative test on us-east-1
        Write-SetupLog "Phase 1: Canadian sovereignty test (positive)"
        $SovereignResult = Invoke-AwsCommand { aws bedrock list-inference-profiles --region ca-central-1 --max-items 1 --profile $SsoProfile 2>&1 }
        if ($SovereignResult.Success) {
            Write-Verbose "   [PASS] Canada Resource Access: ca-central-1"
            Write-SetupLog "PASS: Canadian sovereignty positive test - ca-central-1 accessible"
        }
        else {
            Write-SetupLog "FAIL: Canadian sovereignty test - cannot reach ca-central-1" -Level ERROR
            Write-Warning "   [FAIL] Canada Resource Access: Could not reach ca-central-1 Bedrock."
            Write-Verbose "          $($SovereignResult.Output)"
            $AllTestsPassed = $false
        }

        Write-SetupLog "Phase 2: Sovereign boundary test (us-east-1 must be denied)"
        $usTest = Invoke-AwsCommand { aws bedrock list-inference-profiles --region us-east-1 --profile $SsoProfile 2>&1 }
        if ($usTest.Output -match "AccessDenied") {
            Write-Verbose "   [PASS] Sovereign Lock: us-east-1 access denied."
            Write-SetupLog "PASS: Sovereign boundary test - us-east-1 denied"
        }
        else {
            Write-SetupLog "FAIL: Sovereign boundary test - US access not blocked" -Level ERROR
            Write-Warning "   [FAIL] Sovereign Lock: us-east-1 was accessible!"
            $AllTestsPassed = $false
        }
    }
    elseif ($SovereigntyTier -eq "usa") {
        # USA: positive test on us-east-1, negative test on ca-central-1
        Write-SetupLog "Phase 1: US sovereignty test (positive)"
        $usResult = Invoke-AwsCommand { aws bedrock list-inference-profiles --region us-east-1 --max-items 1 --profile $SsoProfile 2>&1 }
        if ($usResult.Success) {
            Write-Verbose "   [PASS] USA Resource Access: us-east-1"
            Write-SetupLog "PASS: US sovereignty positive test - us-east-1 accessible"
        }
        else {
            Write-SetupLog "FAIL: US sovereignty test - cannot reach us-east-1" -Level ERROR
            Write-Warning "   [FAIL] USA Resource Access: Could not reach us-east-1 Bedrock."
            Write-Verbose "          $($usResult.Output)"
            $AllTestsPassed = $false
        }

        Write-SetupLog "Phase 2: Sovereign boundary test (ca-central-1 must be denied)"
        $caTest = Invoke-AwsCommand { aws bedrock list-inference-profiles --region ca-central-1 --profile $SsoProfile 2>&1 }
        if ($caTest.Output -match "AccessDenied") {
            Write-Verbose "   [PASS] Sovereign Lock: ca-central-1 access denied."
            Write-SetupLog "PASS: Sovereign boundary test - ca-central-1 denied"
        }
        else {
            Write-SetupLog "FAIL: Sovereign boundary test - Canada access not blocked" -Level ERROR
            Write-Warning "   [FAIL] Sovereign Lock: ca-central-1 was accessible!"
            $AllTestsPassed = $false
        }
    }

    # --- OpenRouter Key Test (Global tier only) ---
    Write-SetupLog "Phase 5: OpenRouter API key test (Global tier)"
    if ($SovereigntyTier -eq "global") {
        $apiOk = (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) -or (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_CODE_KEY))
        if ($apiOk) {
            Write-Verbose "   [PASS] OpenRouter API key is set."
            Write-SetupLog "PASS: OpenRouter API key is configured"
        }
        else {
            Write-Warning "   [WARN] OpenRouter API key not set - OpenRouter models may not be available."
            Write-SetupLog "WARN: OpenRouter API key not set" -Level WARN
        }
    }

    # --- Final Decision ---
    if ($AllTestsPassed) {
        Write-Verbose "`n[RESULT] Validation Successful. Environment is secure and ready."
        Write-SetupLog "1KeyTest complete: all validations passed (tier=$SovereigntyTier)"
        return
    }
    else {
        Write-Warning "`n[RESULT] Validation Failed. Aborting to prevent non-compliant state."
        Write-SetupLog "FAIL: validation failed (tier=$SovereigntyTier)" -Level ERROR
        throw "Sovereignty validation failed (tier=$SovereigntyTier)"
    }
}
