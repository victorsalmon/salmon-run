<#
.SYNOPSIS
    T2 Preparation orchestrator — pulls Zoho reports, parses them into T2-ready structured data, and outputs a comprehensive prep package for draft T2 filing.

.DESCRIPTION
    Phase 1 — Pull Reports: Calls sync-local-books-from-zoho.mjs to fetch all Zoho Books reports (P&L, Trial Balance, Balance Sheet, GL, CoA, Tax Summary, AR Aging, AP Aging, Fixed Asset Schedule, per-account GLs).

    Phase 2 — Parse Reports: Reads the raw Zoho JSON exports via Invoke-DraftReports (P&L, TB, BS, GL), plus parses additional reports not handled by Invoke-DraftReports (AR Aging, AP Aging, Tax Summary, per-account GLs).

    Phase 3 — Prepare T2 Inputs: Extracts the specific data points each schedule script needs (P&L hashtable, CCA classes, SHL flows, dividends, instalments, GST data).

    Phase 4 — Generate Prep Package: Writes a structured JSON file (t2-prep-data.json) with all extracted T2 inputs, plus a human-readable markdown summary (t2-prep-summary.md).

    Phase 5 — Draft T2 Pipeline (optional with -RunDraft): Runs Invoke-DraftT2Filing with the prepared data to compute all schedules and produce the draft worksheet.

.PARAMETER ZohoReportsDir
    Path to directory containing Zoho JSON exports. Default: auto-discovered in intersite-docs.

.PARAMETER OutputDir
    Directory to write the T2 prep package. Default: <intersite-docs>/.../t2-prep-output/

.PARAMETER FiscalYearStart
    Fiscal year start date (default: "2025-04-01").

.PARAMETER FiscalYearEnd
    Fiscal year end date (default: "2026-03-31").

.PARAMETER EntityName
    Legal entity name (default: "Intersite Consulting Inc.").

.PARAMETER OpeningSHLBalance
    Shareholder loan opening balance. If 0, auto-discovered from prior year config.

.PARAMETER RunDraft
    If set, also runs Invoke-DraftT2Filing after preparing data.

.PARAMETER SkipSync
    If set, skips the Zoho API sync and uses existing report files.

.PARAMETER ForceSync
    If set, forces a fresh Zoho API sync even if recent reports exist.

.EXAMPLE
    # Full run: sync reports, parse, prepare data
    .\Invoke-T2Prep.ps1

.EXAMPLE
    # Skip Zoho sync, re-parse existing reports only
    .\Invoke-T2Prep.ps1 -SkipSync

.EXAMPLE
    # Full run including draft T2 filing
    .\Invoke-T2Prep.ps1 -RunDraft
#>

$scriptsDir = Split-Path -Parent $PSCommandPath
$repoRoot   = Resolve-Path (Join-Path $scriptsDir "..\..\..\..\..")
$intersiteDocs = Join-Path $repoRoot "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing"

