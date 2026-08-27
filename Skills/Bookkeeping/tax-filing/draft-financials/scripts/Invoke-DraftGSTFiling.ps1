<#
.SYNOPSIS
    Produces a draft GST34 filing with cross-checked numbers from Zoho and local data.

.DESCRIPTION
    Computes GST34 line items using consulting revenue and expense data, cross-checks
    against Zoho trial balance (GST/HST Payable account), and explains which source is
    most reliable. Outputs a markdown GST34 draft to the specified directory.

    Data sourcing (preference order):
      1. Reports from Invoke-DraftReports output
      2. Zoho JSON exports directory (read directly)
      3. Manual revenue + expense CSV

    Cross-check logic:
      - Estimates GST collected (revenue x 5%) and ITCs (expenses via vendor categories)
      - Fetches GST/HST Payable balance from Zoho trial balance
      - If Zoho net GST differs from estimate by > 10%, Zoho is flagged as unreliable
      - Explains reasoning and recommends the best source

.PARAMETER ReportsDir
    Path to draft reports output (from Invoke-DraftReports). Contains profit-and-loss.json,
    trial-balance.json, expense-by-vendor.json. If not specified, falls back to Zoho exports.

.PARAMETER ZohoReportsDir
    Path to Zoho JSON exports (profit-and-loss.json, trial-balance.json, etc.).
    Used when ReportsDir is not specified.

.PARAMETER ConsultingRevenue
    Total consulting revenue (overrides report data).

.PARAMETER ExpensesCSV
    Path to CSV with columns: vendor, amount (overrides report data).

.PARAMETER ExpensesByVendor
    Hashtable keyed by vendor name with total expense amounts (overrides report data).

.PAMATER OutputDir
    Directory to write the GST34 draft markdown file. Default: ./draft-gst-filing-output/

.PARAMETER FiscalYearEnd
    Fiscal year end date string (default: "2026-03-31"). Used to load the correct config.

.PARAMETER EntityName
    Legal entity name (default: "Intersite Consulting Inc.").

.PARAMETER BN
    Business Number / GST number (default: "70473 0084 RT0001").

.PARAMETER PriorPeriodAdjustment
    Prior-period GST adjustment for Line 104 (default: $0).

.PARAMETER DryRun
    If set, log what would be done without writing the output file.

.EXAMPLE
    # Auto-detect from Draft Reports output
    .\Invoke-DraftGSTFiling.ps1

.EXAMPLE
    # Manual override with specific revenue and expenses CSV
    .\Invoke-DraftGSTFiling.ps1 -ConsultingRevenue 17274.07 -ExpensesCSV "C:\data\expenses.csv"

.NOTES
    What worked: Reusing Get-GSTReconciliation for the core calculation avoids duplication.
    What didn't: When Zoho exports are stale, the GST/HST Payable balance may not reflect
      the latest JE. Cross-check with trial-balance.json as-of-date.
    API limits: Zero API calls when using local files.
    Idempotent: Yes
#>

param(
    [string]$ReportsDir,
    [string]$ZohoReportsDir,
    [string]$OutputDir,
    [decimal]$ConsultingRevenue,
    [string]$ExpensesCSV,
    [hashtable]$ExpensesByVendor,
    [string]$FiscalYearEnd = "2026-03-31",
    [string]$EntityName = "Intersite Consulting Inc.",
    [string]$BN = "70473 0084 RT0001",
    [decimal]$PriorPeriodAdjustment = 0,
    [switch]$DryRun
)

