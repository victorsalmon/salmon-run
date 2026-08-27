<#
.SYNOPSIS
    PRP Step 9: Post-recon categorization audit (quality gate).
.DESCRIPTION
    Scans the local Zoho dataset for uncategorized transactions and
    catch-all account usage (Other Expenses, Exclude). Returns counts
    of uncategorized and catch-all categorized items.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions array.
.PARAMETER UncatTxns
    Uncategorized banktransactions from bulk fetch.
.PARAMETER AllExpenses
    All expenses from bulk fetch (for catch-all checking).
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (affects remediation).
.PARAMETER OtherExpensesId
    Account ID for "Other Expenses" catch-all (default: 93310000000000409).
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
    Invoke-PrpStep9-CategorizationAudit.ps1 -ZohoAll $zohoAll -UncatTxns $uncatTxns
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$UncatTxns,

    [Parameter()]
    [array]$AllExpenses,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false,

    [Parameter()]
    [string]$OtherExpensesId = "93310000000000409",

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId
)

$ErrorActionPreference = "Stop"
$stepNumber = 9
$stepName = "Categorization Audit"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 9] WhatIf: would scan $($ZohoAll.Count) transactions for categorization issues" -Tags PRP
    return [PSCustomObject]@{
        StepNumber        = $stepNumber
        Passed            = $true
        Details           = "WhatIf: categorization audit skipped"
        NextSteps         = @("Run without -WhatIf to execute audit")
        UncategorizedCount = 0
        CatchAllCount     = 0
        CatchAllTxns      = @()
    }
}

$uncategorizedCount = 0
$catchAllCount = 0
$catchAllTxns = @()

if ($UncatTxns -and $UncatTxns.Count -gt 0) {
    $uncategorizedCount = $UncatTxns.Count
}

if ($AllExpenses -and $AllExpenses.Count -gt 0) {
    $catchAllTxns = $AllExpenses | Where-Object { $_.account_id -eq $OtherExpensesId }
    $catchAllCount = $catchAllTxns.Count
}

$passed = ($uncategorizedCount -eq 0 -and $catchAllCount -eq 0)
$detail = "Uncategorized: $uncategorizedCount, In catch-all: $catchAllCount"

if ($passed) {
    Write-Information "[PRP STEP 9] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 9] FAILED — $detail"
    if ($uncategorizedCount -gt 0) {
        Write-Warning "  $uncategorizedCount transaction(s) are uncategorized"
    }
    if ($catchAllCount -gt 0) {
        Write-Warning "  $catchAllCount transaction(s) are in catch-all accounts"
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber        = $stepNumber
    Passed            = $passed
    Details           = $detail
    UncategorizedCount = $uncategorizedCount
    CatchAllCount     = $catchAllCount
    CatchAllTxns      = $catchAllTxns
    IsPlaidImmutable  = $IsPlaidImmutable
    NextSteps         = @(
        $(if ($passed) { "Proceed to Step 10: Manual Category Reasonableness Checks" }
          elseif ($IsPlaidImmutable) { "Record uncategorized/catch-all items in remediation report for Zoho UI" }
          else { "Categorize via API using cached token, re-fetch, re-run Step 9" })
    )
}
