<#
.SYNOPSIS
    Classifies a bank credit as Income, Transfer, or Exclude — income-aware wrapper around Get-AccountIdFromRules.
.DESCRIPTION
    Credits (money in) are not all income. This function applies the `income_rules` array from
    categorization-rules.json to determine the classification and Zoho posting mechanism:
      - Income → POST /banktransactions type=deposit (links income account → bank account)
      - Transfer → POST /banktransactions type=transfer (links liability → bank)
      - Exclude → route to Exclude account (no P&L impact)
      - Expense → unusual for credits, but matched by generic rules (e.g. refund routed to same expense)
    Returns a structured result with income_type, account_name, account_id, rule_source, confidence,
    and auto_categorised.
.PARAMETER Vendor
    Payee/vendor name from bank CSV (Description 1 + Description 2).
.PARAMETER Description
    Additional transaction notes or memo.
.PARAMETER Amount
    Numeric amount (positive for credits). Used to detect round-amount transfers.
.PARAMETER EntitySlug
    Entity identifier: "intersite-consulting" or "room-rentals".
.PARAMETER RulesPath
    Optional path to categorization-rules.json for testability.
.EXAMPLE
    Get-IncomeClassification -Vendor "WAVE SV9T" -Amount 850.00
    Returns: income_type=Income, account_name=Consulting Revenue, account_id=93310000000149102, auto_categorised=$true
.EXAMPLE
    Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Amount 500.00
    Returns: income_type=Transfer, account_name=Credit Card Payments, account_id=93310000000300002, auto_categorised=$false
#>
function Get-IncomeClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Vendor,

        [string]$Description,

        [double]$Amount = 0,

        [string]$EntitySlug = "intersite-consulting",

        [string]$RulesPath
    )

    $vendorUpper = $Vendor.ToUpperInvariant()
    $searchText = $Vendor
    if ($Description) { $searchText += " $Description" }
    $searchUpper = $searchText.ToUpperInvariant()

    $result = [PSCustomObject]@{
        account_name     = $null
        account_id       = $null
        income_type      = $null
        rule_source      = $null
        matched_pattern  = $null
        confidence       = "low"
        auto_categorised = $false
    }

    function Set-Result($acctName, $acctId, $type, $source, $pattern, $confidence) {
        $result.account_name = $acctName
        $result.account_id   = $acctId
        $result.income_type  = $type
        $result.rule_source  = $source
        $result.matched_pattern = $pattern
        $result.confidence   = $confidence
        $result.auto_categorised = ($confidence -eq "high")
    }

    # === Phase 1: Data-driven income rule matching from JSON ===
    if (-not $RulesPath) {
        $scriptDir = Split-Path $PSCommandPath -Parent
        $repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..\..")
        $RulesPath = Join-Path $repoRoot "Skills\Bookkeeping\tx-categorization\categorization-rules.json"
    }

    if (Test-Path $RulesPath) {
        $rules = (Get-Content $RulesPath -Raw | ConvertFrom-Json).income_rules
        if ($rules) {
            $sortedRules = $rules | Sort-Object priority

            foreach ($rule in $sortedRules) {
                # Entity filtering — only match rules whose entities include the current entity
                if ($rule.PSObject.Properties.Name -contains 'entities' -and $rule.entities) {
                    $ruleEntities = @($rule.entities)
                    if ($ruleEntities -notcontains $EntitySlug) { continue }
                }
                if ($searchUpper -match $rule.pattern) {
                    $amountMatch = $true
                    if ($rule.PSObject.Properties.Name -contains 'amount_min' -and $rule.amount_min -gt 0) {
                        if ($Amount -lt $rule.amount_min) { $amountMatch = $false }
                    }
                    if ($rule.PSObject.Properties.Name -contains 'amount_max' -and $rule.amount_max -gt 0) {
                        if ($Amount -gt $rule.amount_max) { $amountMatch = $false }
                    }
                    if ($rule.PSObject.Properties.Name -contains 'amount_round_only' -and $rule.amount_round_only) {
                        $isRound = [math]::Abs($Amount - [math]::Round($Amount)) -lt 0.01
                        if (-not $isRound) { $amountMatch = $false }
                    }

                    if ($amountMatch) {
                        $ruleConfidence = if ($rule.PSObject.Properties.Name -contains 'confidence') { $rule.confidence } else { "medium" }
                        Set-Result $rule.account_name $rule.account_id $rule.income_type "income_rules" $rule.pattern $ruleConfidence
                        return $result
                    }
                }
            }
        }
    }

    # === Phase 2: Delegate to Get-AccountIdFromRules for generic classification ===
    $scriptDir2 = Split-Path $PSCommandPath -Parent
    . (Join-Path $scriptDir2 "Get-AccountIdFromRules.ps1")

    $baseResult = Get-AccountIdFromRules -Vendor $Vendor -Description $Description -EntitySlug $EntitySlug -PassThru

    $result.account_name = $baseResult.account_name
    $result.account_id   = $baseResult.account_id
    $result.rule_source  = $baseResult.rule_source
    $result.matched_pattern = $baseResult.matched_pattern

    # === Phase 3: Determine income_type from the matched account ===
    $incomeAccountNames = @("Consulting Revenue", "Rent Revenue", "Interest Income")
    $transferAccountNames = @("Shareholder Loan", "Dividends Paid", "Credit Card Payments", "Credit Card Charges")
    $excludeAccountNames = @("Exclude", "Income Tax Expense")

    $acctName = if ($result.account_name) { $result.account_name.Trim() } else { "" }

    if ($incomeAccountNames -contains $acctName) {
        $result.income_type = "Income"
    } elseif ($transferAccountNames -contains $acctName) {
        $result.income_type = "Transfer"
    } elseif ($excludeAccountNames -contains $acctName) {
        $result.income_type = "Exclude"
    } elseif ($result.rule_source -eq "catch-all") {
        $result.income_type = "Review"
        $result.confidence = "low"
        $result.auto_categorised = $false
    } else {
        $result.income_type = "Expense"
        $result.confidence = "low"
        $result.auto_categorised = $false
    }

    return $result
}
