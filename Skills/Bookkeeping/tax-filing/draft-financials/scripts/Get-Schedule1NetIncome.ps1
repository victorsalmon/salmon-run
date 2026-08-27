<#
    # Used by: Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-t2-filing.md
    # Also used by: Skills/Bookkeeping/tax-filing/draft-financials/scripts/Invoke-DraftT2Filing.ps1
.SYNOPSIS
    Computes T2 Schedule 1 (Net Income for Tax Purposes) from categorized transaction data.
.DESCRIPTION
    Reads either a manifest-enriched CSV or a P&L hashtable, maps each income/expense category
    to its GIFI line, and returns a structured Schedule 1 result.
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER ManifestCSV
    Path to a manifest-enriched.csv with columns: account_name, amount (debit positive).
.PARAMETER PandLData
    Alternative to CSV — hashtable keyed by account name with decimal amounts.
    E.g. @{ "Consulting Revenue" = 85000.00; "Advertising" = 1200.00 }
.PARAMETER MealsExpensesTotal
    Total meals & entertainment expenses for 50% add-back calculation (default 0).
.PARAMETER NonDeductibleItems
    Total non-deductible items like fines, penalties (default 0).
.PARAMETER CCADifference
    Difference between CCA claimed and Zoho depreciation (default 0 — set from Schedule 8).
.PARAMETER PersonalUsePercentages
    Hashtable of expense category → personal use percentage.
    E.g. @{ "Automobile" = 0.50 } adds back 50% of Automobile expense.
    Loaded from tax-year-YYYY.psd1 by default via orchestrator.
.EXAMPLE
    $s1 = .\Get-Schedule1NetIncome.ps1 -Config $cfg -ManifestCSV "C:\data\manifest-enriched.csv"
.EXAMPLE
    $s1 = .\Get-Schedule1NetIncome.ps1 -Config $cfg -PandLData $pl -MealsExpensesTotal 800
