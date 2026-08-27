<#
.SYNOPSIS
    Prepares T776 rental income statement data from room-rentals TAS.
.DESCRIPTION
    Reads the room-rentals TAS CSV, aggregates transactions by T776 line categories,
    and produces a markdown worksheet + JSON data file for T776 filing.
    
    T776 (Statement of Real Estate Rentals) lines:
    - Line 8000–8530: Rental income
    - Line 8520–9275: Expenses (mortgage interest, taxes, utilities, etc.)
.PARAMETER Organization
    Entity: room-rentals only.
.PARAMETER OutputDir
    Output directory (default: ~/intersite-docs/Taxes and Bookkeeping/room-rentals/2026 Filing/T776).
.PARAMETER PriorYearPath
    Path to prior year T776 JSON for variance comparison.
.PARAMETER PassThru
    Return the result object instead of writing files (for pipeline chaining).
.PARAMETER DryRun
    Preview the output without writing files.
.EXAMPLE
    .\Invoke-T776Prep.ps1 -DryRun
    Preview the T776 worksheet.
.EXAMPLE
    .\Invoke-T776Prep.ps1
    Generate the full T776 worksheet and JSON data.
#>
[CmdletBinding()]
param(
    [ValidateSet('room-rentals')]
    [string]$Organization = 'room-rentals',
    [string]$OutputDir,
    [string]$PriorYearPath,
    [switch]$PassThru,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals"
$tasPath = "$booksRoot\TAS-2026.csv"
if (-not (Test-Path $tasPath)) { $tasPath = "$booksRoot\TAS-zoho-fy2026.csv" }
if (-not (Test-Path $tasPath)) { throw "TAS not found: $tasPath. Run Build-TAS.ps1 first." }

$filingDir = "$booksRoot\2026 Filing\T776"
$defaultOutputDir = if ($OutputDir) { $OutputDir } else { $filingDir }
if (-not (Test-Path $defaultOutputDir)) { New-Item -ItemType Directory -Path $defaultOutputDir -Force | Out-Null }

# T776 Line Mapping for rental property expenses
# GIFI codes: 8000–8999 for rental income, 9000–9999 for expenses
$t776Map = @{
    # Income
    'Rent Income'                        = @{ gifi = '8000'; type = 'income';   label = 'Gross rents' }
    'Rent Revenue'                       = @{ gifi = '8000'; type = 'income';   label = 'Gross rents' }

    # Expenses — T776 lines
    'Mortgage Interest'                  = @{ gifi = '8710'; type = 'expense';  label = 'Mortgage interest' }
    'Insurance'                          = @{ gifi = '8690'; type = 'expense';  label = 'Insurance' }
    'Property Tax'                       = @{ gifi = '8810'; type = 'expense';  label = 'Property taxes' }
    'Strata Fees'                        = @{ gifi = '8810'; type = 'expense';  label = 'Strata fees (condo fees)' }
    'Utility'                            = @{ gifi = '8820'; type = 'expense';  label = 'Heat, light, water, fuel' }
    'Internet'                           = @{ gifi = '8810'; type = 'expense';  label = 'Internet' }
    'Software and IT Expenses'           = @{ gifi = '8810'; type = 'expense';  label = 'Software & IT' }
    'Repairs'                            = @{ gifi = '8870'; type = 'expense';  label = 'Repairs and maintenance' }
    'Repairs and Maintenance'            = @{ gifi = '8870'; type = 'expense';  label = 'Repairs and maintenance' }
    'Supplies'                           = @{ gifi = '8810'; type = 'expense';  label = 'Supplies' }
    'Advertising'                        = @{ gifi = '8520'; type = 'expense';  label = 'Advertising' }
    'Advertising And Marketing'          = @{ gifi = '8520'; type = 'expense';  label = 'Advertising and marketing' }
    'Automobile Expense'                 = @{ gifi = '8530'; type = 'expense';  label = 'Motor vehicle expenses' }
    'Vehicle/Other'                      = @{ gifi = '8530'; type = 'expense';  label = 'Motor vehicle expenses' }
    'Professional Services'              = @{ gifi = '8860'; type = 'expense';  label = 'Legal, accounting, and other professional fees' }
    'Professional Fees'                  = @{ gifi = '8860'; type = 'expense';  label = 'Professional fees' }
    'Bank Fee'                           = @{ gifi = '8710'; type = 'expense';  label = 'Bank charges and interest' }
    'Bank Fees and Charges'              = @{ gifi = '8710'; type = 'expense';  label = 'Bank charges and interest' }
    'Service Fee'                        = @{ gifi = '8810'; type = 'expense';  label = 'Service fees' }
    'Management Fee'                     = @{ gifi = '8871'; type = 'expense';  label = 'Management and administration fees' }
    'Subscription'                       = @{ gifi = '8810'; type = 'expense';  label = 'Subscriptions' }
}

# Categories NOT reportable as T776 items
$excludeFromT776 = @(
    'Mortgage', 'Credit Card Payment', 'Credit Card Charges', 'Transfer Out',
    'Owner Funding', 'Loan Payment', 'Credit Card Charges'
)

function Read-TasData {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "TAS not found: $Path" }
    return Import-Csv $Path
}

