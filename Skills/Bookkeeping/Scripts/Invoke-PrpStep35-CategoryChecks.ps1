<#
.DEPRECATED
    Renamed to Invoke-PrpStep10-CategoryChecks.ps1 (PRP reorder). This file
    kept for backward compatibility. All new calls should use the new name.
.SYNOPSIS
    DEPRECATED — PRP Step 3.5: Manual Category Reasonableness Checks.
.DESCRIPTION
    Runs the 5 rubric checks from the legacy pipeline against the categorized
    dataset: category proportion, vendor fit, CC payments in expenses, sparse
    categories, and credit card charges. Returns flagged categories.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions array (post-categorization).
.PARAMETER AllExpenses
    All expenses from bulk fetch (for category analysis).
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (affects remediation).
.PARAMETER VendorMap
    Optional hashtable mapping vendor patterns to expected categories.
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
    Invoke-PrpStep35-CategoryChecks.ps1 -ZohoAll $zohoAll -AllExpenses $allExpenses
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
    [string]$OtherExpensesId = "93310000000000409",

    [Parameter()]
    [string]$ExcludeId = "93310000000000410",

    [Parameter()]
    [hashtable]$VendorMap,

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
$stepNumber = "3.5"
$stepName = "Category Reasonableness Checks"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 3.5] WhatIf: would run 5 rubric checks on categorized dataset" -Tags PRP
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $true
        Details        = "WhatIf: category checks skipped"
        NextSteps      = @("Run without -WhatIf to execute checks")
        FlaggedIssues  = @()
    }
}

$flaggedIssues = @()
$totalExpenses = if ($AllExpenses) { $AllExpenses.Count } else { 0 }

# Check 1: Category proportion — no account > 20% of total expenses
if ($AllExpenses -and $AllExpenses.Count -gt 0) {
    $catchAllIds = @($OtherExpensesId) + @($ExcludeId)
    $categoryGroups = $AllExpenses | Group-Object account_id
    $threshold = [math]::Max([int]($totalExpenses * 0.2), 1)
    foreach ($group in $categoryGroups) {
        if ($group.Count -gt $threshold -and $group.Name -notin $catchAllIds) {
            $flaggedIssues += @{
                Check   = 1
                Issue   = "Category proportion"
                Detail  = "Account $($group.Name) has $($group.Count) transactions ($([math]::Round($group.Count / $totalExpenses * 100, 1))%) — exceeds 20% threshold"
                Severity = "warning"
            }
        }
    }
}

# Check 2: Vendor fit — detect common mismatches
if ($AllExpenses -and $VendorMap) {
    foreach ($expense in $AllExpenses) {
        foreach ($entry in $VendorMap.GetEnumerator()) {
            if ($expense.description -match $entry.Key -and $expense.account_id -ne $entry.Value) {
                $flaggedIssues += @{
                    Check   = 2
                    Issue   = "Vendor fit"
                    Detail  = "Transaction '$($expense.description)' matched pattern '$($entry.Key)' but categorized to account $($expense.account_id), expected $($entry.Value)"
                    Severity = "warning"
                }
            }
        }
    }
}

# Check 3: CC payments in expenses
if ($ZohoAll) {
    $ccPayments = $ZohoAll | Where-Object {
        ($_.description -match "Online Banking Transfer" -or $_.description -match "CREDIT CARD PAYMENT") -and
        $_.amount -eq [math]::Round($_.amount, 0) -and
        $_.transaction_type -eq "debit" -and
        $_.amount -gt 0
    }
    if ($ccPayments -and $ccPayments.Count -gt 0) {
        $flaggedIssues += @{
            Check   = 3
            Issue   = "CC payments in expenses"
            Detail  = "$($ccPayments.Count) round-amount Online Banking Transfer(s) found in expense accounts — should be in Credit Card Payments"
            Severity = "error"
            Txns     = @($ccPayments.transaction_id)
        }
    }
}

# Check 4: Sparse categories
if ($AllExpenses -and $AllExpenses.Count -gt 0) {
    $categoryCounts = $AllExpenses | Group-Object account_id | Where-Object { $_.Count -le 2 }
    foreach ($group in $categoryCounts) {
        $flaggedIssues += @{
            Check   = 4
            Issue   = "Sparse categories"
            Detail  = "Account $($group.Name) has only $($group.Count) transaction(s) — consider merging into an existing category"
            Severity = "info"
        }
    }
}

# Check 5: Credit Card Charges must be $0
$ccChargesId = "93310000000000413"  # Typical Credit Card Charges account ID
if ($AllExpenses) {
    $ccCharges = $AllExpenses | Where-Object { $_.account_id -eq $ccChargesId -and $_.amount -ne 0 }
    if ($ccCharges -and $ccCharges.Count -gt 0) {
        $flaggedIssues += @{
            Check   = 5
            Issue   = "Credit Card Charges"
            Detail  = "$($ccCharges.Count) non-zero transactions in Credit Card Charges ($([math]::Round(($ccCharges | Measure-Object amount -Sum).Sum, 2))) — should be $0"
            Severity = "error"
        }
    }
}

$passed = ($flaggedIssues.Count -eq 0)
$detail = "$($flaggedIssues.Count) issue(s) flagged"

if ($passed) {
    Write-Information "[PRP STEP 3.5] PASSED — All 5 rubric checks pass" -Tags PRP
} else {
    Write-Warning "[PRP STEP 3.5] FAILED — $($flaggedIssues.Count) issue(s) found"
    foreach ($issue in $flaggedIssues) {
        Write-Warning "  [$($issue.Severity)] Check $($issue.Check): $($issue.Detail)"
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber    = $stepNumber
    Passed        = $passed
    Details       = $detail
    FlaggedIssues = $flaggedIssues
    IsPlaidImmutable = $IsPlaidImmutable
    NextSteps     = @(
        $(if ($passed) { "Proceed to Step 4: Audit Warning Scan" }
          elseif ($IsPlaidImmutable) { "Add flagged issues to remediation report for Zoho UI processing" }
          else { "Fix flagged categories via PUT /expenses/{id} or journal entry, re-run Step 3.5" })
    )
}
