<#
.SYNOPSIS
    PRP Step 7f: Verify Recon Readiness via account-level status checks.
.DESCRIPTION
    Reads the organization status JSON produced by Invoke-StatusCheck.ps1,
    runs Test-AccountPreReconReady on the specified account, and returns
    PASS/FAIL with dimension-level blockers.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Account slug name (e.g. "RBC-INTERSITE", "TD-MLM").
.PARAMETER IsPlaidImmutable
    Whether this account is Plaid-immutable.
.EXAMPLE
    .\Invoke-PrpStep7f-ReconReadyVerify.ps1 -OrgName "intersite-consulting" -AccountName "RBC-INTERSITE"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = "7f"
$stepName = "Recon Ready Verification"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
$statusPath = Join-Path $booksRoot "$OrgName-status.json"

if (-not (Test-Path $statusPath)) {
    Write-Warning "[PRP STEP 7f] Status file not found at $statusPath"
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "Status file not found — run Invoke-StatusCheck.ps1 first"
        NextSteps  = @("Run Status Check: Invoke-StatusCheck.ps1 -Organization $OrgName")
    }
}

$status = Get-Content $statusPath -Raw -Encoding utf8 | ConvertFrom-Json

if (-not $status.accounts) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "Status file has no accounts data"
        NextSteps  = @("Regenerate status: Invoke-StatusCheck.ps1 -Organization $OrgName")
    }
}

$accountProp = $status.accounts.PSObject.Properties | Where-Object { $_.Name -eq $AccountName }
if (-not $accountProp) {
    $accountProp = $status.accounts.PSObject.Properties | Where-Object { $_.Value.label -eq $AccountName }
}
if (-not $accountProp) {
    $knownSlugs = ($status.accounts.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "Account '$AccountName' not found in status. Known accounts: $knownSlugs"
        NextSteps  = @("Verify account slug matches status file")
    }
}

$account = $accountProp.Value
$cloudTx = if ($account.cloud_transaction_complete_date) { $account.cloud_transaction_complete_date.date } else { $null }
$localTx = if ($account.local_transaction_complete_date) { $account.local_transaction_complete_date.date } else { $null }
$cloudRc = if ($account.cloud_receipt_complete_date) { $account.cloud_receipt_complete_date.date } else { $null }
$localRc = if ($account.local_receipt_complete_date) { $account.local_receipt_complete_date.date } else { $null }
$recon   = if ($account.reconciliation_date) { $account.reconciliation_date.date } else { $null }

if (-not $recon) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "No reconciliation date set — run Step 7e first"
        NextSteps  = @("Run Step 7e (Update Status) to set reconciliation date")
    }
}

function Test-DateString { param([string]$DateStr) try { if ($DateStr) { return [datetime]::Parse($DateStr, [System.Globalization.CultureInfo]::CurrentCulture) } } catch {} return $null }

$today = (Get-Date).Date
$threshold = 30
$blockers = @()

# 1. Transactions — both cloud and local must be current (within 30 days)
$cloudDt = Test-DateString $cloudTx; $localDt = Test-DateString $localTx
$cloudOk = $null -ne $cloudDt; $localOk = $null -ne $localDt
$txCurrent = $cloudOk -and $localOk -and ($today - $cloudDt).Days -le $threshold -and ($today - $localDt).Days -le $threshold
if (-not $txCurrent) {
    $blockers += "transactions not current: cloud=$cloudTx local=$localTx"
}

# 2. Receipts — both cloud and local must be current (within 30 days)
$cloudRcDt = Test-DateString $cloudRc; $localRcDt = Test-DateString $localRc
$cloudRcOk = $null -ne $cloudRcDt; $localRcOk = $null -ne $localRcDt
$rcCurrent = $cloudRcOk -and $localRcOk -and ($today - $cloudRcDt).Days -le $threshold -and ($today - $localRcDt).Days -le $threshold
if (-not $rcCurrent) {
    $blockers += "receipts not current: cloud=$cloudRc local=$localRc"
}

# 3. Reconciliation — must be behind (at least 25 days) — meaning there's a period ready to reconcile
$reconDt = Test-DateString $recon
$reconBehind = $null -ne $reconDt -and ($today - $reconDt).Days -ge 25
if (-not $reconBehind) {
    $blockers += "reconciliation is up to date ($recon), no periods waiting"
}

$plaidNote = if ($IsPlaidImmutable) { " (Plaid-immutable — some checks may be relaxed)" } else { "" }

$passed = $blockers.Count -eq 0
$detail = if ($passed) {
    "Recon Ready: PASS$plaidNote — transactions current (cloud=$cloudTx, local=$localTx), receipts current (cloud=$cloudRc, local=$localRc), recon behind ($recon)"
} else {
    "Recon Ready: FAIL — $($blockers -join '; ')$plaidNote"
}

if ($passed) {
    Write-Information "[PRP STEP 7f] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 7f] FAILED — $detail"
    foreach ($b in $blockers) { Write-Warning "  Blocker: $b" }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber = $stepNumber
    Passed     = $passed
    Details    = $detail
    Blockers   = $blockers
    Dimensions = @{
        transactions_current = $txCurrent
        receipts_current     = $rcCurrent
        reconciliation_behind = $reconBehind
    }
    NextSteps  = @(
        $(if ($passed) { "Proceed — account is Recon Ready" }
          else { "Fix blockers: $($blockers -join '; ')" })
    )
}