function Get-T776Aggregation {
    param([array]$Rows)
    $income = @{}
    $expense = @{}
    $details = @{}

    foreach ($row in $Rows) {
        $cat = $row.category
        $amt = [decimal]::Parse($row.amount)
        $isNegative = $amt -lt 0

        if ($cat -in $excludeFromT776) { continue }
        if (-not $t776Map.ContainsKey($cat)) { continue }

        $mapping = $t776Map[$cat]
        $gifi = $mapping.gifi
        $label = $mapping.label

        if ($mapping.type -eq 'income') {
            if (-not $income.ContainsKey($gifi)) { $income[$gifi] = @{ label = $label; amount = 0.0; categories = @{} } }
            $income[$gifi].amount += $amt
            if (-not $income[$gifi].categories.ContainsKey($cat)) { $income[$gifi].categories[$cat] = 0.0 }
            $income[$gifi].categories[$cat] += $amt
        } else {
            if (-not $expense.ContainsKey($gifi)) { $expense[$gifi] = @{ label = $label; amount = 0.0; categories = @{} } }
            # Expenses are negative in TAS — flip to positive for reporting
            $val = [math]::Abs($amt)
            $expense[$gifi].amount += $val
            if (-not $expense[$gifi].categories.ContainsKey($cat)) { $expense[$gifi].categories[$cat] = 0.0 }
            $expense[$gifi].categories[$cat] += $val
        }

        $key = "$cat|$gifi"
        if (-not $details.ContainsKey($key)) { $details[$key] = @{ category = $cat; gifi = $gifi; count = 0; total = 0.0 } }
        $details[$key].count++
        $details[$key].total += [math]::Abs($amt)
    }

    return @{
        income  = $income
        expense = $expense
        details = $details
    }
}