#>
function Get-Schedule1NetIncome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [string]$ManifestCSV,

        [hashtable]$PandLData,

        [decimal]$MealsExpensesTotal = 0,

        [decimal]$NonDeductibleItems = 0,

        [decimal]$CCADifference = 0,

        [hashtable]$PersonalUsePercentages = @{}
    )

    $result = [PSCustomObject]@{
        income = [PSCustomObject]@{
            consulting_revenue = 0.0
            interest_income    = 0.0
            total_revenue      = 0.0
            other_income       = 0.0
        }
        expenses = @{}
        total_expenses              = 0.0
        net_income_before_cca       = 0.0
        adjustments = [PSCustomObject]@{
            meals_add_back          = 0.0
            non_deductible          = 0.0
            cca_difference          = 0.0
            personal_use_add_back   = 0.0
            personal_use_detail     = @{}
            total_adjustments       = 0.0
        }
        net_income_for_tax_purposes = 0.0
        raw_accounts = @{}
    }

    function Load-FromCSV($path) {
        if (-not (Test-Path $path)) { throw "Manifest CSV not found: $path" }
        $ht = @{}
        Import-Csv $path | ForEach-Object {
            $acct = $_.account_name
            $amt = [decimal]$_.amount
            if ($ht.ContainsKey($acct)) { $ht[$acct] += $amt }
            else { $ht[$acct] = $amt }
        }
        return $ht
    }

    # --- Load data ---
    $accounts = if ($ManifestCSV) { Load-FromCSV $ManifestCSV } elseif ($PandLData) { $PandLData }
    else { throw "Provide either -ManifestCSV or -PandLData" }

    $result.raw_accounts = $accounts
    $matchedAccounts = @{}  # track which source accounts were matched
    $unmatchedAccounts = @{}  # track accounts in source that matched nothing

    # --- Map income ---
    $incomeMapping = @{
        "Consulting Revenue" = "consulting_revenue"
        "Interest Income"    = "interest_income"
    }

    function Get-MatchedSum($keys, $pattern, $data, $tracker) {
        $matched = $keys | Where-Object { $_ -match $pattern }
        foreach ($k in $matched) { $tracker[$k] = $true }
        return [decimal]($matched | ForEach-Object { $data[$_] } | Measure-Object -Sum).Sum
    }

    $result.income.consulting_revenue = Get-MatchedSum $accounts.Keys "Consulting Revenue" $accounts $matchedAccounts
    $result.income.interest_income    = Get-MatchedSum $accounts.Keys "Interest Income" $accounts $matchedAccounts
    $result.income.other_income       = $result.income.interest_income
    $result.income.total_revenue      = $result.income.consulting_revenue + $result.income.other_income

    # Warn if income accounts exist in source but matched nothing
    foreach ($k in $accounts.Keys) {
        if (-not $matchedAccounts.ContainsKey($k)) { $unmatchedAccounts[$k] = $accounts[$k] }
    }

    # --- Map expenses using GIFI config patterns ---
    $gifiExpenses = $Config.gifi.expenses
    foreach ($g in $gifiExpenses) {
        $pattern = $g.account
        $label   = $g.label
        $amt = Get-MatchedSum $accounts.Keys $pattern $accounts $matchedAccounts
        $result.expenses[$label] = $amt
        $result.total_expenses += $amt
    }

    # Warn on unmatched accounts (likely misnamed expense categories or missing GIFI mapping)
    $stillUnmatched = @{}
    foreach ($k in $accounts.Keys) {
        if (-not $matchedAccounts.ContainsKey($k)) { $stillUnmatched[$k] = $accounts[$k] }
    }
    if ($stillUnmatched.Count -gt 0) {
        $unmatchedStr = ($stillUnmatched.Keys | ForEach-Object { "$_ (`$$($stillUnmatched[$_]))" }) -join ", "
        Write-Warning "Accounts in data with no GIFI mapping: $unmatchedStr — these amounts were excluded from T2 totals."
    }

    $result.net_income_before_cca = $result.income.total_revenue - $result.total_expenses

    # --- Adjustments ---
    $result.adjustments.meals_add_back    = $MealsExpensesTotal * 0.5
    $result.adjustments.non_deductible    = $NonDeductibleItems
    $result.adjustments.cca_difference    = $CCADifference

    # Personal use add-backs (e.g., automobile personal use)
    $result.adjustments.personal_use_add_back = 0.0
    $result.adjustments.personal_use_detail = @{}
    foreach ($kv in $PersonalUsePercentages.GetEnumerator()) {
        $category = $kv.Key
        $pct = [double]$kv.Value
        # Find the expense amount for this category
        $gifiMatch = $Config.gifi.expenses | Where-Object { $_.label -match $category -or $category -match $_.label } | Select-Object -First 1
        $expLabel = if ($gifiMatch) { $gifiMatch.label } else { $category }
        $expAmt = if ($result.expenses.ContainsKey($expLabel)) { [decimal]$result.expenses[$expLabel] } else { 0.0 }
        if ($expAmt -gt 0) {
            $addBack = [math]::Round($expAmt * $pct, 2, [MidpointRounding]::AwayFromZero)
            $result.adjustments.personal_use_detail[$category] = @{ amount = $expAmt; pct = $pct; add_back = $addBack }
            $result.adjustments.personal_use_add_back += $addBack
        }
    }
    $result.adjustments.total_adjustments = $result.adjustments.meals_add_back + $result.adjustments.non_deductible + $result.adjustments.cca_difference + $result.adjustments.personal_use_add_back

    $result.net_income_for_tax_purposes = $result.net_income_before_cca + $result.adjustments.total_adjustments

    return $result
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-Schedule1NetIncome') {
    if (-not (Get-Command Get-DraftT2Config -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "Get-DraftT2Config.ps1") }
    $cfg = Get-DraftT2Config
    Get-Schedule1NetIncome -Config $cfg -PandLData @{ "Consulting Revenue" = 85000; "Advertising" = 1200 }
}