function Invoke-T2Prep {
    [CmdletBinding()]
    param(
        [string]$ZohoReportsDir,
        [string]$OutputDir = (Join-Path $intersiteDocs "t2-prep-output"),
        [string]$FiscalYearStart = "2025-04-01",
        [string]$FiscalYearEnd = "2026-03-31",
        [string]$EntityName = "Intersite Consulting Inc.",
        [decimal]$OpeningSHLBalance = 0,
        [switch]$RunDraft,
        [switch]$SkipSync,
        [switch]$ForceSync
    )

    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "=== T2 Prep Pipeline ===" -ForegroundColor Cyan
    Write-Host "Entity: $EntityName"
    Write-Host "Period: $FiscalYearStart → $FiscalYearEnd"
    Write-Host ""

    # Resolve path
    if (-not $ZohoReportsDir) {
        $candidate = Join-Path $intersiteDocs "2026-zoho-reports"
        if (Test-Path $candidate) { $ZohoReportsDir = $candidate }
    }
    if (-not (Test-Path $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }

    # ── Phase 1: Sync Zoho reports ──────────────────────────────────────────────
    Write-Host "── Phase 1: Pull Reports ──" -ForegroundColor Yellow
    if (-not $SkipSync) {
        $syncScript = Join-Path $repoRoot "Skills\Bookkeeper\Scripts\sync-local-books-from-zoho.mjs"
        if (Test-Path $syncScript) {
            $syncArgs = @()
            if ($ForceSync) { $syncArgs += "--force-refresh" }
            Write-Host "  Running: node sync-local-books-from-zoho.mjs $($syncArgs -join ' ')"
            $result = & node $syncScript $syncArgs 2>&1
            $result | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Zoho sync exited with code $LASTEXITCODE. Proceeding with existing reports."
            }
        } else {
            Write-Warning "Sync script not found at $syncScript"
        }
    } else {
        Write-Host "  Skipped (--SkipSync)"
    }

    if (-not $ZohoReportsDir -or -not (Test-Path $ZohoReportsDir)) {
        $candidate = Join-Path $intersiteDocs "2026-zoho-reports"
        if (Test-Path $candidate) { $ZohoReportsDir = $candidate }
    }
    if (-not $ZohoReportsDir -or -not (Test-Path $ZohoReportsDir)) {
        Write-Error "No Zoho reports directory found. Run without -SkipSync to pull reports."
        return $null
    }
    Write-Host "  Zoho reports dir: $ZohoReportsDir"
    Write-Host ""

    # ── Phase 2: Parse reports ──────────────────────────────────────────────────
    Write-Host "── Phase 2: Parse Reports ──" -ForegroundColor Yellow

    $reportsScript = Join-Path $scriptsDir "Invoke-DraftReports.ps1"
    if (Test-Path $reportsScript) { . $reportsScript }
    $reports = Invoke-DraftReports -ZohoReportsDir $ZohoReportsDir -OutputDir $OutputDir
    $hasReports = $reports -and $reports.profit_and_loss
    if (-not $hasReports) { Write-Error "Could not parse report data from $ZohoReportsDir"; return $null }

    Write-Host "  P&L: $($reports.profit_and_loss.total_revenue.ToString('C2')) revenue, $($reports.profit_and_loss.total_expenses.ToString('C2')) expenses"
    if ($reports.trial_balance) {
        Write-Host "  TB: $($reports.trial_balance.accounts.Count) accounts"
    }
    if ($reports.balance_sheet) {
        Write-Host "  BS: $($reports.balance_sheet.total_assets.ToString('C2')) assets, $($reports.balance_sheet.total_liabilities.ToString('C2')) liabilities"
    }

    # Parse additional reports
    Write-Host "  Parsing additional reports..."
    $taxSummary = Parse-TaxSummary -ReportsDir $ZohoReportsDir
    $arAging = Parse-ARAging -ReportsDir $ZohoReportsDir
    $apAging = Parse-APAging -ReportsDir $ZohoReportsDir
    $fixedAssets = Parse-FixedAssetSchedule -ReportsDir $ZohoReportsDir
    $extraGL = Parse-PerAccountGLs -ReportsDir $ZohoReportsDir
    Write-Host ""

    # ── Phase 3: Prepare T2 Inputs ──────────────────────────────────────────────
    Write-Host "── Phase 3: Prepare T2 Inputs ──" -ForegroundColor Yellow

    $pnl = $reports.profit_and_loss
    $pandLData = @{}
    if ($pnl.revenue) { $pnl.revenue.PSObject.Properties | ForEach-Object { $pandLData[$_.Name] = [decimal]$_.Value } }
    if ($pnl.expenses) { $pnl.expenses.PSObject.Properties | ForEach-Object { $pandLData[$_.Name] = [decimal]$_.Value } }
    Write-Host "  P&L hashtable: $($pandLData.Count) accounts"

    $dividendsTotal = 0m; $instalmentsPaid = 0m
    if ($reports.trial_balance) {
        $divAcct = $reports.trial_balance.accounts | Where-Object { $_.name -match 'Dividend' } | Select-Object -First 1
        if ($divAcct) { $dividendsTotal = [decimal]$divAcct.debit_total }
        Write-Host "  Dividends: $($dividendsTotal.ToString('C2'))"

        $instAcct = $reports.trial_balance.accounts | Where-Object { $_.name -match 'Corporate Income Tax|CIT' -and $_.balance -lt 0 } | Select-Object -First 1
        if (-not $instAcct) { $instAcct = $reports.trial_balance.accounts | Where-Object { $_.name -match 'Instalment|Prepaid.*Tax' } | Select-Object -First 1 }
        if ($instAcct) {
            $instalmentsPaid = [decimal][math]::Abs($instAcct.balance)
            Write-Host "  Instalments paid: $($instalmentsPaid.ToString('C2'))"
        } else {
            Write-Host "  Instalments: not found (defaults to 0)"
        }
    }

    $shlAdvances = 0m; $shlRepayments = 0m
    $shlGL = $extraGL | Where-Object { $_.name -match 'Shareholder Loan' } | Select-Object -First 1
    if ($shlGL) {
        $shlAdvances = [decimal]$shlGL.debit_total
        $shlRepayments = [decimal]$shlGL.credit_total
        Write-Host "  SHL: $($shlAdvances.ToString('C2')) advances, $($shlRepayments.ToString('C2')) repayments"
    }

    if ($OpeningSHLBalance -eq 0 -and $reports.balance_sheet -and $reports.balance_sheet.equity) {
        $shlBalProp = $reports.balance_sheet.equity.PSObject.Properties | Where-Object { $_.Name -match 'Shareholder Loan|Due from Shareholder' } | Select-Object -First 1
        if ($shlBalProp) { $OpeningSHLBalance = [decimal]$shlBalProp.Value }
    }
    Write-Host "  SHL opening balance: $($OpeningSHLBalance.ToString('C2'))"

    $mealsTotal = 0m
    $mealsGL = $extraGL | Where-Object { $_.name -match 'Meals|Entertainment' } | Select-Object -First 1
    if ($mealsGL) { $mealsTotal = [decimal]$mealsGL.debit_total }
    Write-Host "  Meals & entertainment: $($mealsTotal.ToString('C2'))"

    $interestIncome = if ($pandLData.ContainsKey("Interest Income")) { $pandLData["Interest Income"] } else { 0m }
    Write-Host "  Interest income: $($interestIncome.ToString('C2'))"

    $gstCollected = 0m; $gstITCs = 0m
    if ($taxSummary) {
        $gstCollected = $taxSummary.gst_collected
        $gstITCs = $taxSummary.itcs_claimed
        Write-Host "  GST: $($gstCollected.ToString('C2')) collected, $($gstITCs.ToString('C2')) ITCs"
    }

    $ccaClasses = @()
    if ($fixedAssets -and $fixedAssets.Count -gt 0) {
        $ccaClasses = $fixedAssets
        Write-Host "  CCA: $($fixedAssets.Count) classes from Fixed Asset Schedule"
    } else {
        Write-Host "  CCA: no Fixed Asset Schedule data (will default to zeros)"
    }

    $consultingRevenue = if ($pandLData.ContainsKey("Consulting Revenue")) { $pandLData["Consulting Revenue"] } else { 0m }
    $netIncomeTotal = if ($pnl) { $pnl.net_income } else { 0m }

    # ── Phase 4: Generate Prep Package ──────────────────────────────────────────
    Write-Host ""
    Write-Host "── Phase 4: Generate Prep Package ──" -ForegroundColor Yellow

    $t2Inputs = [PSCustomObject]@{
        metadata = [PSCustomObject]@{
            entity             = $EntityName
            fiscal_year_start  = $FiscalYearStart
            fiscal_year_end    = $FiscalYearEnd
            generated_at       = (Get-Date -Format "o")
            zoho_reports_dir   = $ZohoReportsDir
            source             = if ($reports.metadata) { $reports.metadata.source } else { "Zoho JSON Exports" }
        }
        schedule_1 = [PSCustomObject]@{
            pandl_data       = [PSCustomObject]$pandLData
            consulting_revenue = $consultingRevenue
            interest_income  = $interestIncome
            meals_total      = $mealsTotal
            net_income_before_cca = $netIncomeTotal
        }
        schedule_3 = [PSCustomObject]@{
            opening_shl_balance = $OpeningSHLBalance
            shl_advances        = $shlAdvances
            shl_repayments      = $shlRepayments
            closing_balance     = $OpeningSHLBalance + $shlAdvances - $shlRepayments
            dividends_total     = $dividendsTotal
        }
        schedule_4 = [PSCustomObject]@{
            interest_income  = $interestIncome
            instalments_paid = $instalmentsPaid
        }
        schedule_8 = [PSCustomObject]@{
            cca_classes = @($ccaClasses)
        }
        t2s_bc = [PSCustomObject]@{
            note = "T2S(BC) is computed from Schedule 4 data: BC general rate (12%) minus BC small business rate (2%) on SBD-eligible ABI. See Schedule 4 output for the calculation."
        }
        t5_slip = [PSCustomObject]@{
            eligible_dividends    = 0m
            non_eligible_dividends = $dividendsTotal
            recipient             = $EntityName
        }
        gst = [PSCustomObject]@{
            consulting_revenue = $consultingRevenue
            gst_collected     = $gstCollected
            itcs_claimed      = $gstITCs
            net_gst           = $gstCollected - $gstITCs
        }
        additional_reports = [PSCustomObject]@{
            tax_summary          = $taxSummary
            ar_aging             = $arAging
            ap_aging             = $apAging
            fixed_asset_schedule = $fixedAssets
        }
    }

    $jsonPath = Join-Path $OutputDir "t2-prep-data.json"
    $t2Inputs | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8
    Write-Host "  Wrote: $jsonPath"

    $nl = [Environment]::NewLine
    $md = @"
# T2 Preparation Summary
**$EntityName** — FY $FiscalYearStart to $FiscalYearEnd
*Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")*

---

## Income & Expenses (Schedule 1)

### Revenue
| Source | Amount |
|--------|--------|
| Consulting Revenue | `$$($consultingRevenue.ToString('N2'))` |
| Interest Income | `$$($interestIncome.ToString('N2'))` |
| **Total Revenue** | **`$$($pnl.total_revenue.ToString('N2'))`** |

### Expenses

"@
    if ($pnl.expenses) {
        $md += "| Category | Amount |" + $nl
        $md += "|----------|--------|" + $nl
        $pnl.expenses.PSObject.Properties | Sort-Object Name | ForEach-Object {
            $md += "| $($_.Name) | `$$($_.Value.ToString('N2')) |" + $nl
        }
    }
    $md += "| **Total Expenses** | **`$$($pnl.total_expenses.ToString('N2'))** |" + $nl
    $md += "| **Net Income (before CCA)** | **`$$($netIncomeTotal.ToString('N2'))** |" + $nl

    $md += @"

### Adjustments
| Item | Amount |
|------|--------|
| Meals & entertainment (50% add-back) | `$$($mealsTotal.ToString('N2'))` × 50% = `$($(($mealsTotal * 0.5).ToString('N2')))` |
| CCA difference vs book depreciation | To be filled from Schedule 8 |

---

## Capital Cost Allowance (Schedule 8)

"@
    if ($ccaClasses.Count -gt 0) {
        $md += "| Class | Opening UCC | Additions | Disposals |" + $nl
        $md += "|-------|-------------|-----------|-----------|" + $nl
        foreach ($c in $ccaClasses) {
            $md += "| $($c.name) | `$$($c.opening_ucc.ToString('N2')) | `$$($c.additions.ToString('N2')) | `$$($c.disposals.ToString('N2')) |" + $nl
        }
    } else {
        $md += "No fixed asset data found in Zoho. CCA will default to zero unless manually entered." + $nl
    }

    $closingSHL = $OpeningSHLBalance + $shlAdvances - $shlRepayments
    $md += @"

---

## Shareholder Loan (Schedule 3)

| Item | Amount |
|------|--------|
| Opening balance | `$$($OpeningSHLBalance.ToString('N2'))` |
| Advances during year | `$$($shlAdvances.ToString('N2'))` |
| Repayments during year | `$$($shlRepayments.ToString('N2'))` |
| **Closing balance** | **`$$($closingSHL.ToString('N2'))`** |

---

## Dividends & T5 Slip

| Item | Amount |
|------|--------|
| Non-eligible dividends paid | `$$($dividendsTotal.ToString('N2'))` |
| Eligible dividends | `$0.00` |
| **T5 slip required** | **$(if ($dividendsTotal -gt 0) { 'Yes' } else { 'No' })** |

---

## Small Business Deduction (Schedule 4) & T2S(BC)

| Item | Amount |
|------|--------|
| Interest income (AII component) | `$$($interestIncome.ToString('N2'))` |
| Instalments paid | `$$($instalmentsPaid.ToString('N2'))` |
| BC general rate | 12% |
| BC small business rate | 2% |

---

## GST/HST Reconciliation

| Item | Amount |
|------|--------|
| Consulting revenue (GST-inclusive) | `$$($consultingRevenue.ToString('N2'))` |
| GST collected (5%) | `$$($gstCollected.ToString('N2'))` |
| ITCs claimed | `$$($gstITCs.ToString('N2'))` |
| Net GST remittable | `$$(($gstCollected - $gstITCs).ToString('N2'))` |

---

## Additional Reports

"@
    if ($taxSummary) { $md += "- **Tax Summary**: GST `$$($taxSummary.gst_collected.ToString('N2'))` collected, `$$($taxSummary.itcs_claimed.ToString('N2'))` ITCs" + $nl }
    if ($arAging) { $md += "- **AR Aging**: `$$($arAging.total_outstanding.ToString('N2'))` outstanding across $($arAging.customer_count) customer(s)" + $nl }
    if ($apAging) { $md += "- **AP Aging**: `$$($apAging.total_outstanding.ToString('N2'))` outstanding across $($apAging.vendor_count) vendor(s)" + $nl }
    if (-not $taxSummary -and -not $arAging -and -not $apAging) { $md += "No additional report data available." + $nl }

    $md += @"

---

## Next Steps

1. **Review** this summary and the detailed t2-prep-data.json
2. **Resolve gaps** (highlighted in yellow/red above)
3. **Run draft T2 filing**: `.\Invoke-DraftT2Filing.ps1 -RunDraft`
4. **Enter data into CloudTax** using the draft worksheet
5. **File T5 slip** with the T2 return if dividends > 0
6. **T2S(BC)** is automatically computed by Schedule 4 — no separate BC return needed

*Generated by Invoke-T2Prep.ps1*
"@

    $summaryPath = Join-Path $OutputDir "t2-prep-summary.md"
    $md | Out-File -FilePath $summaryPath -Encoding utf8
    Write-Host "  Wrote: $summaryPath"

    $elapsed.Stop()
    Write-Host ""
    Write-Host "── T2 Prep Package Complete ──" -ForegroundColor Green
    Write-Host "  Output: $OutputDir"
    Write-Host "  Elapsed: $($elapsed.Elapsed.TotalSeconds.ToString('F1'))s"
    Write-Host ""

    # ── Phase 5: Run Draft T2 Filing (optional) ─────────────────────────────────
    $draftResult = $null
    if ($RunDraft) {
        Write-Host "── Phase 5: Run Draft T2 Filing ──" -ForegroundColor Yellow

        $cfgScript = Join-Path $scriptsDir "Get-DraftT2Config.ps1"
        if (Test-Path $cfgScript) { . $cfgScript }
        $config = Get-DraftT2Config -FiscalYearEnd $FiscalYearEnd -EntityName $EntityName

        $draftScript = Join-Path $scriptsDir "Invoke-DraftT2Filing.ps1"
        if (Test-Path $draftScript) {
            . $draftScript
            $draftParams = @{
                Config             = $config
                PandLData          = $pandLData
                OpeningSHLBalance  = $OpeningSHLBalance
                DividendsTotal     = $dividendsTotal
                InstalmentsPaid    = $instalmentsPaid
                MealsExpensesTotal = $mealsTotal
                OutputDir          = $OutputDir
            }
            $draftResult = Invoke-DraftT2Filing @draftParams
            if ($draftResult) {
                Write-Host "  Draft T2 Filing complete." -ForegroundColor Green
                Write-Host "  Worksheet: $($draftResult.output.worksheet_path)"
                Write-Host "  JSON: $($draftResult.output.json_path)"
            }
        } else {
            Write-Warning "Invoke-DraftT2Filing.ps1 not found — skipping Phase 5."
        }
    }

    return [PSCustomObject]@{
        prep_data    = $t2Inputs
        json_path    = $jsonPath
        summary_path = $summaryPath
        draft_result = $draftResult
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════

function Parse-TaxSummary {
    param([string]$ReportsDir)
    $path = Join-Path $ReportsDir "tax-summary.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
        $taxSummary = $data.taxsummary
        if (-not $taxSummary) { return $null }
        $gstEntry = $taxSummary | Where-Object { $_.name -match 'GST|HST|Sales Tax' } | Select-Object -First 1
        if (-not $gstEntry) { $gstEntry = $taxSummary[0] }
        if (-not $gstEntry) { return $null }
        return [PSCustomObject]@{
            gst_collected = [decimal]($gstEntry.total_tax_collected -as [decimal])
            itcs_claimed  = [decimal]($gstEntry.total_tax_credit -as [decimal])
            net_tax       = [decimal]($gstEntry.total_tax_collected - $gstEntry.total_tax_credit -as [decimal])
        }
    } catch { Write-Warning "Failed to parse tax-summary.json: $_"; return $null }
}

function Parse-ARAging {
    param([string]$ReportsDir)
    $path = Join-Path $ReportsDir "ar-aging.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
        $aging = $data.accountsreceivableaging
        if (-not $aging) { return $null }
        $total = 0m; $customers = @()
        foreach ($entry in $aging) {
            if ($entry.total -and $entry.total -ne '') {
                $amt = [decimal]($entry.total -as [decimal]); $total += $amt
                $customers += [PSCustomObject]@{ name = $entry.customer_name; total = $amt }
            }
        }
        return [PSCustomObject]@{ total_outstanding = $total; customer_count = $customers.Count; customers = @($customers) }
    } catch { Write-Warning "Failed to parse ar-aging.json: $_"; return $null }
}

