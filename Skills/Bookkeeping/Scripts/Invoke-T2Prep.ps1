<#
.SYNOPSIS
    Prepares T2 corporate tax schedules from reconciled TAS data for Intersite Consulting.
.DESCRIPTION
    Reads TAS-2026.csv ΓåÆ aggregates by category ΓåÆ maps to GIFI codes ΓåÆ generates Schedules 1, 3, 4, 8
    ΓåÆ computes tax payable ΓåÆ generates GST reconciliation. Outputs JSON + markdown worksheet.
.PARAMETER Organization
    Organization: intersite-consulting only (others may be added later).
.PARAMETER OutputDir
    Output directory for generated schedules (default: T2 subfolder in the org folder).
.PARAMETER PriorYearPath
    Path to prior year T2 JSON for variance comparison.
.PARAMETER PassThru
    Output the result object instead of writing files (for pipeline chaining).
.EXAMPLE
    .\Invoke-T2Prep.ps1 -Organization intersite-consulting
#>
[CmdletBinding()]
param(
    [ValidateSet('intersite-consulting')]
    [string]$Organization = 'intersite-consulting',

    [string]$OutputDir,

    [string]$PriorYearPath,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$Organization"
$tasPath = "$booksRoot\TAS-zoho-fy2026.csv"
if (-not (Test-Path $tasPath)) { $tasPath = "$booksRoot\TAS-2026.csv" }  # fallback for legacy name
$filingDir = "$booksRoot\2026 Filing\T2"
$defaultOutputDir = if ($OutputDir) { $OutputDir } else { $filingDir }
if (-not (Test-Path $defaultOutputDir)) { New-Item -ItemType Directory -Path $defaultOutputDir -Force | Out-Null }

# Prior year data (default from existing profile)
$defaultPriorYear = @{
    revenue        = 20771.00
    taxable_income = 15934.00
    tax_payable    = 1754.00
    sbd_claimed    = 3027.00
    cca_claimed    = 837.00
    net_income     = 15934.00
    dividends_paid = 13307.00
}

# ΓöÇΓöÇ GIFI Mapping ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
$gifiMap = @{
    'Consulting Revenue'           = @{ gifi = '8299'; type = 'income';  label = 'Gross Revenue' }
    'Interest Income'              = @{ gifi = '8231'; type = 'income';  label = 'Other Income' }
    'Advertising And Marketing'    = @{ gifi = '8520'; type = 'expense'; label = 'Advertising' }
    'Automobile Expense'           = @{ gifi = '8530'; type = 'expense'; label = 'Automobile' }
    'Bank Fees and Charges'        = @{ gifi = '8710'; type = 'expense'; label = 'Interest & Bank Charges' }
    'Credit Card Charges'          = @{ gifi = '8710'; type = 'expense'; label = 'Interest & Bank Charges' }
    'Insurance'                    = @{ gifi = '8620'; type = 'expense'; label = 'Insurance' }
    'Lease Expense'                = @{ gifi = '8720'; type = 'expense'; label = 'Lease' }
    'Office & General Expenses'    = @{ gifi = '8810'; type = 'expense'; label = 'Office & General' }
    'Professional Fees'            = @{ gifi = '8860'; type = 'expense'; label = 'Professional Fees' }
    'Repairs and Maintenance'      = @{ gifi = '8960'; type = 'expense'; label = 'Repairs & Maintenance' }
    'Software & IT Expenses'       = @{ gifi = '8810'; type = 'expense'; label = 'IT & Internet' }
    'Other Expenses'               = @{ gifi = '9275'; type = 'expense'; label = 'Other Expenses' }
}

# Categories NOT reportable as P&L items (equity, transfers, tax, balance sheet)
$excludeFromPandL = @(
    'Credit Card Payments', 'Intersite', 'Shareholder Loan',
    'Income Tax Expense', 'Corporate Income Tax Payable',
    'Intersite RBC Business Cash Back Mastercard'
)

# Reclassification rules: [source_category] ΓåÆ [target_category]
# These fix known miscategorizations that persist through the TAS pipeline.
# Upscale Havens are now correctly categorized in the Zoho TAS (TAS-2026.csv).
# Kept for backward compatibility if running against TAS-local-2026.csv.
$reclassifications = @{
    'Bank Fees and Charges' = @{
        match = { param($row) $row.description -match 'Upscale Havens' -and [decimal]::Parse($row.amount) -gt 0 }
        to    = 'Consulting Revenue'
    }
}

# ΓöÇΓöÇ Read & Parse TAS ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Read-TasData {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "TAS not found: $Path" }
    $raw = Get-Content $Path -Raw -Encoding utf8
    $lines = $raw -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
    if ($lines.Count -lt 2) { throw "TAS has no data rows" }
    $csvText = $lines -join "`r`n"
    return $csvText | ConvertFrom-Csv
}

