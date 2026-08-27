<#
.SYNOPSIS
    Generates per-schedule CSV sidecars with full source attribution for T2 draft filing.
.DESCRIPTION
    Produces machine-readable CSVs that trace every figure back to its source
    (Zoho account ID, TAS line, prior year extraction, or pipeline calculation).
    Each CSV is self-documenting with comment headers showing formulas and data lineage.

    Files generated (in OutputDir):
      {entity}-{fyyear}-sidecar-schedule1.csv  — Net Income line-by-line
      {entity}-{fyyear}-sidecar-schedule3.csv  — Shareholder loan + dividends
      {entity}-{fyyear}-sidecar-schedule4.csv  — SBD + tax payable calculation
      {entity}-{fyyear}-sidecar-schedule8.csv  — CCA per class
      {entity}-{fyyear}-sidecar-gst.csv        — GST/HST reconciliation
      {entity}-{fyyear}-sidecar-manifest.csv   — SHA256 checksums of all source files

.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER PandLData
    P&L hashtable keyed by account name (from DraftReports or TAS).
.PARAMETER ZohoReportsDir
    Path to Zoho JSON exports (for account IDs and GL detail).
.PARAMETER Schedule1
    Schedule 1 result object.
.PARAMETER Schedule3
    Schedule 3 result object.
.PARAMETER Schedule4
    Schedule 4 result object.
.PARAMETER Schedule8
    Schedule 8 result object.
.PARAMETER GST
    GST reconciliation result object.
.PARAMETER TASPath
    Path to TAS-2026.csv (optional, for cross-reference).
.PARAMETER PriorYearExtractionPath
    Path to prior year T2 extraction markdown (for CCA source attribution).
.PARAMETER OutputDir
    Directory to write sidecar CSV files. Default: <intersite-docs>/.../T2/
.PARAMETER PassThru
    Return hashtable of content strings instead of writing files.

