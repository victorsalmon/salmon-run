<#
.SYNOPSIS
    PRP Step 0.5: Detect Plaid-imported transactions in the Zoho dataset.
.DESCRIPTION
    Analyzes the bulk-fetched Zoho dataset to determine if the account has
    Plaid-imported transactions (source = "statement_imported" or "feed_imported").
    Branches pipeline behavior based on Plaid immutability.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions and expenses array.
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
    Invoke-PrpStep05-PlaidDetection.ps1 -ZohoAll $zohoAll
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$ZohoAll,

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
$stepNumber = "0.5"
$stepName = "Plaid Detection"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if (-not $ZohoAll -or $ZohoAll.Count -eq 0) {
    Write-Warning "[PRP STEP 0.5] No Zoho dataset provided — cannot detect Plaid state"
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = "No Zoho dataset provided"
        NextSteps     = @("Run Step 0 (Token Acquisition) first to fetch data")
        IsPlaidImmutable = $false
        SourceGroups  = $null
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 0.5] WhatIf: would analyze $($ZohoAll.Count) transactions for Plaid source detection" -Tags PRP
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $true
        Details       = "WhatIf: Plaid detection skipped"
        NextSteps     = @("Run without -WhatIf to execute detection")
        IsPlaidImmutable = $false
        SourceGroups  = $null
    }
}

$sourceGroups = $ZohoAll | Group-Object {
    if ($_.source -eq "statement_imported" -or $_.source -eq "feed_imported") { "plaid" } else { "manual" }
}

$plaidGroup = $sourceGroups | Where-Object Name -eq "plaid"
$hasPlaidTxns = $plaidGroup -and $plaidGroup.Count -gt 0
$plaidCount = if ($hasPlaidTxns) { $plaidGroup.Count } else { 0 }
$manualGroup = $sourceGroups | Where-Object Name -eq "manual"
$manualCount = if ($manualGroup) { $manualGroup.Count } else { 0 }

if ($hasPlaidTxns) {
    Write-Warning "[PRP PLAID] Account has $plaidCount Plaid-imported transactions — API remediation will fail. Switching to report-only mode for Steps 2-4."
} else {
    Write-Information "[PRP PLAID] No Plaid transactions detected — API remediation is available" -Tags PRP
}

$detail = "Plaid-imported: $plaidCount, Manual: $manualCount — Account is $(
    if ($hasPlaidTxns) { "PLAID-IMMUTABLE" } else { "API-MUTABLE" }
)"

# ---- Plaid Dedup Phase: remove duplicate Plaid-imported transactions ----
$dedupedCount = 0
$dedupedIds = @()
$plaidTransactions = @()
if ($hasPlaidTxns -and $plaidGroup) {
    $plaidTransactions = @($plaidGroup.Group)
}

if ($plaidTransactions.Count -gt 1) {
    $dedupGroups = @{}
    foreach ($ptxn in $plaidTransactions) {
        $amt = [math]::Abs([double]($ptxn.amount))
        $p = if ($ptxn.payee) { $ptxn.payee.Trim() } else { ($ptxn.description -replace ',.*').Trim() }
        $dedupKey = "$($ptxn.date)|$amt|$p"
        if (-not $dedupGroups.ContainsKey($dedupKey)) {
            $dedupGroups[$dedupKey] = @()
        }
        $dedupGroups[$dedupKey] += $ptxn
    }

    $removedIds = @()
    $duplicatesRemoved = 0
    foreach ($key in $dedupGroups.Keys) {
        $group = $dedupGroups[$key]
        if ($group.Count -gt 1) {
            $sorted = $group | Sort-Object { if ($_.created_time) { $_.created_time } else { $_.createdTime } }
            $keep = $sorted[0]
            $toBeRemoved = $sorted[1..($sorted.Count - 1)]
            foreach ($rm in $toBeRemoved) {
                $rmId = if ($rm.transaction_id) { $rm.transaction_id } else { $rm.transactionId }
                if ($rmId) { $removedIds += $rmId }
                $duplicatesRemoved++
            }
        }
    }

    if ($duplicatesRemoved -gt 0) {
        $dedupedCount = $duplicatesRemoved
        $dedupedIds = $removedIds
        $dedupNote = " — Dedup removed $duplicatesRemoved Plaid duplicate(s)"
        Write-Warning "[PLAID DEDUP] Removed $duplicatesRemoved duplicate Plaid transaction(s) from analysis set — IDs: $($removedIds -join ', ')"
    } else {
        Write-Information "[PLAID DEDUP] No duplicate Plaid transactions detected" -Tags PRP
        $dedupNote = ""
    }
} else {
    Write-Information "[PLAID DEDUP] No Plaid transactions to dedup" -Tags PRP
    $dedupNote = ""
}

$detail += $dedupNote

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber       = $stepNumber
    Passed           = $true
    Details          = $detail
    IsPlaidImmutable = $hasPlaidTxns
    PlaidCount       = $plaidCount
    ManualCount      = $manualCount
    SourceGroups     = $sourceGroups
    DedupedCount     = $dedupedCount
    DedupedIds       = $dedupedIds
    NextSteps        = @(
        "Proceed to Step 0.5b: CR+DR Sweep",
        "Pipeline mode: $(if ($hasPlaidTxns) { 'report-only' } else { 'full API' })"
    )
}