# ΓöÇΓöÇ Aggregate by GIFI ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Get-GifiAggregation {
    param([array]$Rows)
    $income = @{}
    $expense = @{}
    $details = @{}

    foreach ($row in $Rows) {
        $cat = $row.category
        $amt = [decimal]::Parse($row.amount)

        # Apply reclassifications
        $actualCat = $cat
        if ($reclassifications.ContainsKey($cat)) {
            $rule = $reclassifications[$cat]
            if (& $rule.match $row) { $actualCat = $rule.to }
        }

        if ($actualCat -in $excludeFromPandL) { continue }
        if (-not $gifiMap.ContainsKey($actualCat)) { continue }

        $mapping = $gifiMap[$actualCat]
        $gifi = $mapping.gifi
        $label = $mapping.label

        if ($mapping.type -eq 'income') {
            if (-not $income.ContainsKey($gifi)) { $income[$gifi] = @{ label = $label; amount = 0.0; categories = @{} } }
            $income[$gifi].amount += $amt
            if (-not $income[$gifi].categories.ContainsKey($actualCat)) { $income[$gifi].categories[$actualCat] = 0.0 }
            $income[$gifi].categories[$actualCat] += $amt
        } else {
            if (-not $expense.ContainsKey($gifi)) { $expense[$gifi] = @{ label = $label; amount = 0.0; categories = @{} } }
            $expense[$gifi].amount += $amt
            if (-not $expense[$gifi].categories.ContainsKey($actualCat)) { $expense[$gifi].categories[$actualCat] = 0.0 }
            $expense[$gifi].categories[$actualCat] += $amt
        }

        $key = "$actualCat|$gifi"
        if (-not $details.ContainsKey($key)) { $details[$key] = @{ category = $actualCat; gifi = $gifi; count = 0; total = 0.0; reclassified = ($actualCat -ne $cat) } }
        $details[$key].count++
        $details[$key].total += $amt
    }

    return @{
        income  = $income
        expense = $expense
        details = $details
    }
}

# ΓöÇΓöÇ Compute GST ITCs ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Get-GstITCs {
    param([array]$Rows)
    # Canadian expenses (GST-applicable) ΓåÆ ITCs at 5/105
    # US digital, bank fees, insurance ΓåÆ exempt
    $gstCategories = @{
        'Software & IT Expenses'  = 'canadian'   # Freedom Mobile, Canadian SaaS
        'Freedom Mobile'          = 'canadian'
        'Office & General Expenses' = 'canadian' # Amazon.ca, Dollarama
        'Repairs and Maintenance' = 'canadian'   # Home Depot, Bugman
        'Advertising And Marketing' = 'us_digital' # Meta, Google
        'Automobile Expense'      = 'canadian'   # Fuel, repairs
        'Lease Expense'           = 'canadian'
        'Professional Fees'       = 'canadian'
        'Bank Fees and Charges'   = 'exempt'
        'Credit Card Charges'     = 'exempt'
        'Consulting Revenue'      = 'exempt'     # Income, not ITC
    }
    
    $totalExpenses = @{ canadian = 0.0; us_digital = 0.0; exempt = 0.0 }
    $byCategory = @{}
    foreach ($row in $Rows) {
        $cat = $row.category
        $amt = [decimal]::Parse($row.amount)
        if ($amt -ge 0) { continue } # only expenses
        $classification = if ($gstCategories.ContainsKey($cat)) { $gstCategories[$cat] } else { 'exempt' }
        $totalExpenses[$classification] += $amt
        if (-not $byCategory.ContainsKey($cat)) { $byCategory[$cat] = @{ total = 0.0; classification = $classification } }
        $byCategory[$cat].total += $amt
    }
    $itcs = [math]::Round((-1 * $totalExpenses.canadian / 105 * 5), 2)
    return @{
        itcs   = $itcs
        breakdown = @{
            canadian_total   = [math]::Round(-1 * $totalExpenses.canadian, 2)
            us_digital_total = [math]::Round(-1 * $totalExpenses.us_digital, 2)
            exempt_total     = [math]::Round(-1 * $totalExpenses.exempt, 2)
        }
        by_category = $byCategory
    }
}