function ConvertTo-MarkdownWorksheet {
    param([hashtable]$Result)
    $agg = $Result.aggregation
    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.AppendLine("# Draft T776 Rental Income Statement")
    $null = $sb.AppendLine("**Entity:** Room Rentals (Victor Salmon)")
    $null = $sb.AppendLine("**Fiscal Year:** $($Result.fiscal_year)")
    $null = $sb.AppendLine("*Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')*")
    $null = $sb.AppendLine("*Data Source: $($Result.data_source)*")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("")

    # Summary
    $totalIncome = [math]::Round(($agg.income.Values | Measure-Object amount -Sum).Sum, 2)
    $totalExpenses = [math]::Round(($agg.expense.Values | Measure-Object amount -Sum).Sum, 2)
    $netRentalIncome = [math]::Round($totalIncome - $totalExpenses, 2)

    $null = $sb.AppendLine("## Summary")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Line | Description | Amount |")
    $null = $sb.AppendLine("|------|-------------|--------|")
    $null = $sb.AppendLine("| 8000 | Gross rents | $( [string]::Format('{0:N2}', $totalIncome) ) |")
    $mortgageInterestAmt = if ($agg.expense.ContainsKey('8710')) { $agg.expense['8710'].amount } else { 0.0 }
    $null = $sb.AppendLine("| 8710 | Mortgage interest | $( [string]::Format('{0:N2}', $mortgageInterestAmt) ) |")
    $null = $sb.AppendLine("| | **Total expenses** | **$( [string]::Format('{0:N2}', $totalExpenses) )** |")
    $null = $sb.AppendLine("| 9368 | **Net rental income (loss)** | **$( [string]::Format('{0:N2}', $netRentalIncome) )** |")
    $null = $sb.AppendLine("")

    # Income section
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Income")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| GIFI | Line Description | Amount | Source Categories |")
    $null = $sb.AppendLine("|------|-----------------|--------|------------------|")
    $incomeSorted = $agg.income.GetEnumerator() | Sort-Object Key
    foreach ($kv in $incomeSorted) {
        $cats = ($kv.Value.categories.Keys | ForEach-Object { "$_ ($([string]::Format('{0:N2}', $kv.Value.categories[$_])))" }) -join ', '
        $null = $sb.AppendLine("| $($kv.Key) | $($kv.Value.label) | $( [string]::Format('{0:N2}', $kv.Value.amount) ) | $cats |")
    }
    $null = $sb.AppendLine("| **8000** | **Total Gross Rents** | **$( [string]::Format('{0:N2}', $totalIncome) )** | |")
    $null = $sb.AppendLine("")

    # Expense section
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Expenses")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| GIFI | Line Description | Amount | Source Categories |")
    $null = $sb.AppendLine("|------|-----------------|--------|------------------|")
    $expenseSorted = $agg.expense.GetEnumerator() | Sort-Object Key
    foreach ($kv in $expenseSorted) {
        $cats = ($kv.Value.categories.Keys | ForEach-Object { "$_ ($([string]::Format('{0:N2}', $kv.Value.categories[$_])))" }) -join ', '
        $null = $sb.AppendLine("| $($kv.Key) | $($kv.Value.label) | $( [string]::Format('{0:N2}', $kv.Value.amount) ) | $cats |")
    }
    $null = $sb.AppendLine("| | **Total Expenses** | **$( [string]::Format('{0:N2}', $totalExpenses) )** | |")
    $null = $sb.AppendLine("")

    # Net rental income
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("## Net Rental Income Calculation")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Line | Description | Amount |")
    $null = $sb.AppendLine("|------|-------------|--------|")
    $null = $sb.AppendLine("| 8000 | Gross rents | $( [string]::Format('{0:N2}', $totalIncome) ) |")
    $null = $sb.AppendLine("| 8520–8871 | Total expenses | ($( [string]::Format('{0:N2}', $totalExpenses) )) |")
    $null = $sb.AppendLine("| 9368 | **Net rental income (loss)** | **$( [string]::Format('{0:N2}', $netRentalIncome) )** |")
    $null = $sb.AppendLine("")

    # Prior year comparison
    if ($Result.prior_year_comparison) {
        $py = $Result.prior_year_comparison
        $null = $sb.AppendLine("---")
        $null = $sb.AppendLine("## Prior Year Comparison")
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("| Metric | Prior Year | Current Year | Variance |")
        $null = $sb.AppendLine("|--------|-----------|-------------|----------|")
        $null = $sb.AppendLine("| Gross rents | $( [string]::Format('{0:N2}', $py.prior_gross_rents) ) | $( [string]::Format('{0:N2}', $py.current_gross_rents) ) | $( if ($py.prior_gross_rents -ne 0) { "$([math]::Round(($py.current_gross_rents - $py.prior_gross_rents) / $py.prior_gross_rents * 100, 1))%" } else { 'N/A' } ) |")
        $null = $sb.AppendLine("| Net rental income | $( [string]::Format('{0:N2}', $py.prior_net_income) ) | $( [string]::Format('{0:N2}', $py.current_net_income) ) | $( if ($py.prior_net_income -ne 0) { "$([math]::Round(($py.current_net_income - $py.prior_net_income) / $py.prior_net_income * 100, 1))%" } else { 'N/A' } ) |")
        $null = $sb.AppendLine("| Total expenses | $( [string]::Format('{0:N2}', $py.prior_total_expenses) ) | $( [string]::Format('{0:N2}', $py.current_total_expenses) ) | $( if ($py.prior_total_expenses -ne 0) { "$([math]::Round(($py.current_total_expenses - $py.prior_total_expenses) / $py.prior_total_expenses * 100, 1))%" } else { 'N/A' } ) |")
        $null = $sb.AppendLine("")
    }

    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("*Generated by Invoke-T776Prep.ps1 — Data sourced from TAS-2026.csv (reconciled)*")

    return $sb.ToString()
}

