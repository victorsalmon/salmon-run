<#
.SYNOPSIS
    PRP Step 3: Categorization audit with active API categorization.
.DESCRIPTION
    If uncategorized transactions exist and the account is not Plaid-immutable,
    categorizes them via Zoho API using categorization-rules.json, then audits
    for remaining uncategorized and catch-all items.
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
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER RulesPath
    Path to categorization-rules.json. Auto-resolved if not provided.
.PARAMETER RepoRoot
    Repository root path. Auto-resolved via git if not provided.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep3-CategorizationAudit.ps1 -ZohoAll $zohoAll -UncatTxns $uncatTxns -OrgName "intersite-consulting"
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
    [string]$AccountId,

    [Parameter()]
    [string]$OrgName,

    [Parameter()]
    [string]$RulesPath,

    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = 3
$stepName = "Categorization Audit"

# Module-level throttle state for this step
$script:lastApiCallTime = [datetime]::MinValue
$script:apiErrorCount = 0
$script:circuitOpen = $false
$script:categorizeBatchCount = 0

function Invoke-ZohoApiWithThrottle {
    param([scriptblock]$ScriptBlock, [int]$MaxConsecutiveErrors = 3)
    if ($script:circuitOpen) {
        throw "[CIRCUIT BREAKER] Step 3 stopped after $($script:apiErrorCount) consecutive API errors."
    }
    $now = Get-Date
    if ($script:lastApiCallTime -ne [datetime]::MinValue) {
        $elapsed = ($now - $script:lastApiCallTime).TotalMilliseconds
        $minGap = 350
        if ($elapsed -lt $minGap) {
            Start-Sleep -Milliseconds ($minGap - $elapsed)
        }
    }
    try {
        $result = & $ScriptBlock
        $script:lastApiCallTime = Get-Date
        $script:apiErrorCount = 0
        return $result
    } catch {
        $script:lastApiCallTime = Get-Date
        $script:apiErrorCount++
        Write-Warning "[THROTTLE] API error #$($script:apiErrorCount) in Step 3 — $_"
        if ($script:apiErrorCount -ge $MaxConsecutiveErrors) {
            $script:circuitOpen = $true
            Write-Error "[CIRCUIT BREAKER] Step 3: $script:apiErrorCount consecutive errors — circuit opened"
        }
        throw
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 3] WhatIf: would scan $($ZohoAll.Count) transactions for categorization issues" -Tags PRP
    return [PSCustomObject]@{
        StepNumber         = $stepNumber
        Passed             = $true
        Details            = "WhatIf: categorization audit skipped"
        NextSteps          = @("Run without -WhatIf to execute audit")
        UncategorizedCount = 0
        CatchAllCount      = 0
        CatchAllTxns       = @()
    }
}

$entityFilter = @($OrgName)
if ($OrgName -match "intersite") {
    $entityFilter = @("intersite-consulting", "Intersite Consulting Inc.")
}

$categorizedCount = 0
$uncategorizableTxns = @()
$categorizationPerformed = $false