# ΓöÇΓöÇ Build Schedules ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function New-Schedule1 {
    param([hashtable]$Agg)
    $totalRevenue = ($Agg.income.Values | Measure-Object amount -Sum).Sum
    $totalExpenses = ($Agg.expense.Values | Measure-Object amount -Sum).Sum
    $netIncomeBeforeCCA = [math]::Round($totalRevenue + $totalExpenses, 2)
    $expenseMap = @{}
    foreach ($kv in $Agg.expense.GetEnumerator()) {
        $expenseMap[$kv.Key] = @{ label = $kv.Value.label; amount = $kv.Value.amount }
    }
    return @{
        revenue_8299 = @{ label = 'Gross Revenue'; amount = [math]::Round($totalRevenue, 2) }
        other_income_8231 = @{ label = 'Other Income'; amount = 0.0 }
        expenses = $expenseMap
        total_expenses = [math]::Round(-1 * $totalExpenses, 2)
        net_income_before_cca = $netIncomeBeforeCCA
        net_income_for_tax_purposes = $netIncomeBeforeCCA
        gst_collected = [math]::Round($totalRevenue / 105 * 5, 2)  # 5/105 of gross deposits
    }
}

function New-Schedule8 {
    param()
    return @{
        classes = @(
            @{ class = 8;  rate = 0.20; opening_ucc = 0.0; additions = 0.0; disposals = 0.0; cca_claimed = 0.0; closing_ucc = 0.0 }
            @{ class = 10; rate = 0.30; opening_ucc = 0.0; additions = 0.0; disposals = 0.0; cca_claimed = 0.0; closing_ucc = 0.0 }
            @{ class = 50; rate = 0.55; opening_ucc = 0.0; additions = 0.0; disposals = 0.0; cca_claimed = 0.0; closing_ucc = 0.0 }
            @{ class = 12; rate = 1.00; opening_ucc = 0.0; additions = 0.0; disposals = 0.0; cca_claimed = 0.0; closing_ucc = 0.0 }
        )
        total_cca_claimed = 0.0
    }
}

function New-Schedule3 {
    param()
    return @{
        opening_balance = 0.0
        advances_during_year = 0.0  # Converted to dividend at FYE ΓÇö no outstanding SHL
        repayments_during_year = 0.0
        closing_balance = 0.0
        non_eligible_dividends = 5959.36  # $1,959.36 (existing) + $4,000 (SHL reclassed as dividend at FYE)
    }
}

function New-Schedule4 {
    param([double]$NetIncome)
    $abi = [math]::Max(0.0, $NetIncome)
    $businessLimit = 500000.0
    $sbdFederal = [math]::Round([math]::Min($abi, $businessLimit) * 0.19, 2)
    $sbdBC = [math]::Round([math]::Min($abi, $businessLimit) * 0.10, 2)
    return @{
        active_business_income = $abi
        aggregate_investment_income = 0.0
        business_limit_federal = $businessLimit
        business_limit_bc = $businessLimit
        sbd_federal_reduction = $sbdFederal
        sbd_provincial_reduction = $sbdBC
        business_limit_used = [math]::Min($abi, $businessLimit)
    }
}

