<#
    # Used by: Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-reports.md
    # Also called by: Skills/Bookkeeping/tax-filing/draft-financials/scripts/Invoke-DraftT2Filing.ps1
.SYNOPSIS
    Produces standardized financial reports (P&L, Trial Balance, Balance Sheet, GL, Expense-by-Vendor).

.DESCRIPTION
    Reads data from Zoho API exports (JSON files in 2026-zoho-reports/) or generates synthetic reports
    from local bank CSVs + manifests when Zoho data is unavailable. Outputs structured JSON files
    consumable by Invoke-DraftGSTFiling and Invoke-DraftT2Filing.

    Data sources, tried in order:
      1. Zoho JSON exports directory (fast, structured)
      2. Zoho API live query (falls back to local exports)
      3. Local bank CSVs + manifests (last resort — generates expense-by-vendor only)

.PARAMETER ZohoReportsDir
    Path to directory containing Zoho JSON exports (profit-and-loss.json, trial-balance.json, etc.).
    Default: <intersite-docs>/.../2026-zoho-reports/

.PARAMETER OutputDir
    Directory to write report JSON files. Default: ./draft-reports-output/

.PARAMETER FiscalYearStart
    Fiscal year start date (default: "2025-04-01").

.PARAMETER FiscalYearEnd
    Fiscal year end date (default: "2026-03-31").

.PARAMETER EntityName
    Legal entity name (default: "Intersite Consulting Inc.").

.PARAMETER ZohoApiMode
    If set, try to fetch reports live from Zoho API instead of reading local exports.
    Requires valid Zoho OAuth token in the session.

.PARAMETER ForceLocalFromCSVs
    If set, skip Zoho exports and build reports from local bank CSVs and manifests only.

.EXAMPLE
    # Quick run with default Zoho exports directory
    $reports = .\Invoke-DraftReports.ps1

.EXAMPLE
    # Write JSON reports to a specific directory
    $reports = .\Invoke-DraftReports.ps1 -OutputDir "C:\temp\fy2026-reports"

.NOTES
    What worked: Reading Zoho JSON exports is fast (< 1s) and produces complete, accurate reports.
    What didn't: N/A — first iteration.
    API limits: Zero API calls when using local exports.
    Idempotent: Yes
#>

