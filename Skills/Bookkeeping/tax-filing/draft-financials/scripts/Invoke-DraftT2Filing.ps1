<#
.SYNOPSIS
    Orchestrator - runs the full Draft T2 Filing pipeline end-to-end.
.DESCRIPTION
    Coordinates all 7 schedule scripts in sequence and produces the final
    draft worksheet + JSON output. Auto-discovers P&L data, dividends, and
    instalments from DraftReports output or Zoho exports when not explicitly
    provided. Manual override parameters take precedence over auto-discovery.
    Designed to be called from the draft-t2-filing skill.
.PARAMETER Config
    Optional pre-loaded config object. If omitted, auto-loads from Get-DraftT2Config.
.PARAMETER PandLData
    P&L data hashtable keyed by account name. If omitted, auto-loads from
    DraftReports output (preferred) or Zoho exports.
.PARAMETER ManifestCSV
    Path to manifest-enriched.csv. Used only if -PandLData is not provided.
.PARAMETER ZohoReportsDir
    Path to Zoho JSON exports directory. Auto-discovered from default path
    if not specified.
.PARAMETER OpeningSHLBalance
    Shareholder loan opening balance (default 0).
.PARAMETER DividendsTotal
    Non-eligible dividends paid during year. Auto-discovered from trial
    balance if at default (0) and Zoho reports are available.
.PARAMETER InstalmentsPaid
    Total income tax instalments paid. Auto-discovered from trial balance
    if at default (0) and Zoho reports are available. NOTE: defaults to $0;
    if no instalment account exists in Zoho, stays $0.
.PARAMETER MealsExpensesTotal
    Total meals & entertainment (for 50% add-back, default 0).
.PARAMETER CCADifference
    CCA vs depreciation difference (from Schedule 8, default 0).
.PARAMETER OutputDir
    Output directory for generated files (default: current dir).
.PARAMETER PassThru
    Return content instead of writing.
.EXAMPLE
    # Auto-discover everything from DraftReports / Zoho exports
    Invoke-DraftT2Filing

    # Manual override for specific values
    Invoke-DraftT2Filing -PandLData @{ "Consulting Revenue" = 85000 } -OpeningSHLBalance 5000