function New-TaxEstimate {
    param([double]$NetIncome, [hashtable]$S4)
    $abi = [math]::Max(0.0, $NetIncome)
    $federalRate = 0.28
    $bcRate = 0.12
    $partITaxBeforeSBD = [math]::Round($abi * $federalRate, 2)
    $bcTaxBeforeSBD = [math]::Round($abi * $bcRate, 2)
    $partITaxAfterSBD = [math]::Round($partITaxBeforeSBD - $S4.sbd_federal_reduction, 2)
    $bcTaxAfterSBD = [math]::Round($bcTaxBeforeSBD - $S4.sbd_provincial_reduction, 2)
    $totalTax = [math]::Max(0.0, [math]::Round($partITaxAfterSBD + $bcTaxAfterSBD, 2))
    return @{
        federal_part_i_rate_before_sbd = $federalRate
        bc_general_rate = $bcRate
        part_i_tax_before_sbd = $partITaxBeforeSBD
        sbd_reduction_federal = $S4.sbd_federal_reduction
        part_i_tax_after_sbd = $partITaxAfterSBD
        bc_tax_before_sbd = $bcTaxBeforeSBD
        sbd_reduction_bc = $S4.sbd_provincial_reduction
        bc_tax_after_sbd = $bcTaxAfterSBD
        total_tax_payable = $totalTax
        instalments_paid = 0.0
        estimated_refund_balance_owing = [math]::Round(-1 * $totalTax, 2)
    }
}

function New-GstReconciliation {
    param([double]$GrossRevenue, [hashtable]$GstData)
    # GST = 5/105 of gross deposits (deposits include 5% GST)
    $gstCollected = [math]::Round($GrossRevenue / 105 * 5, 2)
    return @{
        gst_collected = $gstCollected
        itcs_claimed = $GstData.itcs
        net_gst_remittable = [math]::Round($gstCollected - $GstData.itcs, 2)
        gst_payable_balance_sheet = 0.0
        revenue_net_of_gst = [math]::Round($GrossRevenue - $gstCollected, 2)
    }
}

function New-PriorYearComparison {
    param(
        [double]$Revenue,
        [double]$NetIncome,
        [double]$TaxPayable,
        [double]$SbdClaimed,
        [double]$CcaClaimed,
        [double]$DividendsPaid,
        [hashtable]$PriorYear
    )
    function Get-PctChange { param($cur, $prev) if ($prev -eq 0) { return 0.0 }; return [math]::Round([math]::Abs(($cur - $prev) / $prev), 4) }
    $flags = @()
    $netIncPct = Get-PctChange $NetIncome $PriorYear.net_income
    if ($netIncPct -gt 0.5) {
        $flags += "net_income: $( [math]::Round($netIncPct * 100) )% change from prior year (threshold: 50%)"
    }
    $taxPct = Get-PctChange $TaxPayable $PriorYear.tax_payable
    if ($taxPct -gt 0.5) {
        $flags += "tax_payable: $( [math]::Round($taxPct * 100) )% change from prior year (threshold: 50%)"
    }
    return @{
        current_revenue = [math]::Round($Revenue, 2)
        prior_revenue = $PriorYear.revenue
        revenue_variance_pct = [math]::Round(($Revenue - $PriorYear.revenue) / $PriorYear.revenue, 4)
        current_net_income = $NetIncome
        prior_net_income = $PriorYear.net_income
        net_income_variance_pct = [math]::Round(($NetIncome - $PriorYear.net_income) / $PriorYear.net_income, 4)
        current_tax_payable = $TaxPayable
        prior_tax_payable = $PriorYear.tax_payable
        current_sbd_claimed = $SbdClaimed
        current_cca_claimed = $CcaClaimed
        current_dividends_paid = $DividendsPaid
        variance_flags = $flags
    }
}