# Main
Write-Host "=== Invoke-T776Prep — $Organization ===" -ForegroundColor Cyan

$data = Read-TasData $tasPath
Write-Host "Read $($data.Count) transactions from TAS" -ForegroundColor Green

$agg = Get-T776Aggregation $data

$totalIncome = [math]::Round(($agg.income.Values | Measure-Object amount -Sum).Sum, 2)
$totalExpenses = [math]::Round(($agg.expense.Values | Measure-Object amount -Sum).Sum, 2)
$netRentalIncome = [math]::Round($totalIncome - $totalExpenses, 2)

# Prior year comparison
$priorYear = if ($PriorYearPath -and (Test-Path $PriorYearPath)) {
    $py = Get-Content $PriorYearPath -Raw -Encoding utf8 | ConvertFrom-Json
    @{
        prior_gross_rents    = $py.summary.gross_rents
        prior_net_income     = $py.summary.net_rental_income
        prior_total_expenses = $py.summary.total_expenses
    }
} else {
    $null
}
$priorYearComp = if ($priorYear) {
    @{
        current_gross_rents    = $totalIncome
        prior_gross_rents      = $priorYear.prior_gross_rents
        current_net_income     = $netRentalIncome
        prior_net_income       = $priorYear.prior_net_income
        current_total_expenses = $totalExpenses
        prior_total_expenses   = $priorYear.prior_total_expenses
    }
} else {
    $null
}

# Assemble result
$result = [ordered]@{
    fiscal_year = 2026
    entity      = 'Room Rentals (Victor Salmon)'
    generated   = (Get-Date).ToString('o')
    data_source = 'TAS-2026.csv (reconciled)'
    summary     = @{
        gross_rents      = $totalIncome
        total_expenses   = $totalExpenses
        net_rental_income = $netRentalIncome
    }
    aggregation     = $agg
    prior_year_comparison = $priorYearComp
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Gross Rents:       $( [string]::Format('{0,10:N2}', $totalIncome) )" -ForegroundColor White
Write-Host "Total Expenses:    $( [string]::Format('{0,10:N2}', $totalExpenses) )" -ForegroundColor White
Write-Host "Net Rental Income: $( [string]::Format('{0,10:N2}', $netRentalIncome) )" -ForegroundColor $(if ($netRentalIncome -gt 0) { 'Green' } else { 'Yellow' })

$md = ConvertTo-MarkdownWorksheet $result

if ($DryRun) {
    Write-Host "`n=== DRY RUN — T776 Preview ===" -ForegroundColor Cyan
    Write-Host $md
    Write-Host "`n=== End Dry Run ===" -ForegroundColor Cyan
} else {
    $jsonPath = Join-Path $defaultOutputDir "draft-t776.json"
    $json = $result | ConvertTo-Json -Depth 10
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)
    Write-Host "`nJSON: $jsonPath" -ForegroundColor Green

    $mdPath = Join-Path $defaultOutputDir "draft-t776-worksheet.md"
    [System.IO.File]::WriteAllText($mdPath, $md, $utf8NoBom)
    Write-Host "Worksheet: $mdPath" -ForegroundColor Green
}

if ($PassThru) { return $result }

Write-Host "`nDone." -ForegroundColor Cyan