function Parse-APAging {
    param([string]$ReportsDir)
    $path = Join-Path $ReportsDir "ap-aging.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
        $aging = $data.accountspayableaging
        if (-not $aging) { return $null }
        $total = 0m; $vendors = @()
        foreach ($entry in $aging) {
            if ($entry.total -and $entry.total -ne '') {
                $amt = [decimal]($entry.total -as [decimal]); $total += $amt
                $vendors += [PSCustomObject]@{ name = $entry.vendor_name; total = $amt }
            }
        }
        return [PSCustomObject]@{ total_outstanding = $total; vendor_count = $vendors.Count; vendors = @($vendors) }
    } catch { Write-Warning "Failed to parse ap-aging.json: $_"; return $null }
}

function Parse-FixedAssetSchedule {
    param([string]$ReportsDir)
    $path = Join-Path $ReportsDir "fixed-asset-schedule.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
        $fas = $data.fixedassetschedule
        if (-not $fas) { return $null }
        $classes = @()
        foreach ($entry in $fas) {
            if ($entry.asset_class -or $entry.class) {
                $classes += [PSCustomObject]@{
                    class        = if ($entry.class) { [int]$entry.class } elseif ($entry.asset_class) { $entry.asset_class } else { 0 }
                    name         = $entry.name
                    opening_ucc  = [decimal]($entry.opening_balance -as [decimal])
                    additions    = [decimal]($entry.additions -as [decimal])
                    disposals    = [decimal]($entry.disposals -as [decimal])
                    depreciation = [decimal]($entry.depreciation -as [decimal])
                    closing_ucc  = [decimal]($entry.closing_balance -as [decimal])
                }
            }
        }
        return $classes
    } catch { Write-Warning "Failed to parse fixed-asset-schedule.json: $_"; return $null }
}