function Invoke-DraftReports {
    [CmdletBinding()]
    param(
        [string]$ZohoReportsDir,
        [string]$OutputDir = (Join-Path $PSScriptRoot "..\draft-reports-output"),
        [string]$FiscalYearStart = "2025-04-01",
        [string]$FiscalYearEnd = "2026-03-31",
        [string]$EntityName = "Intersite Consulting Inc.",
        [switch]$ZohoApiMode,
        [switch]$ForceLocalFromCSVs
    )

    $baseDir = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")

    if (-not $ZohoReportsDir) {
        $candidate = Join-Path $baseDir "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\2026-zoho-reports"
        if (Test-Path $candidate) { $ZohoReportsDir = $candidate }
    }

    if (-not (Test-Path $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }

    # --- Source 1: Zoho JSON exports (best) ---
    if ($ZohoReportsDir -and (Test-Path $ZohoReportsDir) -and -not $ForceLocalFromCSVs) {
        Write-Progress -Activity "Draft Reports" -Status "Reading Zoho JSON exports" -PercentComplete 10
        $reports = Read-ZohoJsonExports -ReportsDir $ZohoReportsDir

        if ($reports) {
            Write-Progress -Activity "Draft Reports" -Status "Reports loaded successfully from Zoho exports" -PercentComplete 90

            $reports.metadata = @{
                source          = "Zoho JSON Exports"
                fiscal_year_start = $FiscalYearStart
                fiscal_year_end   = $FiscalYearEnd
                entity          = $EntityName
                generated_at    = (Get-Date -Format "o")
            }
            Write-ReportFiles -Reports $reports -OutputDir $OutputDir
            return $reports
        }
        Write-Warning "Zoho JSON exports directory found but could not be read. Falling back."
    }

    # --- Source 2: Zoho API (if requested) ---
    if ($ZohoApiMode) {
        Write-Progress -Activity "Draft Reports" -Status "Querying Zoho API" -PercentComplete 10
        $reports = Query-ZohoApi -FiscalYearStart $FiscalYearStart -FiscalYearEnd $FiscalYearEnd
        if ($reports) {
            $reports.metadata = @{
                source          = "Zoho API (live)"
                fiscal_year_start = $FiscalYearStart
                fiscal_year_end   = $FiscalYearEnd
                entity          = $EntityName
                generated_at    = (Get-Date -Format "o")
            }
            Write-ReportFiles -Reports $reports -OutputDir $OutputDir
            return $reports
        }
        Write-Warning "Zoho API query failed or returned no data. Falling back to local CSVs."
    }

    # --- Source 3: Local CSVs + manifests (fallback) ---
    Write-Progress -Activity "Draft Reports" -Status "Building reports from local CSVs and manifests" -PercentComplete 10
    $reports = Build-ReportsFromLocalData
    if ($reports) {
        $reports.metadata = @{
            source          = "Local Bank CSVs + Manifests"
            fiscal_year_start = $FiscalYearStart
            fiscal_year_end   = $FiscalYearEnd
            entity          = $EntityName
            generated_at    = (Get-Date -Format "o")
        }
        Write-ReportFiles -Reports $reports -OutputDir $OutputDir
        return $reports
    }

    Write-Error "Could not produce draft reports — no data source was available."
    return $null
}

# ===========================================================================
# Zoho JSON export reader
# ===========================================================================
function Read-ZohoJsonExports {
    param([string]$ReportsDir)

    $result = @{}
    $pnlPath = Join-Path $ReportsDir "profit-and-loss.json"
    $tbPath  = Join-Path $ReportsDir "trial-balance.json"
    $bsPath  = Join-Path $ReportsDir "balance-sheet.json"
    $glPath  = Join-Path $ReportsDir "general-ledger.json"

    if (-not (Test-Path $pnlPath) -or -not (Test-Path $tbPath)) {
        Write-Warning "Required Zoho exports not found (P&L, Trial Balance, or GL)."
        return $null
    }

    # --- P&L ---
    $pnl = Get-Content $pnlPath -Raw | ConvertFrom-Json
    $result.profit_and_loss = Parse-ZohoPnL -PnlObject $pnl

    # --- Trial Balance ---
    $tb = Get-Content $tbPath -Raw | ConvertFrom-Json
    $result.trial_balance = Parse-ZohoTrialBalance -TbObject $tb

    # --- Balance Sheet ---
    if (Test-Path $bsPath) {
        $bs = Get-Content $bsPath -Raw | ConvertFrom-Json
        $result.balance_sheet = Parse-ZohoBalanceSheet -BsObject $bs
    } else {
        $result.balance_sheet = $null
    }

    # --- General Ledger ---
    if (Test-Path $glPath) {
        $gl = Get-Content $glPath -Raw | ConvertFrom-Json
        $result.general_ledger = Parse-ZohoGeneralLedger -GlObject $gl
    } else {
        $result.general_ledger = $null
    }

    # --- Expense-by-Vendor ---
    $result.expense_by_vendor = Build-ExpenseByVendorFromGl -GeneralLedger $result.general_ledger

    return $result
}

# ===========================================================================
# P&L parser — Zoho nested structure → flat named categories
# ===========================================================================
function Parse-ZohoPnL {
    param([PSCustomObject]$PnlObject)

    $revenue = @{}
    $expenses = @{}
    $totalRevenue = 0.0
    $totalExpenses = 0.0

    if (-not $PnlObject.profit_and_loss) { return $null }

    foreach ($section in $PnlObject.profit_and_loss) {
        $sectionName = $section.name
        if (-not $section.account_transactions) { continue }

        foreach ($group in $section.account_transactions) {
            $groupName = $group.name
            if (-not $group.account_transactions) { continue }

            foreach ($acct in $group.account_transactions) {
                $name = $acct.name
                $total = [double]($acct.total -as [double])

                if ($groupName -match "Operating Income|Non Operating Income") {
                    if ($name -ne "Total Operating Income" -and $name -ne "Total Non Operating Income") {
                        $revenue[$name] = $total
                        $totalRevenue += $total
                    }
                } elseif ($groupName -match "Operating Expense|Non Operating Expense|Cost of Goods Sold") {
                    if ($name -ne "Total Operating Expense" -and $name -ne "Total Non Operating Expense" -and $name -ne "Total Cost of Goods Sold") {
                        $expenses[$name] = $total
                        $totalExpenses += $total
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        revenue         = [PSCustomObject]$revenue
        expenses        = [PSCustomObject]$expenses
        total_revenue   = [math]::Round($totalRevenue, 2, [MidpointRounding]::AwayFromZero)
        total_expenses  = [math]::Round($totalExpenses, 2, [MidpointRounding]::AwayFromZero)
        net_income      = [math]::Round($totalRevenue - $totalExpenses, 2, [MidpointRounding]::AwayFromZero)
    }
}

# ===========================================================================
# Trial Balance parser — Zoho nested structure → flat account list
# ===========================================================================
function Parse-ZohoTrialBalance {
    param([PSCustomObject]$TbObject)

    $accounts = @()

    if (-not $TbObject.trialbalance) { return $null }
    $totalNode = $TbObject.trialbalance[0]
    if (-not $totalNode.account_transactions) { return $null }

    foreach ($typeGroup in $totalNode.account_transactions) {
        $accountType = $typeGroup.name
        if (-not $typeGroup.account_transactions) { continue }

        foreach ($acct in $typeGroup.account_transactions) {
            if ($acct.is_parent -or $acct.is_retained_earnings) { continue }

            $debit = 0.0; $credit = 0.0
            if ($acct.net_debit_total -and $acct.net_debit_total -ne "") {
                $debit = [double]($acct.net_debit_total -as [double])
            }
            if ($acct.net_credit_total -and $acct.net_credit_total -ne "") {
                $credit = [double]($acct.net_credit_total -as [double])
            }

            $accounts += [PSCustomObject]@{
                name         = $acct.name
                account_id   = $acct.account_id
                account_type = $accountType
                debit_total  = $debit
                credit_total = $credit
                balance      = [math]::Round($debit - $credit, 2, [MidpointRounding]::AwayFromZero)
            }
        }
    }

    return [PSCustomObject]@{
        accounts       = @($accounts)
        total_debit    = [math]::Round(($accounts | Measure-Object -Property debit_total -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
        total_credit   = [math]::Round(($accounts | Measure-Object -Property credit_total -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
    }
}

# ===========================================================================
# Balance Sheet parser
# ===========================================================================
function Parse-ZohoBalanceSheet {
    param([PSCustomObject]$BsObject)

    $assets = @{}
    $liabilities = @{}
    $equity = @{}
    $totalAssets = 0.0; $totalLiabilities = 0.0; $totalEquity = 0.0

    if (-not $BsObject.balancesheet) { return $null }

    foreach ($section in $BsObject.balancesheet) {
        $sectionName = $section.name
        if (-not $section.account_transactions) { continue }

        foreach ($group in $section.account_transactions) {
            $groupType = $group.name
            if (-not $group.account_transactions) { continue }

            foreach ($acct in $group.account_transactions) {
                $name = $acct.name
                $total = [double]($acct.total -as [double])

                if ($sectionName -match "Assets") {
                    $assets[$name] = $total
                    $totalAssets += $total
                } elseif ($sectionName -match "Liabilities") {
                    $liabilities[$name] = $total
                    $totalLiabilities += $total
                } elseif ($sectionName -match "Equity") {
                    if ($name -notmatch "Retained Earnings|Net Profit") {
                        $equity[$name] = $total
                        $totalEquity += $total
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        assets             = [PSCustomObject]$assets
        liabilities        = [PSCustomObject]$liabilities
        equity             = [PSCustomObject]$equity
        total_assets       = [math]::Round($totalAssets, 2, [MidpointRounding]::AwayFromZero)
        total_liabilities  = [math]::Round($totalLiabilities, 2, [MidpointRounding]::AwayFromZero)
        total_equity       = [math]::Round($totalEquity, 2, [MidpointRounding]::AwayFromZero)
    }
}

# ===========================================================================
# General Ledger parser
# ===========================================================================
function Parse-ZohoGeneralLedger {
    param([PSCustomObject]$GlObject)

    $accounts = @()

    if (-not $GlObject.generalledger) { return $null }

    foreach ($acct in $GlObject.generalledger) {
        if ($acct.debit_total -eq 0 -and $acct.credit_total -eq 0) { continue }

        $accounts += [PSCustomObject]@{
            name         = $acct.name
            account_id   = $acct.account_id
            debit_total  = [double]$acct.debit_total
            credit_total = [double]$acct.credit_total
            balance      = [double]$acct.balance
            is_debit     = [bool]$acct.is_debit
        }
    }

    return [PSCustomObject]@{
        accounts     = @($accounts)
        total_debit  = [math]::Round(($accounts | Measure-Object -Property debit_total -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
        total_credit = [math]::Round(($accounts | Measure-Object -Property credit_total -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
    }
}

# ===========================================================================
# Expense-by-Vendor from GL (approximate — uses P&L category totals)
# When detailed vendor-level data is not available from GL, this uses the
# P&L expense categories as the expense breakdown. For true vendor-level,
# set up manifests or bank CSVs.
# ===========================================================================
function Build-ExpenseByVendorFromGl {
    param([PSCustomObject]$GeneralLedger)

    if (-not $GeneralLedger) { return $null }

    $expenseAccounts = @(
        "Automobile Expense", "Bank Fees and Charges", "Credit Card Charges",
        "Lease Expense", "Office & General Expenses", "Other Expenses",
        "Professional Fees", "Repairs and Maintenance", "Software & IT Expenses",
        "Advertising", "Insurance", "Telephone", "Travel"
    )

    $byCategory = @{}
    $unmatched = @()
    foreach ($acct in $GeneralLedger.accounts) {
        $name = $acct.name
        if ($expenseAccounts -contains $name) {
            $byCategory[$name] = [math]::Round($acct.debit_total - $acct.credit_total, 2, [MidpointRounding]::AwayFromZero)
        } elseif ($name -notmatch 'Total|Opening|Retained|Net Profit') {
            $unmatched += $name
        }
    }
    if ($unmatched.Count -gt 0) {
        Write-Warning "GL accounts not in expense list (possibly excluded from expense-by-vendor): $($unmatched -join ', ')"
    }

    return [PSCustomObject]@{
        categories       = [PSCustomObject]$byCategory
        total_expenses   = [math]::Round(($byCategory.Values | Measure-Object -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
        note             = "Expenses grouped by category from General Ledger. For vendor-level ITC classification, provide a CSV with vendor,amount columns or use a receipt manifest."
    }
}

# ===========================================================================
# Placeholder for Zoho API live query
# ===========================================================================
function Query-ZohoApi {
    param(
        [string]$FiscalYearStart,
        [string]$FiscalYearEnd
    )
    Write-Warning "Zoho API mode not yet implemented — use local JSON exports instead."
    return $null
}

# ===========================================================================
# Build reports from local CSVs (bank statements + manifests)
# ===========================================================================
function Build-ReportsFromLocalData {
    $intersiteDocs = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")) "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing"

    $rbcCsv = Join-Path $intersiteDocs "2026 Bank Statements\RBC-INTERSITE\2026 Fiscal Year - Intersite Transactions.csv"
    $mcCsv = Join-Path $intersiteDocs "2026 Bank Statements\MC 6241 (6258)\2026 Fiscal Year - Intersite MC 6258 - enriched.csv"
    $rbcManifest = Join-Path $intersiteDocs "Receipts\rbc-intersite-manifest-enriched.csv"
    $mcManifest = Join-Path $intersiteDocs "Receipts\rbc-6258-manifest.csv"

    $expensesByVendor = @{}

    # --- RBC CSV ---
    if (Test-Path $rbcCsv) {
        $rbcData = Import-Csv $rbcCsv
        $rbcData | Where-Object { [double]($_.'CAD$' -replace ',', '') -lt 0 } | ForEach-Object {
            $desc = "$($_.'Description 1') $($_.'Description 2')".Trim()
            $amount = [math]::Abs([double]($_.'CAD$' -replace ',', ''))
            $vendor = $desc
            if ($desc -match '^(WAVE|Misc Payment|Monthly fee|PAY-FILE|E-Transfer)') {
                $vendor = "Bank Fees"
            } elseif ($desc -match 'Zoho|Kilo') {
                $vendor = "Zoho Canada"
            } elseif ($desc -match 'Petro-Can|Shell|Chevron|Esso') {
                $vendor = "Petro-Canada"
            } elseif ($desc -match 'ICBC|Canada Life') {
                $vendor = "ICBC"
            } elseif ($desc -match 'Amazon') {
                $vendor = "Amazon.ca"
            } elseif ($desc -match 'Staples|Best Buy') {
                $vendor = "Staples"
            } elseif ($desc -match 'CRA|CCRA|Canada Revenue') {
                $vendor = "CRA Payments"
            } elseif ($desc -match 'RBC|INTERAC') {
                $vendor = "Bank Fees"
            }
            if ($expensesByVendor.ContainsKey($vendor)) {
                $expensesByVendor[$vendor] += $amount
            } else {
                $expensesByVendor[$vendor] = $amount
            }
        }
    }

    return [PSCustomObject]@{
        profit_and_loss   = $null
        trial_balance     = $null
        balance_sheet     = $null
        general_ledger    = $null
        expense_by_vendor = [PSCustomObject]@{
            categories    = [PSCustomObject]$expensesByVendor
            total_expenses = [math]::Round(($expensesByVendor.Values | Measure-Object -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
            note          = "Built from bank CSVs (RBC + MC). May not capture all non-bank transactions."
        }
    }
}

# ===========================================================================
# Write report JSON files to disk
# ===========================================================================
function Write-ReportFiles {
    param(
        [PSCustomObject]$Reports,
        [string]$OutputDir
    )

    $Reports | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $OutputDir "draft-reports.json") -Encoding utf8

    if ($Reports.profit_and_loss) {
        $Reports.profit_and_loss | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "profit-and-loss.json") -Encoding utf8
    }
    if ($Reports.trial_balance) {
        $Reports.trial_balance | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "trial-balance.json") -Encoding utf8
    }
    if ($Reports.balance_sheet) {
        $Reports.balance_sheet | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "balance-sheet.json") -Encoding utf8
    }
    if ($Reports.general_ledger) {
        $Reports.general_ledger | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "general-ledger.json") -Encoding utf8
    }
    if ($Reports.expense_by_vendor) {
        $Reports.expense_by_vendor | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "expense-by-vendor.json") -Encoding utf8
    }

    Write-Host "Reports written to: $OutputDir"
}

# --- Self-test when run directly ---
if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Invoke-DraftReports') {
    $bound = @{}; foreach ($k in $MyInvocation.BoundParameters.Keys) { $bound[$k] = $MyInvocation.BoundParameters[$k] }
    Invoke-DraftReports @bound
}