#>
function Invoke-DraftT2Filing {
    [CmdletBinding()]
    param(
        [PSObject]$Config,
        [hashtable]$PandLData,
        [string]$ManifestCSV,
        [string]$ZohoReportsDir,
        [decimal]$OpeningSHLBalance = 0,
        [decimal]$DividendsTotal = 0,
        [decimal]$InstalmentsPaid = 0,
        [decimal]$MealsExpensesTotal = 0,
        [decimal]$CCADifference = 0,
        [string]$OutputDir = ".",
        [switch]$PassThru
    )

    # --- Load config if not provided ---
    $config = $Config
    if (-not $config) { $config = Get-DraftT2Config }

    # --- Step 1: Load P&L data ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Loading P&L data" -PercentComplete 5
    $pl = $PandLData
    if (-not $pl -and $ManifestCSV) {
        $pl = @{}
        Import-Csv $ManifestCSV | ForEach-Object { $pl[$_.account_name] = [decimal]$_.amount }
    }

    # Auto-discover from DraftReports output or Zoho exports
    if (-not $pl) {
        $baseDir = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")
        $intersiteDocs = Join-Path $baseDir "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing"

        # Resolve Zoho reports directory
        if (-not $ZohoReportsDir) {
            $candidate = Join-Path $intersiteDocs "2026-zoho-reports"
            if (Test-Path $candidate) { $ZohoReportsDir = $candidate }
        }

        # Try DraftReports output first (parsed format, preferred)
        $draftOutput = Join-Path $intersiteDocs "draft-reports-output"
        if (Test-Path (Join-Path $draftOutput "profit-and-loss.json")) {
            Write-Host "  Auto-discovering P&L data from DraftReports output: $draftOutput" -ForegroundColor Cyan
            $pnl = Get-Content (Join-Path $draftOutput "profit-and-loss.json") -Raw | ConvertFrom-Json
            $pl = @{}
            if ($pnl.revenue) {
                $pnl.revenue.PSObject.Properties | ForEach-Object { $pl[$_.Name] = [decimal]$_.Value }
            }
            if ($pnl.expenses) {
                $pnl.expenses.PSObject.Properties | ForEach-Object { $pl[$_.Name] = [decimal]$_.Value }
            }
        } elseif ($ZohoReportsDir -and (Test-Path (Join-Path $ZohoReportsDir "profit-and-loss.json"))) {
            Write-Host "  Auto-discovering P&L data from Zoho exports: $ZohoReportsDir" -ForegroundColor Cyan
            # Use Invoke-DraftReports parser to extract P&L from raw Zoho format
            $reportsScript = Join-Path $PSScriptRoot "Invoke-DraftReports.ps1"
            if (Test-Path $reportsScript) {
                . $reportsScript
                $reports = Invoke-DraftReports -ZohoReportsDir $ZohoReportsDir -OutputDir $draftOutput
                if ($reports -and $reports.profit_and_loss) {
                    $pl = @{}
                    $reports.profit_and_loss.revenue.PSObject.Properties | ForEach-Object { $pl[$_.Name] = [decimal]$_.Value }
                    $reports.profit_and_loss.expenses.PSObject.Properties | ForEach-Object { $pl[$_.Name] = [decimal]$_.Value }
                }
            }
        }

        if ($pl -and $pl.Count -gt 0) {
            Write-Host "  Auto-discovered $($pl.Count) P&L accounts" -ForegroundColor Green
        } else {
            Write-Warning "No P&L data found. Pass -PandLData or -ManifestCSV, or ensure DraftReports / Zoho exports are available."
            $pl = @{}
        }
    }

    # --- Auto-discover DividendsTotal, InstalmentsPaid, and SHL data from trial balance + GL ---
    # Only when params are at default (not explicitly passed by caller)
    $psBound = $MyInvocation.BoundParameters
    $dividendsDiscovered = $false
    $instalmentsDiscovered = $false
    $shlDiscovered = $false
    $shlAdvances = 0
    $shlRepayments = 0

    $tbSrc = if ($ZohoReportsDir) { Join-Path $ZohoReportsDir "trial-balance.json" } else { $null }
    if (-not $tbSrc -or -not (Test-Path $tbSrc)) {
        # Try DraftReports output
        $baseDirOverride = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")
        $intersiteDocs = Join-Path $baseDirOverride "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing"
        $tbSrc = Join-Path (Join-Path $intersiteDocs "draft-reports-output") "trial-balance.json"
        if (-not (Test-Path $tbSrc)) {
            $tbSrc = Join-Path $intersiteDocs "2026-zoho-reports\trial-balance.json"
        }
    }
    # Re-resolve intersiteDocs for SHL discovery (may not have been set above)
    if (-not $intersiteDocs) {
        $baseDirOverride = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")
        $intersiteDocs = Join-Path $baseDirOverride "..\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing"
    }

    if (Test-Path $tbSrc) {
        $tbData = Get-Content $tbSrc -Raw | ConvertFrom-Json
        $tbAccounts = @()
        if ($tbData.accounts) {
            $tbAccounts = $tbData.accounts  # DraftReports parsed format
        } elseif ($tbData.trialbalance) {
            $tbAccounts = $tbData.trialbalance[0].account_transactions |
                Select-Object -ExpandProperty account_transactions |
                Where-Object { -not $_.is_parent -and -not $_.is_retained_earnings }
        }

        # Dividends: look for "Dividends Paid" or "Dividends" account
        if (-not $psBound.ContainsKey('DividendsTotal') -or $DividendsTotal -eq 0) {
            $divAcct = $tbAccounts | Where-Object { $_.name -match 'Dividend' } | Select-Object -First 1
            if ($divAcct) {
                $divVal = if ($divAcct.debit_total -and $divAcct.debit_total -ne '') { [decimal]$divAcct.debit_total }
                         elseif ($divAcct.net_debit_total -and $divAcct.net_debit_total -ne '') { [decimal]$divAcct.net_debit_total }
                         else { 0 }
                if ($divVal -gt 0) {
                    Write-Host "  Auto-discovered DividendsTotal: `$$divVal (from $($divAcct.name))" -ForegroundColor Cyan
                    $DividendsTotal = $divVal
                    $dividendsDiscovered = $true
                }
            }
            if (-not $dividendsDiscovered) {
                Write-Host "  No dividends account found in trial balance — DividendsTotal stays 0" -ForegroundColor DarkGray
            }
        }

        # Instalments: look for "Corporate Income Tax Payable" credit balance
        if (-not $psBound.ContainsKey('InstalmentsPaid') -or $InstalmentsPaid -eq 0) {
            # CRA instalments are typically tracked in a separate account or as payments
            # against CIT Payable. If no instalment-specific account exists, stay at $0.
            $citAcct = $tbAccounts | Where-Object { $_.name -match 'CIT|Instalment|Income Tax' } | Select-Object -First 1
            if ($citAcct) {
                $citBalance = if ($citAcct.credit_total -and $citAcct.credit_total -ne '') { [decimal]$citAcct.credit_total }
                              elseif ($citAcct.net_credit_total -and $citAcct.net_credit_total -ne '') { [decimal]$citAcct.net_credit_total }
                              else { 0 }
                # CIT Payable with a credit balance means tax OWED, not instalments PAID.
                # Only count as instalments if there's a debit balance (prepaid/instalments).
                if ($citBalance -lt 0) {
                    $InstalmentsPaid = [math]::Abs($citBalance)
                    Write-Host "  Auto-discovered InstalmentsPaid: `$$InstalmentsPaid (from $($citAcct.name) debit)" -ForegroundColor Cyan
                    $instalmentsDiscovered = $true
                }
            }
            if (-not $instalmentsDiscovered) {
                Write-Host "  No CRA instalment prepayment found — InstalmentsPaid stays 0" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Warning "Trial balance not found at $tbSrc — dividends, instalments, and SHL data all default to 0."
    }

    # --- Auto-discover SHL gross flows from Zoho GL (balance sheet — not in P&L) ---
    if ($ZohoReportsDir) {
        # Try named SHL export first (from sync-local-books-from-zoho.mjs naming pattern)
        $shlCandidates = @(
            Join-Path $ZohoReportsDir "account-transactions-shareholder-loan.json"
        )
        # Also check general-ledger.json for a Shareholder Loan section
        $fullGlPath = Join-Path $ZohoReportsDir "general-ledger.json"
        if (Test-Path $fullGlPath) { $shlCandidates += $fullGlPath }

        $shlSource = $null
        foreach ($cand in $shlCandidates) {
            if (Test-Path $cand) { $shlSource = $cand; break }
        }

        if ($shlSource) {
            $shlData = Get-Content $shlSource -Raw | ConvertFrom-Json
            $shlEntry = $null
            if ($shlData.generalledger) {
                $shlEntry = $shlData.generalledger | Where-Object { $_.name -match 'Shareholder Loan|Shareholder' } | Select-Object -First 1
            }

            if ($shlEntry -and $shlEntry.debit_total -and $shlEntry.debit_total -ne '') {
                $rawDebits = [decimal]$shlEntry.debit_total
                $rawCredits = [decimal]$shlEntry.credit_total
                if ($rawDebits -gt 0 -or $rawCredits -gt 0) {
                    $shlAdvances = $rawDebits
                    $shlRepayments = $rawCredits
                    Write-Host "  Auto-discovered SHL gross flows: advances `$$shlAdvances, repayments `$$shlRepayments (from $([System.IO.Path]::GetFileName($shlSource)))" -ForegroundColor Cyan
                    $shlDiscovered = $true
                }
            }
        }
        if (-not $shlDiscovered) {
            Write-Host "  No SHL GL data found in Zoho reports — SHL advances/repayments default to 0" -ForegroundColor DarkGray
        }
    }

    # --- Step 2: Schedule 8 - CCA (must run before S1 for CCA difference) ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Schedule 8 - Capital Cost Allowance" -PercentComplete 20
    $ccaClasses = $config.cca_classes | ForEach-Object {
        @{
            class       = $_.class
            rate        = $_.rate
            opening_ucc = $_.opening_ucc
            additions   = $_.additions
            disposals   = $_.disposals
        }
    }
    $schedule8 = Get-Schedule8CCA -Config $config -Classes $ccaClasses

    # CCA difference = book depreciation - CCA claimed. Zoho has no book depreciation, so = 0 - CCA
    if ($CCADifference -eq 0 -and $schedule8.total_cca_claimed -gt 0) {
        $CCADifference = -$schedule8.total_cca_claimed
    }

    # --- Step 3: Schedule 1 - Net Income ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Schedule 1 - Net Income" -PercentComplete 35
    $personalUsePcts = if ($config.personal_use_percentages) { $config.personal_use_percentages.PSObject.Properties | ForEach-Object -Begin { $h = @{} } -Process { $h[$_.Name] = $_.Value } -End { $h } } else { @{} }
    $schedule1 = Get-Schedule1NetIncome -Config $config -PandLData $pl `
        -MealsExpensesTotal $MealsExpensesTotal -CCADifference $CCADifference `
        -PersonalUsePercentages $personalUsePcts

    # --- Step 4: Schedule 3 - Shareholder ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Schedule 3 - Shareholder" -PercentComplete 50
    # Use auto-discovered SHL GL data if available (covers balance sheet accounts the P&L misses)
    # Falls back to P&L hashtable for backward compat with manual -PandLData overrides
    $shlAdvancesFinal = if ($shlDiscovered) { $shlAdvances } elseif ($pl.ContainsKey("Shareholder Loan")) { [decimal]$pl["Shareholder Loan"] } else { 0 }
    $shlRepaymentsFinal = if ($shlDiscovered) { $shlRepayments } else { 0 }
    $schedule3 = Get-Schedule3Shareholder -OpeningBalance $OpeningSHLBalance `
        -AdvancesTotal $shlAdvancesFinal -RepaymentsTotal $shlRepaymentsFinal -DividendsTotal $DividendsTotal

    # --- Step 5: Schedule 4 - SBD ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Schedule 4 - Small Business Deduction" -PercentComplete 65
    $interestIncome = if ($pl.ContainsKey("Interest Income")) { [decimal]$pl["Interest Income"] } else { 0 }
    $schedule4 = Get-Schedule4SBD -Config $config `
        -NetIncomeForTax $schedule1.net_income_for_tax_purposes `
        -InterestIncome $interestIncome -InstalmentsPaid $InstalmentsPaid

    # --- Step 6: GST Reconciliation ---
    Write-Progress -Activity "Draft T2 Filing" -Status "GST Reconciliation" -PercentComplete 80
    $consultingRevenue = if ($pl.ContainsKey("Consulting Revenue")) { [decimal]$pl["Consulting Revenue"] } else { 0 }
    Write-Host "  GST: no expense-by-vendor data in orchestrator — ITCs will be $0 unless loaded via DraftReports or -ExpensesCSV" -ForegroundColor DarkGray
    $gst = Get-GSTReconciliation -Config $config -ConsultingRevenue $consultingRevenue -ExpensesByVendor @{}

    # --- Diagnostic: flag Schedule 8 all-zeros when prior year had CCA ---
    if ($schedule8.total_cca_claimed -eq 0 -and $config.prior_year.cca_claimed -gt 0) {
        Write-Warning "CCA claimed is `$0 but prior year claimed `$$($config.prior_year.cca_claimed). No opening UCC data was loaded. Verify fixed asset register or prior year Schedule 8."
    }
    if ($schedule3.closing_balance -eq 0 -and -not $shlDiscovered -and $schedule3.non_eligible_dividends -gt 0) {
        Write-Warning "Schedule 3 shows `$0 SHL balance but dividends were paid (`$$($schedule3.non_eligible_dividends)). Verify SHL GL data is available."
    }

    # --- Step 7: Prior Year Comparison ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Prior Year Comparison" -PercentComplete 90
    $currentYear = @{
        revenue        = $schedule1.income.total_revenue
        net_income     = $schedule1.net_income_for_tax_purposes
        cca_claimed    = $schedule8.total_cca_claimed
        sbd_claimed    = $schedule4.sbd_federal_reduction + $schedule4.sbd_provincial_reduction
        taxable_income = $schedule4.active_business_income
        dividends_paid = $schedule3.non_eligible_dividends
        tax_payable    = $schedule4.tax_estimate.total_tax_payable
        instalments    = $InstalmentsPaid
        refund         = $schedule4.tax_estimate.estimated_refund_balance_owing
    }
    $pyParams = @{ Config = $config; CurrentYear = $currentYear }
    if ($config.prior_year) { $pyParams.PriorYearValues = $config.prior_year.PSObject.Properties | ForEach-Object -Begin { $h = @{} } -Process { $h[$_.Name] = $_.Value } -End { $h } }
    $priorYear = Get-PriorYearComparison @pyParams

    # --- Step 8: Generate outputs ---
    Write-Progress -Activity "Draft T2 Filing" -Status "Generating outputs" -PercentComplete 100
    $result = New-DraftT2Worksheet -Config $config -Schedule1 $schedule1 -Schedule8 $schedule8 `
        -Schedule3 $schedule3 -Schedule4 $schedule4 -GST $gst -PriorYear $priorYear `
        -OutputDir $OutputDir -PassThru:$PassThru

    # --- Diagnostic summary: flag suspicious $0 values ---
    $zeroFlags = @()
    if ($schedule1.income.total_revenue -eq 0) { $zeroFlags += "Total revenue is `$0 — no income data loaded" }
    if ($schedule1.total_expenses -eq 0 -and $schedule1.income.total_revenue -gt 0) { $zeroFlags += "Total expenses is `$0 with non-zero revenue — expense mapping may be missing" }
    if ($schedule1.net_income_for_tax_purposes -eq 0 -and $schedule1.income.total_revenue -gt 0) { $zeroFlags += "Net income is `$0 — revenue was fully offset or expense mapping incomplete" }
    if ($schedule4.tax_estimate.total_tax_payable -eq 0 -and $schedule1.net_income_for_tax_purposes -gt 0) { $zeroFlags += "Total tax payable is `$0 with positive net income — SBD may fully offset (verify business limit not exceeded)" }
    if ($gst.gst_collected -eq 0 -and $schedule1.income.total_revenue -gt 0) { $zeroFlags += "GST collected is `$0 — consulting revenue not passed to GST calculation" }
    if ($gst.itcs_claimed -eq 0 -and $gst.gst_collected -gt 0) { $zeroFlags += "ITCs claimed is `$0 with positive GST collected — no expense-by-vendor data provided" }
    if ($schedule3.closing_balance -eq 0 -and $schedule3.non_eligible_dividends -gt 0 -and -not $shlDiscovered) { $zeroFlags += "SHL closing balance is `$0 despite dividends — GL data may be missing" }
    if ($schedule8.total_cca_claimed -eq 0 -and $config.prior_year.cca_claimed -gt 0) { $zeroFlags += "CCA claimed is `$0 but prior year claimed `$$($config.prior_year.cca_claimed)" }

    if ($zeroFlags.Count -gt 0) {
        Write-Host "" -NoNewline
        Write-Host "  ⚠ DRAFT DIAGNOSTICS:" -ForegroundColor Yellow
        foreach ($f in $zeroFlags) {
            Write-Host "     - $f" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    return [PSCustomObject]@{
        config    = $config
        schedule1 = $schedule1
        schedule8 = $schedule8
        schedule3 = $schedule3
        schedule4 = $schedule4
        gst       = $gst
        prior_year_comparison = $priorYear
        output    = $result
        diagnostics = $zeroFlags
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Invoke-DraftT2Filing') {
    Invoke-DraftT2Filing
}