# ΓöÇΓöÇ Format output ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function ConvertTo-MarkdownWorksheet {
    param([hashtable]$Result)
    $s1 = $Result.schedule_1
    $s8 = $Result.schedule_8
    $s3 = $Result.schedule_3
    $s4 = $Result.schedule_4
    $tx = $Result.tax_estimate
    $gs = $Result.gst_reconciliation
    $pv = $Result.prior_year_comparison
    $recls = $Result.reclassifications_applied

    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.AppendLine("# Draft T2 Filing Worksheet")
    $null = $sb.AppendLine("**Intersite Consulting Inc.** ΓÇö FY Ending 2026-03-31")
    $null = $sb.AppendLine("*Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')*")
    $null = $sb.AppendLine("*Data Source: TAS-2026.csv (reconciled)*")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("")

    # Summary
    $netIncome = $s1.net_income_for_tax_purposes
    $null = $sb.AppendLine("## Summary")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Item | Amount |")
    $null = $sb.AppendLine("|------|--------|")
    $null = $sb.AppendLine("| Revenue | $( [string]::Format('{0:N2}', $s1.revenue_8299.amount) ) |")
    $null = $sb.AppendLine("| Total Expenses | $( [string]::Format('{0:N2}', $s1.total_expenses) ) |")
    $null = $sb.AppendLine("| Net Income (before CCA) | $( [string]::Format('{0:N2}', $s1.net_income_before_cca) ) |")
    $null = $sb.AppendLine("| CCA Claimed | $( [string]::Format('{0:N2}', $s8.total_cca_claimed) ) |")
    $null = $sb.AppendLine("| Net Income for Tax Purposes | $( [string]::Format('{0:N2}', $s1.net_income_for_tax_purposes) ) |")
    $null = $sb.AppendLine("| Taxable Income (ABI) | $( [string]::Format('{0:N2}', $s4.active_business_income) ) |")
    $null = $sb.AppendLine("| SBD Claimed (Fed + BC) | $( [string]::Format('{0:N2}', ($s4.sbd_federal_reduction + $s4.sbd_provincial_reduction)) ) |")
    $null = $sb.AppendLine("| Tax Payable | $( [string]::Format('{0:N2}', $tx.total_tax_payable) ) |")
    $null = $sb.AppendLine("| Instalments Paid | $( [string]::Format('{0:N2}', $tx.instalments_paid) ) |")
    $null = $sb.AppendLine("| Est. Refund / (Owing) | $( [string]::Format('{0:N2}', $tx.estimated_refund_balance_owing) ) |")
    if ($s3.non_eligible_dividends -ne 0) { $null = $sb.AppendLine("| Dividends Paid | $( [string]::Format('{0:N2}', $s3.non_eligible_dividends) ) |") }
    $null = $sb.AppendLine("")

    # Reclassification notes
    if ($recls.Count -gt 0) {
        $null = $sb.AppendLine("### Reclassifications Applied")
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("| Source Category | Reclassified To | Count | Total Amount |")
        $null = $sb.AppendLine("|----------------|-----------------|-------|-------------|")
        foreach ($r in $recls) {
            $null = $sb.AppendLine("| $($r.from) | $($r.to) | $($r.count) | $( [string]::Format('{0:N2}', $r.total) ) |")
        }
        $null = $sb.AppendLine("")
    }

    # Schedule 1
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Schedule 1 ΓÇö Net Income (for Tax Purposes)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("### Income")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Source | Amount | GIFI Line |")
    $null = $sb.AppendLine("|--------|--------|-----------|")
    $null = $sb.AppendLine("| $($s1.revenue_8299.label) | $( [string]::Format('{0:N2}', $s1.revenue_8299.amount) ) | 8299 |")
    $null = $sb.AppendLine("| $($s1.other_income_8231.label) | $( [string]::Format('{0:N2}', $s1.other_income_8231.amount) ) | 8231 |")
    $null = $sb.AppendLine("| **Total Revenue** | **$( [string]::Format('{0:N2}', $s1.revenue_8299.amount) )** | 8299 + 8231 |")
    $null = $sb.AppendLine("")

    $null = $sb.AppendLine("### Expenses")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Category | Amount | GIFI Line |")
    $null = $sb.AppendLine("|----------|--------|-----------|")
    $expenseSorted = $s1.expenses.GetEnumerator() | Sort-Object { $_.Value.label }
    $totalExp = 0.0
    foreach ($kv in $expenseSorted) {
        $v = $kv.Value
        $displayAmt = [math]::Round(-1 * $v.amount, 2)
        $null = $sb.AppendLine("| $($v.label) | $( [string]::Format('{0:N2}', $displayAmt) ) | $($kv.Key) |")
        $totalExp += $displayAmt
    }
    $null = $sb.AppendLine("| **Total Expenses** | **$( [string]::Format('{0:N2}', $totalExp) )** | **Sum** |")
    $null = $sb.AppendLine("")

    # Net Income
    $null = $sb.AppendLine("### Net Income Calculation")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Item | Amount |")
    $null = $sb.AppendLine("|------|--------|")
    $null = $sb.AppendLine("| Total Revenue | $( [string]::Format('{0:N2}', $s1.revenue_8299.amount) ) |")
    $null = $sb.AppendLine("| Less: Total Expenses | ($( [string]::Format('{0:N2}', $totalExp) )) |")
    $null = $sb.AppendLine("| **Net Income (before CCA)** | **$( [string]::Format('{0:N2}', $s1.net_income_before_cca) )** |")
    $null = $sb.AppendLine("| CCA Claimed | ($( [string]::Format('{0:N2}', $s8.total_cca_claimed) )) |")
    $null = $sb.AppendLine("| **Net Income for Tax Purposes** | **$( [string]::Format('{0:N2}', $s1.net_income_for_tax_purposes) )** |")
    $null = $sb.AppendLine("")

    # Schedule 8
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Schedule 8 ΓÇö Capital Cost Allowance")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Class | Rate | Opening UCC | Additions | Disposals | CCA Claimed | Closing UCC |")
    $null = $sb.AppendLine("|-------|------|-------------|-----------|-----------|-------------|-------------|")
    foreach ($cls in $s8.classes) {
        $null = $sb.AppendLine("| Class $($cls.class) | $($cls.rate * 100)% | $( [string]::Format('{0:N2}', $cls.opening_ucc) ) | $( [string]::Format('{0:N2}', $cls.additions) ) | $( [string]::Format('{0:N2}', $cls.disposals) ) | $( [string]::Format('{0:N2}', $cls.cca_claimed) ) | $( [string]::Format('{0:N2}', $cls.closing_ucc) ) |")
    }
    $null = $sb.AppendLine("| **Total** | | | | | **$( [string]::Format('{0:N2}', $s8.total_cca_claimed) )** | |")
    $null = $sb.AppendLine("")

    # Schedule 3
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Schedule 3 ΓÇö Shareholder Information")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Line | Description | Amount |")
    $null = $sb.AppendLine("|------|-------------|--------|")
    $null = $sb.AppendLine("| 170 | Balance at start of year | $( [string]::Format('{0:N2}', $s3.opening_balance) ) |")
    $null = $sb.AppendLine("| 171ΓÇô175 | Advances during year | $( [string]::Format('{0:N2}', $s3.advances_during_year) ) |")
    $null = $sb.AppendLine("| 180 | Balance before repayments | $( [string]::Format('{0:N2}', ($s3.opening_balance + $s3.advances_during_year)) ) |")
    $null = $sb.AppendLine("| 181ΓÇô185 | Repayments during year | $( [string]::Format('{0:N2}', $s3.repayments_during_year) ) |")
    $null = $sb.AppendLine("| 186 | Balance at end of year | $( [string]::Format('{0:N2}', $s3.closing_balance) ) |")
    if ($s3.non_eligible_dividends -ne 0) {
        $null = $sb.AppendLine("| 270 | Non-eligible dividends paid | $( [string]::Format('{0:N2}', $s3.non_eligible_dividends) ) |")
    }
    $null = $sb.AppendLine("")

    # Schedule 4
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Schedule 4 ΓÇö Small Business Deduction")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Line | Description | Amount |")
    $null = $sb.AppendLine("|------|-------------|--------|")
    $null = $sb.AppendLine("| 400 | Active business income | $( [string]::Format('{0:N2}', $s4.active_business_income) ) |")
    $null = $sb.AppendLine("| 410ΓÇô420 | Business limit | $( [string]::Format('{0:N2}', $s4.business_limit_federal) ) |")
    $null = $sb.AppendLine("| 430 | SBD reduction (federal) | $( [string]::Format('{0:N2}', $s4.sbd_federal_reduction) ) |")
    $null = $sb.AppendLine("| 440 | SBD reduction (provincial) | $( [string]::Format('{0:N2}', $s4.sbd_provincial_reduction) ) |")
    $null = $sb.AppendLine("")

    $null = $sb.AppendLine("### Tax Payable Estimate")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Item | Amount |")
    $null = $sb.AppendLine("|------|--------|")
    $null = $sb.AppendLine("| Net income for tax purposes | $( [string]::Format('{0:N2}', $netIncome) ) |")
    $null = $sb.AppendLine("| Federal Part I tax (@ $($tx.federal_part_i_rate_before_sbd * 100)%) | $( [string]::Format('{0:N2}', $tx.part_i_tax_before_sbd) ) |")
    $null = $sb.AppendLine("| Less: SBD federal | ($( [string]::Format('{0:N2}', $tx.sbd_reduction_federal) )) |")
    $null = $sb.AppendLine("| Part I tax after SBD | $( [string]::Format('{0:N2}', $tx.part_i_tax_after_sbd) ) |")
    $null = $sb.AppendLine("| BC general rate (@ $($tx.bc_general_rate * 100)%) | $( [string]::Format('{0:N2}', $tx.bc_tax_before_sbd) ) |")
    $null = $sb.AppendLine("| Less: SBD BC | ($( [string]::Format('{0:N2}', $tx.sbd_reduction_bc) )) |")
    $null = $sb.AppendLine("| BC tax after SBD | $( [string]::Format('{0:N2}', $tx.bc_tax_after_sbd) ) |")
    $null = $sb.AppendLine("| **Total Tax Payable** | **$( [string]::Format('{0:N2}', $tx.total_tax_payable) )** |")
    $null = $sb.AppendLine("| Instalments Paid | $( [string]::Format('{0:N2}', $tx.instalments_paid) ) |")
    $null = $sb.AppendLine("| **Est. Refund / (Balance Owing)** | **$( [string]::Format('{0:N2}', $tx.estimated_refund_balance_owing) )** |")
    $null = $sb.AppendLine("")

    # GST
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## GST/HST Reconciliation")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Line | Description | Amount |")
    $null = $sb.AppendLine("|------|-------------|--------|")
    $null = $sb.AppendLine("| 101 | Total taxable sales (GST-exclusive) | $( [string]::Format('{0:N2}', $s1.revenue_8299.amount) ) |")
    $null = $sb.AppendLine("| 103 | GST/HST collected (5%) | $( [string]::Format('{0:N2}', $gs.gst_collected) ) |")
    $null = $sb.AppendLine("| 106 | Input Tax Credits (ITCs) | $( [string]::Format('{0:N2}', $gs.itcs_claimed) ) |")
    $null = $sb.AppendLine("| 109 | Net tax | $( [string]::Format('{0:N2}', $gs.net_gst_remittable) ) |")
    $null = $sb.AppendLine("| 115 | Amount owing | $( [string]::Format('{0:N2}', [math]::Round($gs.net_gst_remittable)) ) |")
    $null = $sb.AppendLine("")

    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Prior Year Comparison")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Metric | Prior Year | Current Year | Variance |")
    $null = $sb.AppendLine("|--------|-----------|-------------|----------|")
    $null = $sb.AppendLine("| revenue | $( [string]::Format('{0:N2}', $pv.prior_revenue) ) | $( [string]::Format('{0:N2}', $pv.current_revenue) ) | $($pv.revenue_variance_pct.ToString('P1')) |")
    $null = $sb.AppendLine("| net_income | $( [string]::Format('{0:N2}', $pv.prior_net_income) ) | $( [string]::Format('{0:N2}', $pv.current_net_income) ) | $($pv.net_income_variance_pct.ToString('P1')) |")
    $null = $sb.AppendLine("| tax_payable | $( [string]::Format('{0:N2}', $pv.prior_tax_payable) ) | $( [string]::Format('{0:N2}', $pv.current_tax_payable) ) | ΓÇö |")
    $null = $sb.AppendLine("")
    if ($pv.variance_flags.Count -gt 0) {
        $null = $sb.AppendLine("### Variance Flags")
        $null = $sb.AppendLine("")
        foreach ($f in $pv.variance_flags) {
            $null = $sb.AppendLine("- $f")
        }
        $null = $sb.AppendLine("")
    }

    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("*Generated by Invoke-T2Prep.ps1 ΓÇö Data sourced from reconciled TAS-2026.csv*")

    return $sb.ToString()
}

