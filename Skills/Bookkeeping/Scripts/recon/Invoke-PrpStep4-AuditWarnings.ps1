<#
.SYNOPSIS
    PRP Step 4: Scan for audit warning patterns.
.DESCRIPTION
    Runs 10 warning pattern checks against the local dataset:
    CC payments miscategorized, negative balance expenses, Shareholder Loan
    activity, cross-entity contamination, and others. Returns warnings list
    with per-warning fix strategies.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions array.
.PARAMETER AllExpenses
    All expenses from bulk fetch.
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (affects remediation).
.PARAMETER EntityName
    Entity name for cross-entity contamination check.
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep4-AuditWarnings.ps1 -ZohoAll $zohoAll -EntityName "intersite-consulting"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$AllExpenses,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false,

    [Parameter()]
    [string]$EntityName,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = 4
$stepName = "Audit Warning Scan"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 4] WhatIf: would scan $($ZohoAll.Count) transactions for 10 warning patterns" -Tags PRP
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "WhatIf: audit warning scan skipped"
        NextSteps  = @("Run without -WhatIf to execute scan")
        Warnings   = @()
    }
}

$warnings = @()

# Warning 1: CC payments (type transfer_fund from chequing to CC) miscategorized as expenses
if ($ZohoAll) {
    $miscategorizedCC = $ZohoAll | Where-Object {
        $_.transaction_type -eq "transfer_fund" -and
        $_.description -match "CREDIT CARD" -or
        $_.description -match "ONLINE TRANSFER"
    }
    if ($miscategorizedCC -and $miscategorizedCC.Count -gt 0) {
        $warnings += @{
            Type     = "CC payment miscategorized"
            Count    = $miscategorizedCC.Count
            Detail   = "$($miscategorizedCC.Count) transfer_fund transaction(s) found"
            Severity = "warning"
            FixStrategy = "Find Online Banking Transfer + round amount, reclassify to Credit Card Payments via POST /banktransactions with transfer_fund"
            Txns     = @($miscategorizedCC.transaction_id)
        }
    }
}

# Warning 2: Negative balance expense accounts (refunds without matching purchases)
if ($AllExpenses) {
    $negativeBalances = $AllExpenses | Where-Object { $_.amount -lt 0 -or ($_.total -and $_.total -lt 0) }
    if ($negativeBalances -and $negativeBalances.Count -gt 0) {
        $warnings += @{
            Type     = "Negative balance expenses"
            Count    = $negativeBalances.Count
            Detail   = "$($negativeBalances.Count) negative amount expense(s)"
            Severity = "warning"
            FixStrategy = "Match refunds to original purchases, verify via PUT /expenses/{id}"
            Txns     = @($negativeBalances.expense_id)
        }
    }
}

# Warning 3: Shareholder Loan activity
if ($ZohoAll) {
    $shareholderLoanId = "93310000000000407"
    $slActivity = $ZohoAll | Where-Object { $_.account_id -eq $shareholderLoanId -or $_.from_account_id -eq $shareholderLoanId }
    if ($slActivity -and $slActivity.Count -gt 0) {
        $warnings += @{
            Type     = "Shareholder Loan activity"
            Count    = $slActivity.Count
            Detail   = "$($slActivity.Count) Shareholder Loan transaction(s) — net should be $0"
            Severity = "info"
            FixStrategy = "Verify net Shareholder Loan activity = $0; create journal entry if not"
            Txns     = @($slActivity.transaction_id)
        }
    }
}

# Warning 4: Cross-entity contamination
if ($ZohoAll -and $EntityName) {
    $otherEntityPatterns = @{
        "intersite-consulting" = @("TMH", "MLM", "FRA")
        "room-rentals"         = @("INTERSITE", "BUSINESS")
    }
    $patterns = $otherEntityPatterns[$EntityName]
    if ($patterns) {
        $crossEntity = $ZohoAll | Where-Object {
            $desc = $_.description -or ""
            ($patterns | Where-Object { $desc -match $_ }).Count -gt 0
        }
        if ($crossEntity -and $crossEntity.Count -gt 0) {
            $warnings += @{
                Type     = "Cross-entity contamination"
                Count    = $crossEntity.Count
                Detail   = "$($crossEntity.Count) transaction(s) may belong to a different entity"
                Severity = "error"
                FixStrategy = "Move property expenses Intersite ↔ Room Rentals via PUT /expenses/{id} or journal entry"
                Txns     = @($crossEntity.transaction_id)
            }
        }
    }
}

# Warning 5: Other Expenses drain (catch-all overuse)
$otherExpensesId = "93310000000000409"
if ($AllExpenses) {
    $otherExpensesTxns = $AllExpenses | Where-Object { $_.account_id -eq $otherExpensesId }
    if ($otherExpensesTxns -and $otherExpensesTxns.Count -gt 3) {
        $warnings += @{
            Type     = "Other Expenses drain"
            Count    = $otherExpensesTxns.Count
            Detail   = "$($otherExpensesTxns.Count) transaction(s) in Other Expenses catch-all"
            Severity = "warning"
            FixStrategy = "Check vendor against categorization-rules.json, PUT /expenses/{id} with corrected account_id"
            Txns     = @($otherExpensesTxns.expense_id)
        }
    }
}