if ($UncatTxns -and $UncatTxns.Count -gt 0 -and -not $IsPlaidImmutable) {
    Write-Information "[PRP STEP 3] $($UncatTxns.Count) uncategorized transaction(s) found — executing API categorization" -Tags PRP

    if (-not $RulesPath) {
        if (-not $RepoRoot) {
            $RepoRoot = & git rev-parse --show-toplevel 2>$null
            if (-not $RepoRoot) { $RepoRoot = Resolve-Path "$PSScriptRoot/../../.." }
        }
        $RulesPath = Join-Path $RepoRoot "Skills/Bookkeeping/tx-categorization/categorization-rules.json"
    }

    if (-not (Test-Path $RulesPath)) {
        Write-Warning "[PRP STEP 3] categorization-rules.json not found at $RulesPath — skipping active categorization"
    } else {
        $rulesJson = Get-Content $RulesPath -Raw -Encoding utf8
        $rules = $rulesJson | ConvertFrom-Json
        $categorizationPerformed = $true

        foreach ($txn in $UncatTxns) {
            $description = if ($txn.description) { $txn.description } else { "" }
            $payee = if ($txn.payee) { $txn.payee } else { "" }
            $matched = $false

            foreach ($rule in $rules.income_rules) {
                $hasEntity = ($rule.entities | Where-Object { $_ -in $entityFilter }).Count -gt 0
                if (-not $hasEntity) { continue }
                if ($description -notmatch $rule.pattern -and $payee -notmatch $rule.pattern) { continue }

                $confidenceLevel = if ($rule.confidence -eq "high") { "HIGH" } elseif ($rule.confidence -eq "medium") { "MEDIUM" } else { "LOW" }

                if ($confidenceLevel -eq "LOW") {
                    Write-Information "[CATEGORIZE] txn $($txn.banktransaction_id): $description → $($rule.account_name) (confidence=LOW, rule=income_#$($rule.priority)) — skipping for manual review" -Tags PRP
                    $matched = $true
                    break
                }

                $uri = "https://www.zohoapis.com/books/v3/banktransactions/$($txn.banktransaction_id)?organization_id=$OrgId"
                $body = @{ account_id = $rule.account_id } | ConvertTo-Json -Compress
                try {
                    $null = Invoke-ZohoApiWithThrottle -ScriptBlock { Invoke-RestMethod -Uri $uri -Method Put -ContentType "application/json" -Headers $Headers -Body $body }
                    Write-Information "[CATEGORIZE] txn $($txn.banktransaction_id): $description → $($rule.account_name) (confidence=$confidenceLevel, rule=income_#$($rule.priority))" -Tags PRP
                    $categorizedCount++
                    $script:categorizeBatchCount++
                    if ($script:categorizeBatchCount % 10 -eq 0) {
                        Write-Information "[BATCH THROTTLE] $($script:categorizeBatchCount) categorizations — pausing 2s" -Tags PRP
                        Start-Sleep -Seconds 2
                    }
                } catch {
                    Write-Warning "[CATEGORIZE] FAILED txn $($txn.banktransaction_id): $_"
                }
                $matched = $true
                break
            }
            if ($matched) { continue }

            foreach ($rule in $rules.vendor_keyword_rules) {
                $hasEntity = ($rule.entities | Where-Object { $_ -in $entityFilter }).Count -gt 0
                if (-not $hasEntity) { continue }
                if ($payee -notmatch $rule.pattern -and $description -notmatch $rule.pattern) { continue }

                $uri = "https://www.zohoapis.com/books/v3/banktransactions/$($txn.banktransaction_id)?organization_id=$OrgId"
                $body = @{ account_id = $rule.account_id } | ConvertTo-Json -Compress
                try {
                    $null = Invoke-ZohoApiWithThrottle -ScriptBlock { Invoke-RestMethod -Uri $uri -Method Put -ContentType "application/json" -Headers $Headers -Body $body }
                    Write-Information "[CATEGORIZE] txn $($txn.banktransaction_id): $description → $($rule.account_name) (confidence=MEDIUM, rule=vendor_keyword)" -Tags PRP
                    $categorizedCount++
                    $script:categorizeBatchCount++
                    if ($script:categorizeBatchCount % 10 -eq 0) {
                        Write-Information "[BATCH THROTTLE] $($script:categorizeBatchCount) categorizations — pausing 2s" -Tags PRP
                        Start-Sleep -Seconds 2
                    }
                } catch {
                    Write-Warning "[CATEGORIZE] FAILED txn $($txn.banktransaction_id): $_"
                }
                $matched = $true
                break
            }
            if ($matched) { continue }

            $isAmazon = ($payee -match 'amazon' -or $description -match 'amazon')
            if ($isAmazon) {
                foreach ($rule in $rules.amazon_keyword_rules) {
                    $hasEntity = ($rule.entities | Where-Object { $_ -in $entityFilter }).Count -gt 0
                    if (-not $hasEntity) { continue }
                    if ($description -notmatch $rule.pattern) { continue }

                    Write-Information "[CATEGORIZE] txn $($txn.banktransaction_id): $description → $($rule.account_name) (confidence=LOW, rule=amazon_keyword) — skipping for manual review" -Tags PRP
                    $matched = $true
                    break
                }
            }

            if (-not $matched) {
                $uncategorizableTxns += $txn
            }
        }

        if ($categorizedCount -gt 0) {
            Write-Information "[PRP STEP 3] Categorized $categorizedCount transaction(s) via API" -Tags PRP
        }
        if ($uncategorizableTxns.Count -gt 0) {
            Write-Warning "[PRP STEP 3] $($uncategorizableTxns.Count) transaction(s) could not be auto-categorized — manual review needed"
        }
    }
} elseif ($UncatTxns -and $UncatTxns.Count -gt 0 -and $IsPlaidImmutable) {
    Write-Warning "[PRP STEP 3] $($UncatTxns.Count) uncategorized transaction(s) found but account is Plaid-immutable — no API categorization available"
    $uncategorizableTxns = $UncatTxns
}