.EXAMPLE
    # Full generation after running Invoke-DraftT2Filing
    Export-T2Sidecars -Config $cfg -PandLData $pandLData -ZohoReportsDir $zohoDir `
        -Schedule1 $s1 -Schedule3 $s3 -Schedule4 $s4 -Schedule8 $s8 -GST $gst

.EXAMPLE
    # For a new tax year, call from orchestrator:
    $result = Invoke-DraftT2Filing
    Export-T2Sidecars -Config $result.config -PandLData $pl `
        -Schedule1 $result.schedule1 -Schedule3 $result.schedule3 `
        -Schedule4 $result.schedule4 -Schedule8 $result.schedule8 -GST $result.gst
#>
function Export-T2Sidecars {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [hashtable]$PandLData = @{},

        [string]$ZohoReportsDir,

        [Parameter(Mandatory)]
        [PSObject]$Schedule1,

        [Parameter(Mandatory)]
        [PSObject]$Schedule3,

        [Parameter(Mandatory)]
        [PSObject]$Schedule4,

        [Parameter(Mandatory)]
        [PSObject]$Schedule8,

        [Parameter(Mandatory)]
        [PSObject]$GST,

        [string]$TASPath,

        [string]$PriorYearExtractionPath,

        [string]$OutputDir,

        [switch]$PassThru
    )

    # --- Resolve paths ---
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")
    $intersiteDocs = Join-Path $repoRoot "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting"
    if (-not $OutputDir) {
        $OutputDir = Join-Path $intersiteDocs "2026 Filing\T2"
    }
    if (-not (Test-Path $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }

    $entity     = $Config.entity
    $fyEnd      = $Config.fiscal_year_end
    $fyYear     = $fyEnd.Substring(0, 4)
    $prefix     = "intersite-fy${fyYear}-sidecar"

    if (-not $ZohoReportsDir) {
        $candidate = Join-Path $intersiteDocs "2026 Filing\2026-zoho-reports"
        if (Test-Path $candidate) { $ZohoReportsDir = $candidate }
    }

    if (-not $TASPath) {
        $c = Join-Path $intersiteDocs "TAS-2026.csv"
        if (Test-Path $c) { $TASPath = $c }
    }

    $result = @{}
    $sourceFiles = @{}
    $nl = [Environment]::NewLine

    # ═══════════════════════════════════════════════════════════════════
    # Schedule 1 — Net Income
    # ═══════════════════════════════════════════════════════════════════
    $s1 = @()

    # Header comments
    $s1 += "# Schedule 1 — Net Income (for Tax Purposes)"
    $s1 += "# Entity: $entity"
    $s1 += "# Fiscal Year: $($Config.fiscal_year_end)"
    $s1 += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $s1 += "# Source: Zoho P&L (DraftReports) + T2 pipeline"
    $s1 += "# GIFI mapping: prior year (2025) filed T2 Schedule 125 — corrected 2026-06-08"
    $s1 += "# See: tax-year-${fyYear}.psd1 for authoritative mapping"
    $s1 += "#"
    $s1 += "# Columns: type,section,category,gifi,zoho_account_id,amount,formula,source_file,matching_transaction,notes"

    $totalRev = [decimal]0
    $totalExp = [decimal]0

    # Revenue rows
    $s1 += "# --- Income ---"
    $gifiIncome = $Config.gifi.income
    foreach ($g in $gifiIncome) {
        $acctName = $g.account
        $gifiCode = $g.gifi
        $label    = $g.label
        # Try to match by the P&L account name
        $matchedKey = $PandLData.Keys | Where-Object { $_ -match $acctName -or $acctName -match $_ } | Select-Object -First 1
        $amt = if ($matchedKey) { [decimal]$PandLData[$matchedKey] } else { [decimal]0 }
        $zohoId = ""
        $srcFile = ""
        if ($g.type -eq "revenue") {
            $totalRev += [math]::Abs($amt)
        } elseif ($g.type -eq "other_income") {
            $totalRev += [math]::Abs($amt)
        }
        $s1 += "revenue,income,$label,$gifiCode,$zohoId,$amt,,profit-and-loss.json,,"
    }

    $s1 += "summary,income,Total Revenue,,,$totalRev,,,=SUM(revenue),,"

    # Expense rows
    $s1 += "# --- Expenses ---"
    foreach ($g in $Config.gifi.expenses) {
        $acctName = $g.account
        $gifiCode = $g.gifi
        $label    = $g.label
        # Split regex patterns (e.g., "Bank Fees|Bank Fees and Charges")
        $patterns = $acctName -split '\|'
        $matchedKey = $null
        foreach ($pat in $patterns) {
            $matchedKey = $PandLData.Keys | Where-Object { $_ -match $pat } | Select-Object -First 1
            if ($matchedKey) { break }
        }
        $amt = if ($matchedKey) { [decimal][math]::Abs([decimal]$PandLData[$matchedKey]) } else { [decimal]0 }
        $zohoId = ""
        $s1 += "expense,expense,$label,$gifiCode,$zohoId,$amt,,profit-and-loss.json,,"
        $totalExp += $amt
    }

    $s1 += "summary,expense,Total Expenses,,,$totalExp,,,=SUM(expenses),,"
    $s1 += "summary,net_income_before_cca,,,$($Schedule1.net_income_before_cca),,,=TotalRevenue - TotalExpenses,,"

    # Adjustments
    $s1 += "# --- Adjustments ---"
    $s1 += "adjustment,adjustment,Meals add-back (50%),,,$($Schedule1.adjustments.meals_add_back),,pipeline,,"
    $s1 += "adjustment,adjustment,CCA difference (book - CCA),,,$($Schedule1.adjustments.cca_difference),,pipeline,,=book_depreciation - CCA_claimed"
    $s1 += "adjustment,adjustment,Non-deductible items,,,$($Schedule1.adjustments.non_deductible_items),,pipeline,,"
    $s1 += "summary,adjustment,Total Adjustments,,,$($Schedule1.adjustments.total_adjustments),,,=SUM(adjustments),,"
    $s1 += "summary,net_income_for_tax,Net Income for Tax Purposes,360,,$($Schedule1.net_income_for_tax_purposes),,,=NetIncomeBeforeCCA + TotalAdjustments,,"

    Write-Host "  Schedule 1: $($s1.Length) rows"

    # ═══════════════════════════════════════════════════════════════════
    # Schedule 8 — Capital Cost Allowance
    # ═══════════════════════════════════════════════════════════════════
    $s8 = @()
    $s8 += "# Schedule 8 — Capital Cost Allowance"
    $s8 += "# Entity: $entity"
    $s8 += "# Fiscal Year: $($Config.fiscal_year_end)"
    $s8 += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $s8 += "# Source: Prior year T2 Schedule 8 extraction"
    if ($PriorYearExtractionPath) { $s8 += "# Prior year file: $PriorYearExtractionPath" }
    $s8 += "#"
    $s8 += "# Method: Declining balance with half-year rule"
    $s8 += "# Half-year rule: additions * 50% in first year (except Class 12: 100%)"
    $s8 += "#"
    $s8 += "# Opening UCC derivation (from prior year closing UCC):"
    foreach ($c in $Schedule8.classes) {
        if ($c.opening_ucc -gt 0) {
            $rate = $c.rate
            $prevCCA = [math]::Round($c.opening_ucc * $rate / (1 - $rate), 2, [MidpointRounding]::AwayFromZero)
            $s8 += "#   Class $($c.class): Opening ~$($c.opening_ucc) * $($rate*100)% = CCA ~$($c.cca_claimed)"
        }
    }
    $s8 += "#"
    $s8 += "# Columns: class,rate_pct,rate,opening_ucc,additions,disposals,ucc_before_cca,cca_claimed,closing_ucc,half_year_adj,formula,opening_ucc_source"

    foreach ($c in $Schedule8.classes) {
        $ratePct = if ($c.rate -eq 1.0) { "100%" } else { "$([math]::Round($c.rate * 100))%" }
        $formula = if ($c.additions -gt 0) {
            "${c.rate_pct} of ($($c.opening_ucc) - $($c.disposals) + $($c.additions)*50%)"
        } else {
            "${ratePct} of ($($c.opening_ucc) - $($c.disposals))"
        }
        $openSrc = if ($c.opening_ucc -gt 0) { "Prior year T2 S8 closing" } else { "Default (zero)" }
        $s8 += "$($c.class),$ratePct,$($c.rate),$($c.opening_ucc),$($c.additions),$($c.disposals),$($c.ucc_before_cca),$($c.cca_claimed),$($c.closing_ucc),$($c.half_year_adj),$formula,$openSrc"
    }

    $totalCCA = $Schedule8.total_cca_claimed
    $totalOpening = [math]::Round(($Schedule8.classes | ForEach-Object { [decimal]$_.opening_ucc } | Measure-Object -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
    $totalClosing = [math]::Round(($Schedule8.classes | ForEach-Object { [decimal]$_.closing_ucc } | Measure-Object -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
    $s8 += "total,,,,$totalOpening,0,0,,$totalCCA,$totalClosing,,,"
    Write-Host "  Schedule 8: $($s8.Length) rows"

    # ═══════════════════════════════════════════════════════════════════
    # Schedule 3 — Shareholder Information
    # ═══════════════════════════════════════════════════════════════════
    $s3 = @()
    $s3 += "# Schedule 3 — Shareholder Information"
    $s3 += "# Entity: $entity"
    $s3 += "# Fiscal Year: $($Config.fiscal_year_end)"
    $s3 += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $s3 += "# Source: Zoho GL (account-transactions-shareholder-loan.json) + Zoho TB (Dividends)"
    $s3 += "# Shareholder Loan account: 93310000000146154"
    $s3 += "# Dividends account: 93310000000146151"
    $s3 += "#"
    $s3 += "# Columns: line,description,amount,source,source_account_id,source_file,matching_transaction,formula"

    $s3 += "170,Balance at start of year,$($Schedule3.opening_balance),Prior year Schedule 3 line 186,,,,"
    $s3 += "171-175,Advances during year,$($Schedule3.advances_during_year),Zoho GL debit_total,93310000000146154,account-transactions-shareholder-loan.json,,"
    $s3 += "180,Balance before repayments,$($Schedule3.schedule_lines.line_180),,,,,=170+171-175"
    $s3 += "181-185,Repayments during year,$($Schedule3.repayments_during_year),Zoho GL credit_total,93310000000146154,account-transactions-shareholder-loan.json,,"
    $s3 += "186,Balance at end of year,$($Schedule3.closing_balance),,,,,=180-181-185"
    $s3 += "270,Non-eligible dividends paid,$($Schedule3.non_eligible_dividends),Zoho TB Dividends Paid debit,93310000000146151,trial-balance.json,,"
    $s3 += "note,Note,$($Schedule3.note),,,,,"
    Write-Host "  Schedule 3: $($s3.Length) rows"

    # ═══════════════════════════════════════════════════════════════════
    # Schedule 4 — Small Business Deduction & Tax Payable
    # ═══════════════════════════════════════════════════════════════════
    $s4 = @()
    $s4 += "# Schedule 4 — Small Business Deduction & Tax Payable Estimate"
    $s4 += "# Entity: $entity"
    $s4 += "# Fiscal Year: $($Config.fiscal_year_end)"
    $s4 += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $s4 += "#"
    $s4 += "# Tax rates from: tax-year-${fyYear}.psd1"
    $s4 += "# Federal Part I rate: 38% - 10% abatement = $(($Config.tax_rates.federal_part_i_rate_before_sbd * 100))%"
    $s4 += "# SBD federal reduction: $(($Config.tax_rates.federal_small_business_deduction_rate * 100))%"
    $s4 += "# BC general rate: $(($Config.bc_tax_rates.bc_general_rate * 100))%"
    $s4 += "# BC small business rate: $(($Config.bc_tax_rates.bc_small_business_rate * 100))%"
    $s4 += "#   SBD BC reduction: $(($Config.bc_tax_rates.bc_general_rate * 100))% - $(($Config.bc_tax_rates.bc_small_business_rate * 100))% = $((($Config.bc_tax_rates.bc_general_rate - $Config.bc_tax_rates.bc_small_business_rate) * 100))%"
    $s4 += "# Business limits: Federal `$($($Config.business_limits.federal.ToString('N0'))), BC `$($($Config.business_limits.bc.ToString('N0')))"
    $s4 += "#"
    $s4 += "# Columns: line,description,amount,formula,source,matching_transaction"

    $abi   = $Schedule4.active_business_income
    $blFed = $Config.business_limits.federal
    $blBc  = $Config.business_limits.bc
    $sbdFedRate = $Config.tax_rates.federal_small_business_deduction_rate
    $sbdBcRate  = $Config.bc_tax_rates.bc_general_rate - $Config.bc_tax_rates.bc_small_business_rate
    $fedRate    = $Config.tax_rates.federal_part_i_rate_before_sbd
    $bcRate     = $Config.bc_tax_rates.bc_general_rate

    $s4 += "400,Active business income,$abi,= Schedule 1 line 360 (Net Income for Tax Purposes),Schedule 1,"
    $s4 += "410,Business limit (federal),$blFed,CCPC not associated - standard limit,tax-year-${fyYear}.psd1,"
    $s4 += "426,Business limit used,$abi,= MIN(ABI, business_limit, ABI before AII reduction),calculation,"
    $s4 += "430,SBD federal reduction,$($Schedule4.sbd_federal_reduction),= MIN(ABI, limit) * ${sbdFedRate},= ${abi} * ${sbdFedRate},"
    $s4 += "440,SBD BC reduction,$($Schedule4.sbd_provincial_reduction),= MIN(ABI, limit) * ${sbdBcRate},= ${abi} * ${sbdBcRate},"

    # Tax payable breakdown
    $s4 += "# --- Tax Payable Calculation ---"
    $ptBefore = [math]::Round($abi * $fedRate, 2, [MidpointRounding]::AwayFromZero)
    $s4 += "tax,Part I tax before SBD,$($Schedule4.tax_estimate.part_i_tax_before_sbd),= ${abi} * ${fedRate} = ${ptBefore},"
    $s4 += "tax,Less: SBD federal,$($Schedule4.tax_estimate.sbd_reduction_federal),= -$($Schedule4.sbd_federal_reduction),"
    $s4 += "tax,Part I tax after SBD,$($Schedule4.tax_estimate.part_i_tax_after_sbd),,"
    $s4 += "tax,BC tax before SBD,$($Schedule4.tax_estimate.bc_tax_before_sbd),= ${abi} * ${bcRate},"
    $s4 += "tax,Less: SBD BC,$($Schedule4.tax_estimate.sbd_reduction_bc),= -$($Schedule4.sbd_provincial_reduction),"
    $s4 += "tax,BC tax after SBD,$($Schedule4.tax_estimate.bc_tax_after_sbd),,"
    $s4 += "tax,Total Tax Payable,$($Schedule4.tax_estimate.total_tax_payable),,"
    $s4 += "tax,Instalments Paid,$($Schedule4.tax_estimate.instalments_paid),,"
    $s4 += "tax,Est. Refund/(Owing),$($Schedule4.tax_estimate.estimated_refund_balance_owing),= TotalTax - Instalments,"
    Write-Host "  Schedule 4: $($s4.Length) rows"

    # ═══════════════════════════════════════════════════════════════════
    # GST/HST Reconciliation
    # ═══════════════════════════════════════════════════════════════════
    $gstRows = @()
    $gstRows += "# GST/HST Reconciliation"
    $gstRows += "# Entity: $entity"
    $gstRows += "# Fiscal Year: $($Config.fiscal_year_end)"
    $gstRows += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $gstRows += "#"
    $gstRows += "# GST rate: $($Config.gst.rate * 100)% (federal only - BC no PST)"
    $gstRows += "# Method: GST collected = revenue * rate (simplified)"
    $gstRows += "# ITCs: 5/105 reverse calculation from vendor-level expense data"
    $gstRows += "#"
    $gstRows += "# Columns: line,description,amount,formula,source,matching_transaction,notes"

    $gstRev   = $Schedule1.income.total_revenue
    $gstRate  = $Config.gst.rate
    $gstColl  = [math]::Round($gstRev * $gstRate, 2, [MidpointRounding]::AwayFromZero)

    $gstRows += "101,Taxable sales (GST-excl),$gstRev,= Consulting Revenue,Schedule 1,"
    $gstRows += "103,GST collected (5%),$gstColl,= ${gstRev} * ${gstRate},calculation,"
    $gstRows += "106,ITCs claimed,$($GST.itcs_claimed),5/105 of GST-included expenses,GST pipeline,"
    $gstRows += "109,Net GST remittable,$($GST.net_gst_remittable),= 103 - 106,calculation,"
    $gstRows += "115,GST/HST Payable (BS),$($GST.gst_payable_balance_sheet),From Zoho trial balance,trial-balance.json,Verify before filing"
    Write-Host "  GST: $($gstRows.Length) rows"

    # ═══════════════════════════════════════════════════════════════════
    # Source Manifest
    # ═══════════════════════════════════════════════════════════════════
    $manifest = @()
    $manifest += "# Source File Manifest — SHA256 checksums"
    $manifest += "# Entity: $entity"
    $manifest += "# Fiscal Year: $($Config.fiscal_year_end)"
    $manifest += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $manifest += "#"
    $manifest += "# Columns: file_type,file_path,sha256,notes"

    $sourcePaths = @{
        "Tax Year Config"           = Join-Path $PSScriptRoot "..\tax-year-${fyYear}.psd1"
        "P&L (DraftReports)"        = Join-Path $intersiteDocs "2026 Filing\draft-reports-output\profit-and-loss.json"
        "Trial Balance"             = Join-Path $intersiteDocs "2026 Filing\2026-zoho-reports\trial-balance.json"
        "SHL GL"                    = Join-Path $intersiteDocs "2026 Filing\2026-zoho-reports\account-transactions-shareholder-loan.json"
        "Fixed Asset Schedule"      = Join-Path $intersiteDocs "2026 Filing\2026-zoho-reports\fixed-asset-schedule.json"
        "TAS"                       = $TASPath
        "Draft Worksheet"           = Join-Path $OutputDir "draft-filing-worksheet.md"
        "Draft JSON Schedules"      = Join-Path $OutputDir "draft-t2-schedules.json"
    }

    foreach ($kv in $sourcePaths.GetEnumerator()) {
        if ($kv.Value -and (Test-Path $kv.Value)) {
            try {
                $hash = (Get-FileHash $kv.Value -Algorithm SHA256).Hash
                $manifest += "$($kv.Key),$($kv.Value),$hash,"
            } catch {
                $manifest += "$($kv.Key),$($kv.Value),ERROR: $_ ,"
            }
        } else {
            $manifest += "$($kv.Key),,NOT_FOUND,"
        }
    }

    # ── Write all files ──────────────────────────────────────────────
    $files = @{
        "${prefix}-schedule1.csv"   = $s1 -join $nl
        "${prefix}-schedule3.csv"   = $s3 -join $nl
        "${prefix}-schedule4.csv"   = $s4 -join $nl
        "${prefix}-schedule8.csv"   = $s8 -join $nl
        "${prefix}-gst.csv"         = $gstRows -join $nl
        "${prefix}-manifest.csv"    = $manifest -join $nl
    }

    if ($PassThru) { return $files }

    foreach ($kv in $files.GetEnumerator()) {
        $path = Join-Path $OutputDir $kv.Key
        $kv.Value | Out-File -FilePath $path -Encoding utf8
        Write-Host "  Wrote: $path"
    }

    Write-Host "Generated $($files.Count) sidecar files in $OutputDir" -ForegroundColor Green

    # Return paths
    $files.Keys | ForEach-Object {
        [PSCustomObject]@{
            File     = $_
            Path     = Join-Path $OutputDir $_
            Size     = if (Test-Path (Join-Path $OutputDir $_)) { (Get-Item (Join-Path $OutputDir $_)).Length } else { 0 }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# Self-test / direct execution
# ═══════════════════════════════════════════════════════════════════════
if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Export-T2Sidecars') {
    Write-Host "Export-T2Sidecars requires pipeline data. Call from Invoke-T2Prep or Invoke-DraftT2Filing." -ForegroundColor Yellow
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  . .\Export-T2Sidecars.ps1" -ForegroundColor Gray
    Write-Host '  Export-T2Sidecars -Config $cfg -PandLData $pl `' -ForegroundColor Gray
    Write-Host '      -Schedule1 $s1 -Schedule3 $s3 -Schedule4 $s4 -Schedule8 $s8 -GST $gst' -ForegroundColor Gray
}

