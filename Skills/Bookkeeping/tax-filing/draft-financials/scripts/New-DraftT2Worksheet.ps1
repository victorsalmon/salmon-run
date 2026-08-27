<#
.SYNOPSIS
    Produces the Draft T2 Filing outputs: markdown worksheet + machine-readable JSON.
    Called by Invoke-DraftT2Filing (orchestrator) or directly by agent after running all schedule scripts.
    Owned by: Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-t2-filing.md
    See also: Get-DraftT2Config, Get-Schedule1NetIncome, Get-Schedule8CCA, Get-Schedule3Shareholder, Get-Schedule4SBD
.DESCRIPTION
    Takes all schedule calculation results and generates:
      - A formatted markdown worksheet at OutputDir/draft-filing-worksheet.md
      - A structured JSON schedules file at OutputDir/draft-t2-schedules.json
    The worksheet is designed for user review before CloudTax entry.
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER Schedule1
    Result from Get-Schedule1NetIncome.
.PARAMETER Schedule8
    Result from Get-Schedule8CCA.
.PARAMETER Schedule3
    Result from Get-Schedule3Shareholder.
.PARAMETER Schedule4
    Result from Get-Schedule4SBD.
.PARAMETER GST
    Result from Get-GSTReconciliation.
.PARAMETER PriorYear
    Result from Get-PriorYearComparison.
.PARAMETER OutputDir
    Output directory for generated files (default: current working directory).
.PARAMETER PassThru
    Return the worksheet content as a string instead of writing to file.
.EXAMPLE
    .\New-DraftT2Worksheet.ps1 -Config $cfg -Schedule1 $s1 -Schedule8 $s8 -Schedule3 $s3 -Schedule4 $s4 -GST $gst -PriorYear $py -OutputDir "C:\out"
.EXAMPLE
    .\New-DraftT2Worksheet.ps1 -Config $cfg -Schedule1 $s1 -Schedule8 $s8 -Schedule3 $s3 -Schedule4 $s4 -GST $gst -PriorYear $py -PassThru
#>
function New-DraftT2Worksheet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [Parameter(Mandatory)]
        [PSObject]$Schedule1,

        [Parameter(Mandatory)]
        [PSObject]$Schedule8,

        [Parameter(Mandatory)]
        [PSObject]$Schedule3,

        [Parameter(Mandatory)]
        [PSObject]$Schedule4,

        [Parameter(Mandatory)]
        [PSObject]$GST,

        [Parameter(Mandatory)]
        [PSObject]$PriorYear,

        [string]$OutputDir = ".",

        [switch]$PassThru
    )

    $fy = $Config.fiscal_year_end
    $entity = $Config.entity
    $nl = [Environment]::NewLine

    # --- Build markdown worksheet ---
    $md = @"
# Draft T2 Filing Worksheet
**$entity** — FY Ending $fy
*Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")*

---

## Summary