# Warning 6: Duplicate transactions (same date, amount, vendor)
if ($ZohoAll) {
    $dupGroups = $ZohoAll | Group-Object { "$($_.date)|$([math]::Abs($_.amount))|$($_.description)" }
    $duplicates = $dupGroups | Where-Object { $_.Count -gt 1 }
    if ($duplicates -and $duplicates.Count -gt 0) {
        $warnings += @{
            Type     = "Duplicate transactions"
            Count    = ($duplicates | ForEach-Object Count | Measure-Object -Sum).Sum
            Detail   = "$($duplicates.Count) group(s) of potential duplicates"
            Severity = "warning"
            FixStrategy = "Verify and remove duplicates via DELETE /banktransactions/{id}"
            Txns     = @()
        }
    }
}

# Warning 7: Missing receipts (expenses without attachments)
if ($AllExpenses) {
    $missingReceipts = $AllExpenses | Where-Object { -not $_.has_attachment }
    if ($missingReceipts -and $missingReceipts.Count -gt 0) {
        $warnings += @{
            Type     = "Missing receipts"
            Count    = $missingReceipts.Count
            Detail   = "$($missingReceipts.Count) expense(s) without attachment"
            Severity = "info"
            FixStrategy = "Accept if category is reasonable — document in notes; upload receipts if available"
            Txns     = @($missingReceipts.expense_id)
        }
    }
}

# Warning 8: Large round amounts (potential CC payments)
if ($ZohoAll) {
    $roundAmounts = $ZohoAll | Where-Object {
        $_.amount -gt 100 -and $_.amount -eq [math]::Round($_.amount, 0) -and
        $_.transaction_type -eq "debit" -and
        $_.description -notmatch "TRANSFER"
    }
    if ($roundAmounts -and $roundAmounts.Count -gt 0) {
        $warnings += @{
            Type     = "Large round amounts"
            Count    = $roundAmounts.Count
            Detail   = "$($roundAmounts.Count) debit(s) with round amounts > $100 — possible miscategorized CC payments"
            Severity = "info"
            FixStrategy = "Review each: if CC payment, reclassify to Credit Card Payments"
            Txns     = @($roundAmounts.transaction_id)
        }
    }
}

# Warning 9: Period boundary orphan transactions
if ($ZohoAll) {
    $boundaryOrphans = $ZohoAll | Where-Object {
        $day = if ($_.date -is [datetime]) { $_.date.Day } else { [datetime]::Parse($_.date).Day }
        $day -le 3 -or $day -ge 28
    }
    if ($boundaryOrphans -and $boundaryOrphans.Count -gt 0) {
        $warnings += @{
            Type     = "Period boundary orphans"
            Count    = $boundaryOrphans.Count
            Detail   = "$($boundaryOrphans.Count) transaction(s) near period boundaries (±3 days)"
            Severity = "info"
            FixStrategy = "Verify they belong to the correct period; ±2 day tolerance already applied in Step 2"
            Txns     = @($boundaryOrphans.transaction_id)
        }
    }
}

# Warning 10: Uncategorized expenses with high amounts
if ($ZohoAll) {
    $highUncat = $ZohoAll | Where-Object {
        ($_.status -eq "uncategorized" -or -not $_.account_id) -and
        $_.amount -gt 500
    }
    if ($highUncat -and $highUncat.Count -gt 0) {
        $warnings += @{
            Type     = "High-value uncategorized"
            Count    = $highUncat.Count
            Detail   = "$($highUncat.Count) uncategorized transaction(s) over $500"
            Severity = "warning"
            FixStrategy = "Categorize urgently — high-value items affect balance forward accuracy"
            Txns     = @($highUncat.transaction_id)
        }
    }
}

$passed = ($warnings.Count -eq 0)
$detail = "$($warnings.Count) warning pattern(s) found"

if ($passed) {
    Write-Information "[PRP STEP 4] PASSED — No warning patterns detected" -Tags PRP
} else {
    Write-Warning "[PRP STEP 4] FAILED — $($warnings.Count) warning pattern(s)"
    foreach ($w in $warnings) {
        Write-Warning "  [$($w.Severity)] $($w.Type): $($w.Detail)"
        Write-Warning "    Fix: $($w.FixStrategy)"
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber       = $stepNumber
    Passed           = $passed
    Details          = $detail
    Warnings         = $warnings
    IsPlaidImmutable = $IsPlaidImmutable
    NextSteps        = @(
        $(if ($passed) { "Proceed to Step 5: Balance Forward Verification" }
          elseif ($IsPlaidImmutable) { "Append warnings to remediation report for Zoho UI processing" }
          else { "Execute fix strategies via API using cached token, re-fetch, re-run Step 4" })
    )
}
