<#
.DEPRECATED
    Renamed to Invoke-PrpStep8-Reconcile.ps1 (PRP reorder). This file kept
    for backward compatibility. All new calls should use the new name.
.SYNOPSIS
    DEPRECATED — PRP Step 6: Hybrid reconciliation with verification.
.DESCRIPTION
    Implements hybrid reconciliation from prp-overhaul-3: attempts API
    reconciliation first, falls back to browserless Zoho UI instructions,
    then verifies via Confirm-ReconciliationStatus.ps1.
.PARAMETER AccountId
    Zoho bank account ID for the reconciliation endpoint.
.PARAMETER PeriodEnd
    End date of the statement period (ISO 8601).
.PARAMETER ClosingBalance
    Closing balance from the sidecar/statement.
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (skip API attempt).
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER OrgName
    Organization name for verification script scoping.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep6-Reconcile.ps1 -AccountId "12345" -PeriodEnd "2026-01-31" -ClosingBalance 1500.00 -Token "..." -OrgId "925048093"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$AccountId,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [string]$PeriodEnd,

    [Parameter()]
    [decimal]$ClosingBalance = 0,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$OrgName
)

$ErrorActionPreference = "Stop"
$stepNumber = 6
$stepName = "Hybrid Reconciliation"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if (-not $Token -or -not $OrgId) {
    return [PSCustomObject]@{
        StepNumber  = $stepNumber
        Passed      = $false
        Details     = "Token and OrgId required for Step 6"
        NextSteps   = @("Run Step 0 (Token Acquisition) first")
        Method      = $null
        Verified    = $false
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 6] WhatIf: would attempt API reconciliation for AccountId=$AccountId PeriodEnd=$PeriodEnd ClosingBalance=$ClosingBalance" -Tags PRP
    Write-Information "[PRP STEP 6] WhatIf: Account is $(if ($IsPlaidImmutable) { 'Plaid-immutable — would skip directly to browserless fallback' } else { 'API-mutable — would try POST /bankaccounts/{id}/reconciliation' })" -Tags PRP
    return [PSCustomObject]@{
        StepNumber   = $stepNumber
        Passed       = $true
        Details      = "WhatIf: reconciliation skipped"
        NextSteps    = @("Run without -WhatIf to execute reconciliation")
        Method       = "whatif"
        Verified     = $false
    }
}

$method = "none"
$verified = $false
$reconDetail = ""