$refreshUncatCount = $null
$freshUncatTxns = @()
if ($categorizationPerformed -and $categorizedCount -gt 0 -and $Token -and $OrgId -and $AccountId) {
    Write-Information "[PRP STEP 3] Re-fetching uncategorized transactions after API categorization..." -Tags PRP
    try {
        $uncatUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$AccountId&organization_id=$OrgId&status=uncategorized&per_page=200"
        $page = 1
        do {
            $resp = Invoke-ZohoApiWithThrottle -ScriptBlock { Invoke-RestMethod -Uri "${uncatUri}&page=${page}" -Headers $Headers }
            if ($resp.banktransactions) { $freshUncatTxns += $resp.banktransactions }
            $hasMore = if ($resp.page_context) { $resp.page_context.has_more_page } else { $false }
            $page++
        } while ($hasMore)
        $refreshUncatCount = $freshUncatTxns.Count
        Write-Information "[PRP STEP 3] After categorization: $refreshUncatCount uncategorized transaction(s) remaining" -Tags PRP
    } catch {
        Write-Warning "[PRP STEP 3] Re-fetch failed: $_ — using original uncategorized count"
    }
}

$uncategorizedCount = if ($refreshUncatCount -ne $null) { $refreshUncatCount } elseif ($UncatTxns) { $UncatTxns.Count } else { 0 }
$catchAllCount = 0
$catchAllTxns = @()

if ($AllExpenses -and $AllExpenses.Count -gt 0) {
    $catchAllTxns = $AllExpenses | Where-Object { $_.account_id -eq $OtherExpensesId }
    $catchAllCount = $catchAllTxns.Count
}

$detail = "Uncategorized: $uncategorizedCount, In catch-all: $catchAllCount"
if ($categorizedCount -gt 0) { $detail += " | Categorized via API: $categorizedCount" }
$passed = $false

if ($IsPlaidImmutable) {
    $passed = ($uncategorizedCount -eq 0 -and $catchAllCount -eq 0)
    if (-not $passed) {
        Write-Warning "[PRP STEP 3] Plaid-immutable account with $uncategorizedCount uncategorized / $catchAllCount catch-all — logging warning but passing"
        $passed = $true
    }
} elseif ($categorizationPerformed -and ($uncategorizableTxns.Count -gt 0 -or $uncategorizedCount -gt 0)) {
    $passed = ($uncategorizedCount -eq 0 -and $catchAllCount -eq 0)
    if (-not $passed -and $uncategorizableTxns.Count -gt 0) {
        $uncatIds = ($uncategorizableTxns | ForEach-Object { "$($_.banktransaction_id): $($_.description)" }) -join "; "
        $detail = "$uncategorizedCount uncategorized transactions could not be auto-categorized — manual review needed. Unmatched: $uncatIds"
        Write-Warning "[PRP STEP 3] FAILED — $detail"
    }
} else {
    $passed = ($uncategorizedCount -eq 0 -and $catchAllCount -eq 0)
}

if ($passed) {
    Write-Information "[PRP STEP 3] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 3] FAILED — $detail"
    if ($uncategorizedCount -gt 0) {
        Write-Warning "  $uncategorizedCount transaction(s) are uncategorized"
    }
    if ($catchAllCount -gt 0) {
        Write-Warning "  $catchAllCount transaction(s) are in catch-all accounts"
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber         = $stepNumber
    Passed             = $passed
    Details            = $detail
    UncategorizedCount = $uncategorizedCount
    CatchAllCount      = $catchAllCount
    CatchAllTxns       = $catchAllTxns
    IsPlaidImmutable   = $IsPlaidImmutable
    CategorizedViaApi  = $categorizedCount
    UnmatchedCount     = $uncategorizableTxns.Count
    UnmatchedTxns      = $uncategorizableTxns | ForEach-Object { @{ id = $_.banktransaction_id; description = $_.description } }
    NextSteps          = @(
        $(if ($passed) { "Proceed to Step 3.5: Manual Category Reasonableness Checks" }
          elseif ($IsPlaidImmutable) { "Record uncategorized/catch-all items in remediation report for Zoho UI" }
          elseif ($uncategorizableTxns.Count -gt 0) { "Manually categorize $($uncategorizableTxns.Count) unmatched transactions in Zoho UI, re-run Step 3" }
          else { "Categorize via API using cached token, re-fetch, re-run Step 3" })
    )
}