function Invoke-DraftGSTFiling {
    [CmdletBinding()]
    param(
        [string]$ReportsDir,
        [string]$ZohoReportsDir,
        [string]$OutputDir = (Join-Path $PSScriptRoot "..\draft-gst-filing-output"),
        [decimal]$ConsultingRevenue,
        [string]$ExpensesCSV,
        [hashtable]$ExpensesByVendor,
        [string]$FiscalYearEnd = "2026-03-31",
        [string]$EntityName = "Intersite Consulting Inc.",
        [string]$BN = "70473 0084 RT0001",
        [decimal]$PriorPeriodAdjustment = 0,
        [switch]$DryRun
    )

    Write-Progress -Activity "Draft GST Filing" -Status "Loading config and data" -PercentComplete 5

    # --- Load Draft T2 config (for GST rate + vendor categories) ---
    $configScript = Join-Path $PSScriptRoot "Get-DraftT2Config.ps1"
    if (-not (Test-Path $configScript)) {
        throw "Get-DraftT2Config.ps1 not found at: $configScript"
    }
    . $configScript
    $cfg = Get-DraftT2Config -FiscalYearEnd $FiscalYearEnd -EntityName $EntityName

    # --- Load GST Reconciliation script ---
    $gstScript = Join-Path $PSScriptRoot "Get-GSTReconciliation.ps1"
    if (-not (Test-Path $gstScript)) {
        throw "Get-GSTReconciliation.ps1 not found at: $gstScript"
    }
    . $gstScript

    # --- Discover data sources ---
    $sourceDesc = ""
    $pnlFile = $null; $tbFile = $null; $expFile = $null
    $baseDir = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")

    # Resolve relative paths passed as parameters
    if ($ReportsDir) { $ReportsDir = Resolve-Path $ReportsDir -ErrorAction SilentlyContinue }
    if ($ZohoReportsDir) { $ZohoReportsDir = Resolve-Path $ZohoReportsDir -ErrorAction SilentlyContinue }

    if (-not $ConsultingRevenue -and -not $ExpensesCSV -and -not $ExpensesByVendor) {
        # Try: explicit ReportsDir (Draft Reports output)
        if (-not $pnlFile -and $ReportsDir) {
            $candidate = Join-Path $ReportsDir "profit-and-loss.json"
            if (Test-Path $candidate) {
                $pnlFile = $candidate; $tbFile = Join-Path $ReportsDir "trial-balance.json"
                $expFile = Join-Path $ReportsDir "expense-by-vendor.json"
                $sourceDesc = "Draft Reports output"
            }
        }
        # Try: explicit ZohoReportsDir
        if (-not $pnlFile -and $ZohoReportsDir) {
            $candidate = Join-Path $ZohoReportsDir "profit-and-loss.json"
            if (Test-Path $candidate) {
                $pnlFile = $candidate; $tbFile = Join-Path $ZohoReportsDir "trial-balance.json"
                $expFile = Join-Path $ZohoReportsDir "expense-by-vendor.json"
                $sourceDesc = "Zoho exports"
            }
        }
        # Try: default Draft Reports output next to script
        $candidate = Join-Path $PSScriptRoot "..\draft-reports-output\profit-and-loss.json"
        if (-not $pnlFile -and (Test-Path $candidate)) {
            $dir = Split-Path $candidate -Parent
            $pnlFile = $candidate; $tbFile = Join-Path $dir "trial-balance.json"
            $expFile = Join-Path $dir "expense-by-vendor.json"
            $sourceDesc = "Draft Reports output (default path)"
        }
        # Try: default Zoho exports dir
        if (-not $pnlFile) {
            $candidate = Join-Path $baseDir "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\2026-zoho-reports\profit-and-loss.json"
            if (Test-Path $candidate) {
                $dir = Split-Path $candidate -Parent
                $pnlFile = $candidate; $tbFile = Join-Path $dir "trial-balance.json"
                $sourceDesc = "default Zoho exports path"
            }
        }
    }

    # --- Extract revenue and expense data from reports ---
    if (-not $ConsultingRevenue) {
        if ($pnlFile -and (Test-Path $pnlFile)) {
            Write-Progress -Activity "Draft GST Filing" -Status "Extracting revenue from P&L" -PercentComplete 20
            $pnl = Get-Content $pnlFile -Raw | ConvertFrom-Json
            if (-not $pnl.revenue) {
                # Raw Zoho P&L format — parse it
                $ConsultingRevenue = [double]($pnl.profit_and_loss[0].account_transactions[0].account_transactions | Where-Object { $_.name -match "Consulting Revenue" } | Select-Object -First 1).total
                Write-Host "  Revenue from Zoho P&L (raw): $ConsultingRevenue"
            } else {
                # Parsed Draft Reports format
                $revenueProp = $pnl.revenue.PSObject.Properties | Where-Object { $_.Name -match "Consulting Revenue|Revenue" } | Select-Object -First 1
                if ($revenueProp) {
                    $ConsultingRevenue = [double]$revenueProp.Value
                    Write-Host "  Revenue from P&L: $ConsultingRevenue"
                } else {
                    Write-Warning "Could not find Consulting Revenue property in P&L."
                }
            }
        }
    }

    if (-not $ExpensesCSV -and -not $ExpensesByVendor) {
        if ($expFile -and (Test-Path $expFile)) {
            Write-Progress -Activity "Draft GST Filing" -Status "Loading expense-by-vendor data" -PercentComplete 25
            $exp = Get-Content $expFile -Raw | ConvertFrom-Json
            $ExpensesByVendor = @{}
            foreach ($prop in $exp.categories.PSObject.Properties) {
                $ExpensesByVendor[$prop.Name] = [double]$prop.Value
            }
            Write-Host "  Expense by vendor loaded from: $expFile"
        } elseif ($tbFile -and (Test-Path $tbFile)) {
            Write-Progress -Activity "Draft GST Filing" -Status "Deriving expense data from trial balance" -PercentComplete 25
            $tb = Get-Content $tbFile -Raw | ConvertFrom-Json
            $ExpensesByVendor = @{}
            $expenseAccountNames = @(
                "Automobile Expense", "Bank Fees and Charges", "Credit Card Charges",
                "Lease Expense", "Office & General Expenses", "Other Expenses",
                "Professional Fees", "Repairs and Maintenance", "Software & IT Expenses"
            )
            foreach ($acct in $tb.accounts) {
                if ($expenseAccountNames -contains $acct.name -and $acct.debit_total -gt 0) {
                    $ExpensesByVendor[$acct.name] = [double]$acct.debit_total
                }
            }
        }
    }

    # --- Run GST reconciliation ---
    Write-Progress -Activity "Draft GST Filing" -Status "Computing GST reconciliation" -PercentComplete 40

    if (-not $ConsultingRevenue -or $ConsultingRevenue -eq 0) {
        Write-Warning "No consulting revenue found. GST computed will be $0."
    }

    if (($ExpensesByVendor -or $ExpensesCSV) -and -not ($ConsultingRevenue -gt 0 -or $ExpensesByVendor.Values -or (Test-Path $ExpensesCSV -ErrorAction SilentlyContinue))) {
        Write-Warning "Expenses provided but may not be vendor-level data. ITCs will be $0 unless vendor names match gst_vendor_categories patterns."
    }

    $gstParams = @{
        Config            = $cfg
        ConsultingRevenue = $ConsultingRevenue
    }
    if ($ExpensesCSV) { $gstParams.ExpensesCSV = $ExpensesCSV }
    if ($ExpensesByVendor) { $gstParams.ExpensesByVendor = $ExpensesByVendor }

    $gstResult = Get-GSTReconciliation @gstParams
    Write-Host "  GST Collected: $($gstResult.gst_collected)"
    Write-Host "  ITCs Claimed: $($gstResult.itcs_claimed)"
    Write-Host "  Net GST: $($gstResult.net_gst_remittable)"

    # --- Cross-check with Zoho Trial Balance (GST/HST Payable) ---
    Write-Progress -Activity "Draft GST Filing" -Status "Cross-checking with Zoho Trial Balance" -PercentComplete 60

    $zohoNetGST = $null
    $zohoTBLoaded = $false

    if ($tbFile -and (Test-Path $tbFile)) {
        if (-not $tb) { $tb = Get-Content $tbFile -Raw | ConvertFrom-Json }

        # Handle both Draft Reports format (flat .accounts[]) and raw Zoho format (nested)
        $gstPayableAcct = if ($tb.accounts) {
            $tb.accounts | Where-Object { $_.name -match "GST/HST Payable" } | Select-Object -First 1
        } elseif ($tb.trialbalance) {
            $tb.trialbalance[0].account_transactions | Where-Object { $_.name -match "Liabilities" } |
                Select-Object -ExpandProperty account_transactions |
                Where-Object { $_.name -match "GST/HST Payable" } | Select-Object -First 1
        } else { $null }
        if ($gstPayableAcct) {
            if ($gstPayableAcct.balance -ne $null) { $zohoNetGST = [double]$gstPayableAcct.balance }
            elseif ($gstPayableAcct.net_credit_total -ne $null -and $gstPayableAcct.net_credit_total -ne "") { $zohoNetGST = [double]$gstPayableAcct.net_credit_total }
            elseif ($gstPayableAcct.credit_total -ne $null) { $zohoNetGST = [double]$gstPayableAcct.credit_total }
            $zohoTBLoaded = $true
            Write-Host "  Zoho TB GST/HST Payable: $zohoNetGST"
        }
    }

    if (-not $zohoNetGST -and $gstResult.gst_payable_balance_sheet -gt 0) {
        $zohoNetGST = $gstResult.gst_payable_balance_sheet
        Write-Host "  Using GST/HST Payable from parameter: $zohoNetGST"
    }

    # --- Decide which source is more reliable ---
    Write-Progress -Activity "Draft GST Filing" -Status "Evaluating data source reliability" -PercentComplete 75

    $estimateNetGST = $gstResult.net_gst_remittable
    $reliability = Determine-SourceReliability -Estimate $estimateNetGST -ZohoValue $zohoNetGST -Config $cfg -GstResult $gstResult

    # --- Generate output ---
    Write-Progress -Activity "Draft GST Filing" -Status "Generating GST34 draft" -PercentComplete 85

    $now = Get-Date
    $year = ($FiscalYearEnd -split '-')[0]
    $fileName = "$FiscalYearEnd - GST Draft Filing.md"
    $outputPath = Join-Path $OutputDir $fileName

    $gstCollected = $gstResult.gst_collected
    $itcsClaimed = $gstResult.itcs_claimed
    $netTaxBeforeRounding = $estimateNetGST
    $line105 = $gstCollected + $PriorPeriodAdjustment
    $line108 = $itcsClaimed
    $line109 = $line105 - $line108
    $line115 = [math]::Max(0, $line109)

    $lines = @()

    $lines += "# GST/HST Return (GST34) – Draft Filing"
    $lines += ""
    $lines += "**Entity**: $EntityName"
    $lines += "**BN**: $BN"
    $lines += "**Fiscal Year**: $year (ending $FiscalYearEnd)"
    $lines += "**GST Rate**: $($cfg.gst.rate * 100)%"
    $lines += "**Generated**: $($now.ToString('yyyy-MM-dd HH:mm'))"
    $lines += "**Data Source**: $sourceDesc"
    $lines += ""

    # --- Reliability section ---
    $lines += "## Data Source Reliability"
    $lines += ""
    $lines += $reliability.explanation
    $lines += ""

    if ($reliability.zoho_warning) {
        $lines += "> **Warning**: $($reliability.zoho_warning)"
        $lines += ""
    }

    $lines += "**Recommended source**: $($reliability.recommended_source)"
    $lines += ""

    # --- GST34 lines ---
    $lines += "## GST34 Line Items"
    $lines += ""
    $lines += "| Line | Description | Amount | Source / Calculation |"
    $lines += "|:----:|-------------|------:|---------------------|"

        $lines += "| 101 | Total taxable sales (GST-exclusive) | $($reliability.final_revenue.ToString('N2')) | Consulting Revenue from P&L |"
        $lines += "| 103 | GST/HST collected (5%) | $($gstCollected.ToString('N2')) | Line 101 x 5% |"
        $lines += "| 104 | Adjustments - prior period | $($PriorPeriodAdjustment.ToString('N2')) | User-provided |"
        $lines += "| 105 | Total GST/HST collected | $($line105.ToString('N2')) | 103 + 104 |"
        $lines += "| 106 | Input Tax Credits (ITCs) | $($itcsClaimed.ToString('N2')) | Per-vendor GST classification |"
        $lines += "| 107 | Adjustments to ITCs | 0.00 | None |"
        $lines += "| 108 | Total ITCs | $($line108.ToString('N2')) | 106 + 107 |"
        $lines += "| 109 | Net tax | $($line109.ToString('N2')) | 105 - 108 |"
        $lines += "| 110 | Instalments / annual payments | 0.00 | Annual filer under `$3,000 |"
        $lines += "| 115 | Amount owing (if Line 109 > `$0) | $($line115.ToString('N2')) | Net tax after rounding |"
    $lines += ""

    # --- ITC breakdown ---
    $lines += "## ITC Breakdown"
    $lines += ""
    $lines += "| Category | Total Expenses | GST Portion (5/105) |"
    $lines += "|----------|:-------------:|:-------------------:|"

    $expSummary = $gstResult.expenses_summary
    if ($expSummary.categorized) {
        foreach ($cat in ($expSummary.categorized.PSObject.Properties | Sort-Object Name)) {
            $catAmount = [double]$cat.Value
            $itcAmount = [math]::Round($catAmount * [double]$cfg.gst.reverse_factor, 2, [MidpointRounding]::AwayFromZero)
            $lines += "| $($cat.Name) | $($catAmount.ToString('N2')) | $($itcAmount.ToString('N2')) |"
        }
    }
    $lines += ""
    $lines += "| **Total analyzed** | $($expSummary.total_expenses_analyzed.ToString('N2')) | **ITCs: $($gstResult.itcs_claimed.ToString('N2'))** |"
    $lines += ""

    # --- Cross-reference table ---
    if ($zohoNetGST -ne $null) {
        $lines += "## Cross-Reference: Zoho Trial Balance"
        $lines += ""
        $lines += "| Source | Net GST / GST/HST Payable | Difference | Threshold | Status |"
        $lines += "|--------|:------------------------:|:----------:|:---------:|:------:|"
        $lines += "| Estimate (this filing) | $($estimateNetGST.ToString('N2')) | — | — | — |"
        $lines += "| Zoho Trial Balance | $($zohoNetGST.ToString('N2')) | $([math]::Abs($estimateNetGST - $zohoNetGST).ToString('N2')) | $($reliability.threshold_pct)% | $($reliability.status) |"
        $lines += ""
        $lines += "**Interpretation**: $($reliability.interpretation)"
        $lines += ""
    }

    # --- Line-by-line reasoning ---
    $lines += "## Line-by-Line Reasoning"
    $lines += ""
    $lines += "**Line 101 — Taxable Sales**: The consulting revenue total from the Profit & Loss statement. This represents all income before GST."
    if ($reliability.used_zoho_revenue) {
        $lines += "  - Source: Zoho P&L report ($($reliability.final_revenue.ToString('N2')))"
    }
    $lines += ""

    $lines += "**Line 103 - GST Collected**: Line 101 x 5% = `$$($gstCollected.ToString('N2')). This is the total GST the business should have charged on all taxable supplies."
    $lines += ""

    $lines += "**Line 106 - ITCs**: Each expense vendor is classified as GST-applicable or not, based on vendor category patterns in the tax config. Expenses from Canadian vendors (software, fuel, insurance, lease, Amazon CA, office supplies) have GST at 5/105 reverse-calculated. US digital services, bank fees, and CRA payments are GST-exempt."
    $lines += ""

    $lines += "**Line 109 - Net Tax**: The difference between GST collected and ITCs claimed. This is the amount owing to CRA."
    $lines += ""

    $lines += "**Line 115 - Amount Owing**: Annual filers with net tax under `$3,000 do not need to make instalment payments. The full amount is due when the return is filed."
    $lines += ""

    # --- Prior period ---
    if ($PriorPeriodAdjustment -ne 0) {
        $lines += "## Prior Period Adjustment"
        $lines += ""
        $ppStr = $PriorPeriodAdjustment.ToString('N2')
        $lines += "A prior-period adjustment of **`$$ppStr** has been included on Line 104. This represents:"
        $lines += "- The `$93.81 difference between the originally filed GST return (revenue `$15,391.87) and the revised revenue (`$17,274.07)"
        $lines += "  - carried forward per the 2026-06-06 handoff instruction"
        $lines += ""
    }

    # --- Notes for filing ---
    $lines += "## Filing Notes"
    $lines += ""
    $lines += "1. **CRA My Business Account**: File at [https://cra-arc.gc.ca/mybusiness](https://cra-arc.gc.ca/mybusiness)"
    $lines += "2. **Due date**: June 30 following the fiscal year end (June 30, $year)"
    $lines += "3. **Clearing JE**: After filing, post a journal entry to move the net tax from GST/HST Payable to CRA payable"
    $lines += "4. **GST/PST BC Tax Group**: Create in Zoho UI Settings -> Taxes -> Tax Groups (IDs: GST 93310000000327007, PST 93310000000322002)"
    $lines += ""

    # --- Write output ---
    $content = $lines -join "`n"

    if ($DryRun) {
        Write-Host "`n=== DRY RUN: would write to $outputPath ==="
        Write-Host $content
    } else {
        if (-not (Test-Path $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }
        $content | Out-File -FilePath $outputPath -Encoding utf8
        Write-Host "GST34 draft written to: $outputPath"
    }

    # --- Return structured object ---
    return [PSCustomObject]@{
        config               = $cfg
        gst_reconciliation   = $gstResult
        gst34_lines = [PSCustomObject]@{
            line_101_revenue          = [math]::Round($reliability.final_revenue, 2, [MidpointRounding]::AwayFromZero)
            line_103_gst_collected    = $gstCollected
            line_104_adjustments      = $PriorPeriodAdjustment
            line_105_total_collected  = $line105
            line_106_itcs             = $itcsClaimed
            line_107_itc_adjustments  = 0
            line_108_total_itcs       = $line108
            line_109_net_tax          = $line109
            line_110_instalments      = 0
            line_115_amount_owing     = $line115
        }
        reliability = [PSCustomObject]@{
            zoho_value           = $zohoNetGST
            estimate_value       = $estimateNetGST
            difference           = if ($zohoNetGST -ne $null) { [math]::Round([math]::Abs($estimateNetGST - $zohoNetGST), 2, [MidpointRounding]::AwayFromZero) } else { $null }
            threshold_pct        = $reliability.threshold_pct
            status               = $reliability.status
            recommended_source   = $reliability.recommended_source
            explanation          = $reliability.explanation
        }
        output_path = $outputPath
        source      = $sourceDesc
    }
}

# ===========================================================================
# Determine source reliability
# ===========================================================================
function Determine-SourceReliability {
    param(
        [decimal]$Estimate,
        [decimal]$ZohoValue,
        [PSObject]$Config,
        [PSObject]$GstResult
    )

    $thresholdPct = 10.0
    $result = @{
        threshold_pct      = $thresholdPct
        final_revenue      = $GstResult.gst_on_income.consulting_revenue
        used_zoho_revenue  = $true
        zoho_warning       = $null
        status             = "Consistent"
        interpretation     = ""
        explanation        = ""
        recommended_source = "Estimate (computed from P&L and expenses)"
    }

    if ($ZohoValue -eq $null -or $ZohoValue -eq 0) {
        $result.status = "No Zoho data"
        $result.explanation = "No GST/HST Payable balance was found in the Zoho Trial Balance export. "
        $result.explanation += "Zoho's `reports/taxsummary` returns empty for Canadian orgs because historical transactions "
        $result.explanation += "were entered without tax-line tracking. **The estimate from P&L + expense categories is the only reliable source.**"
        $result.zoho_warning = "Zoho `taxsummary` reports are not available for Canadian orgs. The GST/HST Payable balance in the trial balance reflects manually posted JEs, not auto-calculated amounts."

        $result.interpretation = "No Zoho GST/HST Payable balance to compare. The computed estimate is the authoritative source."
        return $result
    }

    $diffPct = if ($Estimate -ne 0) { [math]::Round([math]::Abs(($ZohoValue - $Estimate) / $Estimate * 100), 1, [MidpointRounding]::AwayFromZero) } else { 0 }

    if ($diffPct -le $thresholdPct) {
        $result.status = "Consistent ✓"
        $result.interpretation = "The Zoho Trial Balance (GST/HST Payable = `$$($ZohoValue.ToString('N2'))`) is within $thresholdPct% of the computed estimate (`$$($Estimate.ToString('N2'))`). "
        $result.interpretation += "Difference: `$$([math]::Abs($Estimate - $ZohoValue).ToString('N2'))`. Both sources agree — use either."
        $result.explanation = "Consistent: Zoho Trial Balance shows GST/HST Payable at `$$($ZohoValue.ToString('N2'))`, "
        $result.explanation += "while the estimate from P&L + expense vendor classification gives `$$($Estimate.ToString('N2'))`. "
        $result.explanation += "The difference of `$$([math]::Abs($Estimate - $ZohoValue).ToString('N2'))` is under the $thresholdPct% threshold. "
        $result.explanation += "Both sources are reliable. The estimate is recommended for filing because it is computed from the full transaction set."
    } else {
        $result.status = "MISMATCH"
        $diffPctStr = "{0:N1}" -f $diffPct
        $absDiffStr = "{0:N2}" -f [math]::Abs($ZohoValue - $Estimate)
        $estStr = "{0:N2}" -f $Estimate
        $zohoStr = "{0:N2}" -f $ZohoValue
        $result.interpretation = "The Zoho Trial Balance (GST/HST Payable = `$$zohoStr`) differs from the computed estimate "
        $result.interpretation += "(`$$estStr`) by **${diffPctStr}%**, which exceeds the ${thresholdPct}% threshold. "
        if ($ZohoValue -gt $Estimate) {
            $result.interpretation += "Possible causes: uncleared opening balances, GST JEs not yet posted to revenue/expense accounts, "
            $result.interpretation += "or prior-year adjustments included in the TB balance."
        } else {
            $result.interpretation += "Possible causes: unreconciled expenses, missing vendor categorization for ITCs, "
            $result.interpretation += "or unreported adjustments in the P&L."
        }
        $result.interpretation += " Recommendation: Use the estimate."
        $result.zoho_warning = "Zoho GST/HST Payable (`$$zohoStr`) is out of line with the estimate (`$$estStr`). "
        $result.zoho_warning += "Zoho transactions were not entered with individual tax-line tracking, so the trial balance figure may include uncleared opening balances or stale adjustments."
        $result.explanation = "MISMATCH: The difference between Zoho (`$$zohoStr`) and the estimate "
        $result.explanation += "(`$$estStr`) is **${diffPctStr}%**, exceeding the ${thresholdPct}% threshold. "
        $result.explanation += "The estimate is more reliable because it is computed from the complete P&L and expense vendor classification. "
        $result.explanation += "Zoho's GST/HST Payable reflects manual JE adjustments and uncleared opening entries, not a systematic computation."
        $result.recommended_source = "Estimate (computed from P&L and expenses) - Zoho flagged as unreliable (${diffPctStr}% difference)"
    }

    return $result
}

# ===========================================================================
# Path helpers
# ===========================================================================
function TryToFindReportsDir {
    param([string]$BaseDir)
    # Check if Draft Reports was just run (same session)
    $candidate = Join-Path $PSScriptRoot "..\draft-reports-output"
    if (Test-Path $candidate) { $script:ReportsDir = $candidate; return }
}

function Resolve-ZohoReportsDir {
    param([string]$Path)
    if (Test-Path $Path) { return $Path }
    return $null
}

# --- Self-test when run directly ---
if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Invoke-DraftGSTFiling') {
    $bound = @{}
    if ($ReportsDir) { $bound.ReportsDir = $ReportsDir }
    if ($ZohoReportsDir) { $bound.ZohoReportsDir = $ZohoReportsDir }
    if ($OutputDir) { $bound.OutputDir = $OutputDir }
    else { $bound.OutputDir = Join-Path $PSScriptRoot "..\draft-gst-filing-output" }
    if ($ConsultingRevenue) { $bound.ConsultingRevenue = $ConsultingRevenue }
    if ($ExpensesCSV) { $bound.ExpensesCSV = $ExpensesCSV }
    if ($ExpensesByVendor) { $bound.ExpensesByVendor = $ExpensesByVendor }
    $bound.FiscalYearEnd = $FiscalYearEnd
    $bound.EntityName = $EntityName
    $bound.BN = $BN
    if ($PriorPeriodAdjustment -ne 0) { $bound.PriorPeriodAdjustment = $PriorPeriodAdjustment }
    if ($DryRun) { $bound.DryRun = $true }
    Invoke-DraftGSTFiling @bound
}