# ΓöÇΓöÇ Main ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
Write-Host "=== Invoke-T2Prep ΓÇö $Organization ===" -ForegroundColor Cyan

# Read TAS
$data = Read-TasData $tasPath
Write-Host "Read $($data.Count) transactions from TAS" -ForegroundColor Green

# Apply GIFI aggregation
$agg = Get-GifiAggregation $data

# Track reclassifications for reporting
$reclassApplied = @()
if ($reclassifications.Count -gt 0) {
    foreach ($srcCat in $reclassifications.Keys) {
        $rule = $reclassifications[$srcCat]
        $matched = $data | Where-Object { & $rule.match $_ }
        if ($matched) {
            $total = ($matched | Measure-Object -Property amount -Sum).Sum
            $reclassApplied += @{
                from  = $srcCat
                to    = $rule.to
                count = $matched.Count
                total = [math]::Round($total, 2)
            }
        }
    }
}

# Build schedules
$schedule1 = New-Schedule1 $agg
$schedule8 = New-Schedule8
$schedule3 = New-Schedule3
$schedule4 = New-Schedule4 $schedule1.net_income_for_tax_purposes
$taxEstimate = New-TaxEstimate $schedule1.net_income_for_tax_purposes $schedule4

# GST
$gstData = Get-GstITCs $data
$gstRecon = New-GstReconciliation $schedule1.revenue_8299.amount $gstData