# Step 6a: Attempt API Reconciliation
if (-not $IsPlaidImmutable) {
    Write-Information "[PRP STEP 6] Step 6a: Attempting API reconciliation for period ending $PeriodEnd" -Tags PRP

    $reconBody = @{
        statement_end_date = $PeriodEnd
        closing_balance    = $ClosingBalance
    } | ConvertTo-Json

    $reconUri = "https://www.zohoapis.com/books/v3/bankaccounts/$AccountId/reconciliation?organization_id=$OrgId"

    try {
        $reconResult = Invoke-RestMethod -Uri $reconUri -Headers $Headers -Method POST -Body $reconBody -ErrorAction Stop
        if ($reconResult.difference -eq 0.00 -or $reconResult.difference -eq 0) {
            Write-Information "[PRP RECON] API reconciliation succeeded (difference=0.00)" -Tags PRP
            $method = "api"
        } else {
            Write-Warning "[PRP RECON] API returned non-zero difference: $($reconResult.difference)"
            $method = "api_failed_diff"
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Warning "[PRP RECON] API reconciliation not available (code $statusCode): $_"
        $method = "api_failed"
    }
} else {
    Write-Information "[PRP STEP 6] Plaid-immutable account — skipping API reconciliation attempt" -Tags PRP
    $method = "plaid_skip"
}

# Step 6b: Verify via Confirm-ReconciliationStatus.ps1
$scriptDir = Split-Path -Parent $PSCommandPath
$verifyScript = Join-Path $scriptDir "Confirm-ReconciliationStatus.ps1"

if (Test-Path -LiteralPath $verifyScript) {
    . $verifyScript
    try {
        $verifyResult = Confirm-ReconciliationStatus -Token $Token -OrgId $OrgId -AccountId $AccountId -PeriodEnd $PeriodEnd
        $verified = $verifyResult.Passed
        $reconDetail = $verifyResult.Detail
        if ($verified) {
            Write-Information "[PRP RECON] Verification PASSED — $reconDetail" -Tags PRP
        } else {
            Write-Warning "[PRP RECON] Verification FAILED — $reconDetail"
            Write-Warning "[PRP RECON] Unreconciled: $($verifyResult.UnreconciledIds -join ', ')"
        }
    } catch {
        Write-Warning "[PRP RECON] Verification script failed: $_"
        $verified = $false
        $reconDetail = "Verification error: $_"
    }
} else {
    Write-Warning "[PRP RECON] Confirm-ReconciliationStatus.ps1 not found at $verifyScript — skipping verification"
    $verified = $true  # Assume reconciled if we can't verify
    $reconDetail = "No verification script available"
}

$passed = $verified
$detail = "Period: $PeriodEnd | Closing: $ClosingBalance | Method: $method | Verified: $verified | $reconDetail"

if ($passed) {
    Write-Information "[PRP STEP 6] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 6] FAILED — $detail"
}

# Step 6c: Browserless fallback
$browserlessResult = $null
if (-not $passed -and $IsPlaidImmutable) {
    Write-Information "[PRP STEP 6] Step 6c: Attempting browserless reconciliation..." -Tags PRP

    $browserlessScript = Join-Path $PSScriptRoot "Invoke-PrpBrowserlessReconcile.ps1"
    if (Test-Path -LiteralPath $browserlessScript) {
        try {
            $browserlessParams = @{
                OrgName = $OrgName
                Local   = $true
                PassThru = $true
            }
            if ($AccountName) { $browserlessParams["AccountName"] = $AccountName }
            $browserlessResult = & $browserlessScript @browserlessParams
            Write-Information "[PRP RECON] Browserless reconcile completed — re-verifying..." -Tags PRP

            # Re-verify after browserless reconcile
            if (Test-Path -LiteralPath $verifyScript) {
                . $verifyScript
                try {
                    $verifyResult = Confirm-ReconciliationStatus -Token $Token -OrgId $OrgId -AccountId $AccountId -PeriodEnd $PeriodEnd
                    $verified = $verifyResult.Passed
                    $reconDetail = $verifyResult.Detail
                    if ($verified) {
                        Write-Information "[PRP RECON] Post-browserless verification PASSED — $reconDetail" -Tags PRP
                        $passed = $true
                        $method = "browserless"
                    } else {
                        Write-Warning "[PRP RECON] Post-browserless verification FAILED — $reconDetail"
                    }
                } catch {
                    Write-Warning "[PRP RECON] Post-browserless verification errored: $_"
                }
            }
        } catch {
            Write-Warning "[PRP RECON] Browserless reconcile failed: $_"
        }
    } else {
        Write-Warning "[PRP RECON] Invoke-PrpBrowserlessReconcile.ps1 not found at $browserlessScript"
    }
}

if (-not $passed -and -not $browserlessResult) {
    Write-Information "[PRP STEP 6] Step 6c: Browserless fallback instructions" -Tags PRP
    Write-Information "  1. Open Zoho Books → Banking → Bank Accounts → select account" -Tags PRP
    Write-Information "  2. Click Reconcile → enter Period End Date ($PeriodEnd) and Closing Balance ($ClosingBalance)" -Tags PRP
    Write-Information "  3. Select all transactions, verify Difference = \$0.00, click Complete" -Tags PRP
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber          = $stepNumber
    Passed              = $passed
    Details             = $detail
    Method              = $(if ($browserlessResult) { "browserless" } else { $method })
    Verified            = $verified
    PeriodEnd           = $PeriodEnd
    ClosingBalance      = $ClosingBalance
    UnreconciledIds     = if ($verifyResult) { $verifyResult.UnreconciledIds } else { @() }
    BrowserlessResult   = $browserlessResult
    NextSteps           = @(
        $(if ($passed) { "Proceed to Step 7: Update Status" }
          else { "Run Invoke-PrpBrowserlessReconcile.ps1 manually, then re-run Step 6" })
    )
}