| Item | Amount |
|------|--------|
| Revenue | `$$([math]::Round($Schedule1.income.total_revenue, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Total Expenses | `$$([math]::Round($Schedule1.total_expenses, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Net Income (before CCA) | `$$([math]::Round($Schedule1.net_income_before_cca, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| CCA Claimed | `$$([math]::Round($Schedule8.total_cca_claimed, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Net Income for Tax Purposes | `$$([math]::Round($Schedule1.net_income_for_tax_purposes, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Taxable Income (ABI) | `$$([math]::Round($Schedule4.active_business_income, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| SBD Claimed (Fed + BC) | `$$([math]::Round($Schedule4.sbd_federal_reduction + $Schedule4.sbd_provincial_reduction, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Tax Payable | `$$([math]::Round($Schedule4.tax_estimate.total_tax_payable, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Instalments Paid | `$$([math]::Round($Schedule4.tax_estimate.instalments_paid, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Est. Refund / (Owing) | `$$([math]::Round($Schedule4.tax_estimate.estimated_refund_balance_owing, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Dividends Paid | `$$([math]::Round($Schedule3.non_eligible_dividends, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| SH Loan End Balance | `$$([math]::Round($Schedule3.closing_balance, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |

---

## Schedule 1 — Net Income (for Tax Purposes)

### Income

| Source | Amount | GIFI Line |
|--------|--------|-----------|
| Consulting Revenue | `$$([math]::Round($Schedule1.income.consulting_revenue, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` | 8299 |
| Interest Income | `$$([math]::Round($Schedule1.income.interest_income, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` | 8231 |
| **Total Revenue** | **`$$([math]::Round($Schedule1.income.total_revenue, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** | 8299 + 8231 |

### Expenses

| Category | Amount | GIFI Line |
|----------|--------|-----------|
"@

    $gifiExpenses = $Config.gifi.expenses
    foreach ($g in $gifiExpenses) {
        $cat = $g.label
        $line = $g.gifi
        $amt = if ($Schedule1.expenses.ContainsKey($cat)) { $Schedule1.expenses[$cat] } else { 0.0 }
        $md += "${nl}| $cat | `$$([math]::Round($amt, 2, [MidpointRounding]::AwayFromZero).ToString('N2')) | $line |"
    }

    $md += @"

| **Total Expenses** | **`$$([math]::Round($Schedule1.total_expenses, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** | **Sum** |

### Net Income Calculation

| Item | Amount |
|------|--------|
| Total Revenue | `$$([math]::Round($Schedule1.income.total_revenue, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Less: Total Expenses | (`$$([math]::Round($Schedule1.total_expenses, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`) |
| **Net Income (before CCA)** | **`$$([math]::Round($Schedule1.net_income_before_cca, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** |

### Adjustments

| Adjustment | Amount | Direction |
|-----------|--------|----------|
| Meals & entertainment (50% add-back) | `$$([math]::Round($Schedule1.adjustments.meals_add_back, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` | Add to income |
| CCA claimed vs Zoho depreciation | `$$([math]::Round($Schedule1.adjustments.cca_difference, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` | Per Schedule 8 |
| Non-deductible items | `$$([math]::Round($Schedule1.adjustments.non_deductible, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` | Add to income |
$(if ($Schedule1.adjustments.personal_use_add_back -gt 0) {
    $detail = ""
    $Schedule1.adjustments.personal_use_detail.PSObject.Properties | ForEach-Object {
        $d = $_.Value
        $detail += "`n| Personal use add-back ($($d.pct * 100)% of `$$($d.amount.ToString('N2')) $($_.Name)) | `$$($d.add_back.ToString('N2')) | Add to income |"
    }
    $detail
})
| **Total Adjustments** | **`$$([math]::Round($Schedule1.adjustments.total_adjustments, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** | |
| **Net Income for Tax Purposes (Line 360)** | **`$$([math]::Round($Schedule1.net_income_for_tax_purposes, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** | |

---

## Schedule 8 — Capital Cost Allowance

| Class | Rate | Opening UCC | Additions | Disposals | UCC Before CCA | CCA Claimed | Closing UCC |
|-------|------|-------------|-----------|-----------|----------------|-------------|-------------|
"@

    foreach ($c in $Schedule8.classes) {
        $md += "${nl}| Class $($c.class) | $($c.rate_label) | " +
            "`$$($c.opening_ucc.ToString('N2')) | " +
            "`$$($c.additions.ToString('N2')) | " +
            "`$$($c.disposals.ToString('N2')) | " +
            "`$$($c.ucc_before_cca.ToString('N2')) | " +
            "`$$($c.cca_claimed.ToString('N2')) | " +
            "`$$($c.closing_ucc.ToString('N2')) |"
    }

    $md += @"

| **Total** | | | | | | **`$$([math]::Round($Schedule8.total_cca_claimed, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))`** | |

---

## Schedule 3 — Shareholder Information

| Line | Description | Amount |
|------|-------------|--------|
| 170 | Balance at start of year | `$$($Schedule3.schedule_lines.line_170.ToString('N2'))` |
| 171–175 | Advances during year | `$$($Schedule3.schedule_lines.line_171_175.ToString('N2'))` |
| 180 | Balance before repayments | `$$($Schedule3.schedule_lines.line_180.ToString('N2'))` |
| 181–185 | Repayments during year | `$$($Schedule3.schedule_lines.line_181_185.ToString('N2'))` |
| 186 | Balance at end of year | `$$($Schedule3.schedule_lines.line_186.ToString('N2'))` |
| 270 | Non-eligible dividends paid | `$$($Schedule3.schedule_lines.line_270.ToString('N2'))` |

**Note**: $($Schedule3.note)

---

## Schedule 4 — Small Business Deduction

| Line | Description | Amount |
|------|-------------|--------|
| 400 | Active business income | `$$([math]::Round($Schedule4.active_business_income, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| 410–420 | Business limit (federal) | `$$([math]::Round($Schedule4.business_limit_federal, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| 430 | SBD reduction (federal) | `$$([math]::Round($Schedule4.sbd_federal_reduction, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| 440 | SBD reduction (provincial) | `$$([math]::Round($Schedule4.sbd_provincial_reduction, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |

### Tax Payable Estimate

| Item | Amount |
|------|--------|
| Net income for tax purposes | `$$([math]::Round($Schedule1.net_income_for_tax_purposes, 2, [MidpointRounding]::AwayFromZero).ToString('N2'))` |
| Federal Part I tax (@ $($Schedule4.tax_estimate.federal_part_i_rate_before_sbd * 100)%) | `$$($Schedule4.tax_estimate.part_i_tax_before_sbd.ToString('N2'))` |
| Less: SBD federal | (`$$($Schedule4.tax_estimate.sbd_reduction_federal.ToString('N2'))`) |
| Part I tax after SBD | `$$($Schedule4.tax_estimate.part_i_tax_after_sbd.ToString('N2'))` |
| BC general rate (@ $($Schedule4.tax_estimate.bc_general_rate * 100)%) | `$$($Schedule4.tax_estimate.bc_tax_before_sbd.ToString('N2'))` |
| Less: SBD BC | (`$$($Schedule4.tax_estimate.sbd_reduction_bc.ToString('N2'))`) |
| BC tax after SBD | `$$($Schedule4.tax_estimate.bc_tax_after_sbd.ToString('N2'))` |
| **Total Tax Payable** | **`$$($Schedule4.tax_estimate.total_tax_payable.ToString('N2'))`** |
| Instalments Paid | `$$($Schedule4.tax_estimate.instalments_paid.ToString('N2'))` |
| **Est. Refund / (Balance Owing)** | **`$$($Schedule4.tax_estimate.estimated_refund_balance_owing.ToString('N2'))`** |

---

## GST/HST Reconciliation

| Line | Description | Amount |
|------|-------------|--------|
| 103 | GST collected | `$$($GST.gst_collected.ToString('N2'))` |
| | ITCs claimed | `$$($GST.itcs_claimed.ToString('N2'))` |
| | Net GST remittable | `$$($GST.net_gst_remittable.ToString('N2'))` |
| | GST/HST Payable (BS) | `$$($GST.gst_payable_balance_sheet.ToString('N2'))` |

$(if ($GST.itcs_claimed -eq 0 -and $GST.gst_collected -gt 0) { "**Note**: ITCs shown as `$0.00 - no vendor-level expense data provided. ITCs may be understated." + $nl })$(if ($GST.gst_payable_balance_sheet -eq 0 -and $GST.gst_collected -gt 0) { "**Note**: GST/HST Payable (BS) shown as `$0.00 - verify against trial balance before filing." + $nl })
---

## Prior Year Comparison

| Metric | Prior Year | Current Year | Variance | Var % | Flag |
|--------|-----------|-------------|----------|-------|------|
"@

    foreach ($entry in $PriorYear.comparisons.PSObject.Properties) {
        $key = $entry.Name
        $val = $entry.Value
        $isFlagged = ($PriorYear.variance_flags | Where-Object { $_ -match "^$key" }) -ne $null
        $flagText = if ($isFlagged) { "⚠ Flagged" } else { "OK" }
        $md += "${nl}| $key | `$$($val.prior_year.ToString('N2')) | `$$($val.current_year.ToString('N2')) | `$$($val.variance.ToString('N2')) | $([math]::Round($val.variance_pct * 100, 1, [MidpointRounding]::AwayFromZero))% | $flagText |"
    }

    if ($PriorYear.variance_flags.Count -gt 0) {
        $flagLines = ($PriorYear.variance_flags | ForEach-Object { "- $_" }) -join "$nl"
        $md += @"

### Variance Flags

$flagLines
"@
    }

    $md += @"

---

*Draft generated by Get-DraftT2Config → Get-Schedule1NetIncome → Get-Schedule8CCA → Get-Schedule3Shareholder → Get-Schedule4SBD → Get-GSTReconciliation → Get-PriorYearComparison → New-DraftT2Worksheet*
"@

    # --- Build JSON output ---
    $json = [PSCustomObject]@{
        fiscal_year_end = $Config.fiscal_year_end
        entity          = $Config.entity

        schedule_1 = [PSCustomObject]@{
            revenue_8299   = [PSCustomObject]@{ label = "Gross Revenue";   amount = [math]::Round($Schedule1.income.consulting_revenue, 2, [MidpointRounding]::AwayFromZero) }
            other_income_8231 = [PSCustomObject]@{ label = "Other Income"; amount = [math]::Round($Schedule1.income.interest_income, 2, [MidpointRounding]::AwayFromZero) }
            expenses = [PSCustomObject]@{}
            total_expenses = [math]::Round($Schedule1.total_expenses, 2, [MidpointRounding]::AwayFromZero)
            net_income_before_cca = [math]::Round($Schedule1.net_income_before_cca, 2, [MidpointRounding]::AwayFromZero)
            net_income_for_tax_purposes = [math]::Round($Schedule1.net_income_for_tax_purposes, 2, [MidpointRounding]::AwayFromZero)
        }

        schedule_8 = [PSCustomObject]@{
            classes = @($Schedule8.classes | ForEach-Object {
                [PSCustomObject]@{
                    class        = $_.class
                    rate         = $_.rate
                    opening_ucc  = $_.opening_ucc
                    additions    = $_.additions
                    disposals    = $_.disposals
                    cca_claimed  = $_.cca_claimed
                    closing_ucc  = $_.closing_ucc
                }
            })
            total_cca_claimed = [math]::Round($Schedule8.total_cca_claimed, 2, [MidpointRounding]::AwayFromZero)
        }

        schedule_3 = [PSCustomObject]@{
            opening_balance       = [math]::Round($Schedule3.opening_balance, 2, [MidpointRounding]::AwayFromZero)
            advances_during_year  = [math]::Round($Schedule3.advances_during_year, 2, [MidpointRounding]::AwayFromZero)
            repayments_during_year = [math]::Round($Schedule3.repayments_during_year, 2, [MidpointRounding]::AwayFromZero)
            closing_balance       = [math]::Round($Schedule3.closing_balance, 2, [MidpointRounding]::AwayFromZero)
            non_eligible_dividends = [math]::Round($Schedule3.non_eligible_dividends, 2, [MidpointRounding]::AwayFromZero)
        }

        schedule_4 = [PSCustomObject]@{
            active_business_income     = [math]::Round($Schedule4.active_business_income, 2, [MidpointRounding]::AwayFromZero)
            aggregate_investment_income = [math]::Round($Schedule4.aggregate_investment_income, 2, [MidpointRounding]::AwayFromZero)
            business_limit_federal     = [math]::Round($Schedule4.business_limit_federal, 2, [MidpointRounding]::AwayFromZero)
            business_limit_bc          = [math]::Round($Schedule4.business_limit_bc, 2, [MidpointRounding]::AwayFromZero)
            sbd_federal_reduction      = [math]::Round($Schedule4.sbd_federal_reduction, 2, [MidpointRounding]::AwayFromZero)
            sbd_provincial_reduction   = [math]::Round($Schedule4.sbd_provincial_reduction, 2, [MidpointRounding]::AwayFromZero)
            business_limit_used        = [math]::Round($Schedule4.business_limit_used_federal, 2, [MidpointRounding]::AwayFromZero)
        }

        tax_estimate = [PSCustomObject]@{
            federal_part_i_rate_before_sbd   = [math]::Round($Schedule4.tax_estimate.federal_part_i_rate_before_sbd, 4, [MidpointRounding]::AwayFromZero)
            bc_general_rate                  = [math]::Round($Schedule4.tax_estimate.bc_general_rate, 4, [MidpointRounding]::AwayFromZero)
            part_i_tax_before_sbd            = [math]::Round($Schedule4.tax_estimate.part_i_tax_before_sbd, 2, [MidpointRounding]::AwayFromZero)
            sbd_reduction_federal            = [math]::Round($Schedule4.tax_estimate.sbd_reduction_federal, 2, [MidpointRounding]::AwayFromZero)
            part_i_tax_after_sbd             = [math]::Round($Schedule4.tax_estimate.part_i_tax_after_sbd, 2, [MidpointRounding]::AwayFromZero)
            bc_tax_before_sbd                = [math]::Round($Schedule4.tax_estimate.bc_tax_before_sbd, 2, [MidpointRounding]::AwayFromZero)
            sbd_reduction_bc                 = [math]::Round($Schedule4.tax_estimate.sbd_reduction_bc, 2, [MidpointRounding]::AwayFromZero)
            bc_tax_after_sbd                 = [math]::Round($Schedule4.tax_estimate.bc_tax_after_sbd, 2, [MidpointRounding]::AwayFromZero)
            total_tax_payable                = [math]::Round($Schedule4.tax_estimate.total_tax_payable, 2, [MidpointRounding]::AwayFromZero)
            instalments_paid                 = [math]::Round($Schedule4.tax_estimate.instalments_paid, 2, [MidpointRounding]::AwayFromZero)
            estimated_refund_balance_owing   = [math]::Round($Schedule4.tax_estimate.estimated_refund_balance_owing, 2, [MidpointRounding]::AwayFromZero)
        }

        gst_reconciliation = [PSCustomObject]@{
            gst_collected            = $GST.gst_collected
            itcs_claimed             = $GST.itcs_claimed
            net_gst_remittable       = $GST.net_gst_remittable
            gst_payable_balance_sheet = $GST.gst_payable_balance_sheet
        }

        prior_year_comparison = [PSCustomObject]@{
            revenue_variance_pct   = if ($PriorYear.comparisons.revenue) { $PriorYear.comparisons.revenue.variance_pct } else { 0.0 }
            net_income_variance_pct = if ($PriorYear.comparisons.net_income) { $PriorYear.comparisons.net_income.variance_pct } else { 0.0 }
            variance_flags          = @($PriorYear.variance_flags)
        }
    }

    # Populate expenses in JSON
    $expJson = @{}
    $expenseMap = @{
        "Advertising"           = "advertising_8520"
        "Automobile"            = "automobile_8530"
        "Interest & Bank Charges" = "interest_bank_charges_8710"
        "Insurance"             = "insurance_8690"
        "IT & Internet"         = "it_internet_8810"
        "Lease"                 = "lease_8720"
        "Office & General"      = "office_general_8810"
        "Professional Fees"     = "professional_fees_8860"
        "Repairs & Maintenance" = "repairs_maintenance_8960"
        "Telephone"             = "telephone_9220"
        "Travel"                = "travel_8880"
        "Other Expenses"        = "other_expenses_9275"
    }
    foreach ($kv in $expenseMap.GetEnumerator()) {
        $amt = if ($Schedule1.expenses.ContainsKey($kv.Key)) { $Schedule1.expenses[$kv.Key] } else { 0.0 }
        $expJson[$kv.Value] = [math]::Round($amt, 2, [MidpointRounding]::AwayFromZero)
    }
    $json.schedule_1.expenses = [PSCustomObject]$expJson

    # --- Write outputs ---
    if ($PassThru) {
        return $md
    }

    $wsPath = Join-Path $OutputDir "draft-filing-worksheet.md"
    $jsonPath = Join-Path $OutputDir "draft-t2-schedules.json"

    # Add metadata stamp before writing JSON output
    $jsonObj = [PSCustomObject]@{
        _metadata = [PSCustomObject]@{
            generated_at = (Get-Date -Format "o")
            data_source  = "Local reconciled books ($entity fiscal $fyStart-$fyEnd)"
            entity       = $entity
            fiscal_year  = "$fyStart-$fyEnd"
            script       = "New-DraftT2Worksheet.ps1"
            version      = "2026-06-30"
        }
    }
    $json.PSObject.Properties | ForEach-Object { $jsonObj | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force }
    $md | Out-File -FilePath $wsPath -Encoding utf8
    $jsonObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8

    return [PSCustomObject]@{
        worksheet_path = (Resolve-Path $wsPath).Path
        json_path      = (Resolve-Path $jsonPath).Path
        content        = $md
        json_content   = $json
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\New-DraftT2Worksheet') {
    Write-Warning "New-DraftT2Worksheet requires all schedule results. Use the orchestrator (Invoke-DraftT2Filing) instead."
}