# Prior year comparison
$priorYear = if ($PriorYearPath -and (Test-Path $PriorYearPath)) {
    $py = Get-Content $PriorYearPath -Raw -Encoding utf8 | ConvertFrom-Json
    @{
        revenue        = $py.prior_year_comparison.revenue
        taxable_income = $py.schedule_1.net_income_for_tax_purposes
        tax_payable    = $py.tax_estimate.total_tax_payable
        sbd_claimed    = $py.schedule_4.sbd_federal_reduction + $py.schedule_4.sbd_provincial_reduction
        cca_claimed    = $py.schedule_8.total_cca_claimed
        net_income     = $py.schedule_1.net_income_for_tax_purposes
        dividends_paid = $py.schedule_3.non_eligible_dividends
    }
} else {
    $defaultPriorYear
}
$priorYearComp = New-PriorYearComparison `
    $schedule1.revenue_8299.amount $schedule1.net_income_for_tax_purposes `
    $taxEstimate.total_tax_payable `
    ($schedule4.sbd_federal_reduction + $schedule4.sbd_provincial_reduction) `
    $schedule8.total_cca_claimed `
    $schedule3.non_eligible_dividends `
    $priorYear

# Assemble result
$result = [ordered]@{
    fiscal_year_end = '2026-03-31'
    entity = 'Intersite Consulting Inc.'
    generated = (Get-Date).ToString('o')
    data_source = 'TAS-2026.csv (reconciled)'
    reclassifications_applied = $reclassApplied
    schedule_1 = $schedule1
    schedule_8 = $schedule8
    schedule_3 = $schedule3
    schedule_4 = $schedule4
    tax_estimate = $taxEstimate
    gst_reconciliation = $gstRecon
    prior_year_comparison = $priorYearComp
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Revenue:         $( [string]::Format('{0,10:N2}', $schedule1.revenue_8299.amount) )" -ForegroundColor White
Write-Host "Total Expenses:  $( [string]::Format('{0,10:N2}', $schedule1.total_expenses) )" -ForegroundColor White
Write-Host "Net Income:      $( [string]::Format('{0,10:N2}', $schedule1.net_income_for_tax_purposes) )" -ForegroundColor $(if ($schedule1.net_income_for_tax_purposes -gt 0) { 'Green' } else { 'Yellow' })
Write-Host "Tax Payable:     $( [string]::Format('{0,10:N2}', $taxEstimate.total_tax_payable) )" -ForegroundColor Yellow
Write-Host "GST Remittable:  $( [string]::Format('{0,10:N2}', $gstRecon.net_gst_remittable) )" -ForegroundColor Yellow

if ($reclassApplied.Count -gt 0) {
    Write-Host "`nReclassifications:" -ForegroundColor Cyan
    foreach ($r in $reclassApplied) {
        Write-Host "  $($r.from) ΓåÆ $($r.to): $($r.count) rows, $([string]::Format('{0:N2}', $r.total))" -ForegroundColor DarkGray
    }
}

# Output files
$jsonPath = Join-Path $defaultOutputDir "draft-t2-schedules.json"
$json = $result | ConvertTo-Json -Depth 10
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)
Write-Host "`nJSON: $jsonPath" -ForegroundColor Green

$mdPath = Join-Path $defaultOutputDir "draft-filing-worksheet.md"
$md = ConvertTo-MarkdownWorksheet $result
[System.IO.File]::WriteAllText($mdPath, $md, $utf8NoBom)
Write-Host "Worksheet: $mdPath" -ForegroundColor Green

if ($PassThru) { return $result }