function Parse-PerAccountGLs {
    param([string]$ReportsDir)
    $results = @()
    $glFiles = Get-ChildItem -Path $ReportsDir -Filter "gl-*.json" | Where-Object { $_.Name -ne 'general-ledger.json' }
    foreach ($file in $glFiles) {
        try {
            $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($data.generalledger) {
                foreach ($acct in $data.generalledger) {
                    if ($acct.debit_total -eq 0 -and $acct.credit_total -eq 0) { continue }
                    $results += [PSCustomObject]@{
                        name         = $acct.name
                        account_id   = $acct.account_id
                        debit_total  = [decimal]$acct.debit_total
                        credit_total = [decimal]$acct.credit_total
                        balance      = [decimal]$acct.balance
                    }
                }
            }
        } catch { Write-Warning "Failed to parse $($file.Name): $_" }
    }

    # Also scan main GL for accounts not in per-account exports
    $fullGlPath = Join-Path $ReportsDir "general-ledger.json"
    if (Test-Path $fullGlPath) {
        try {
            $data = Get-Content $fullGlPath -Raw | ConvertFrom-Json
            $extraNames = @("Dividend", "Meals", "Entertainment", "Interest Income", "Shareholder Loan")
            if ($data.generalledger) {
                foreach ($acct in $data.generalledger) {
                    $alreadyFound = $results | Where-Object { $_.account_id -eq $acct.account_id } | Select-Object -First 1
                    if ($alreadyFound) { continue }
                    if ($acct.debit_total -eq 0 -and $acct.credit_total -eq 0) { continue }
                    foreach ($name in $extraNames) {
                        if ($acct.name -match $name) {
                            $results += [PSCustomObject]@{
                                name         = $acct.name
                                account_id   = $acct.account_id
                                debit_total  = [decimal]$acct.debit_total
                                credit_total = [decimal]$acct.credit_total
                                balance      = [decimal]$acct.balance
                            }
                            break
                        }
                    }
                }
            }
        } catch { Write-Warning "Failed to scan general-ledger.json for extra accounts: $_" }
    }
    return $results
}

# ── Self-test when run directly ───────────────────────────────────────
if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Invoke-T2Prep') {
    $bound = @{}; foreach ($k in $MyInvocation.BoundParameters.Keys) { $bound[$k] = $MyInvocation.BoundParameters[$k] }
    Invoke-T2Prep @bound
}
