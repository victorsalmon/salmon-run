#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $scriptsDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $repoRoot "Skills") "Bookkeeper") "tax-filing") "draft-financials") "scripts"

    . (Join-Path $scriptsDir "Get-DraftT2Config.ps1")
    . (Join-Path $scriptsDir "Get-Schedule1NetIncome.ps1")
    . (Join-Path $scriptsDir "Get-Schedule8CCA.ps1")
    . (Join-Path $scriptsDir "Get-Schedule3Shareholder.ps1")
    . (Join-Path $scriptsDir "Get-Schedule4SBD.ps1")
    . (Join-Path $scriptsDir "Get-GSTReconciliation.ps1")
    . (Join-Path $scriptsDir "Get-PriorYearComparison.ps1")
    . (Join-Path $scriptsDir "New-DraftT2Worksheet.ps1")
    . (Join-Path $scriptsDir "Invoke-DraftT2Filing.ps1")

    $cfg = Get-DraftT2Config
}

Describe "Get-DraftT2Config" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Returns a config object with expected properties" {
        $cfg.entity | Should -Be "Intersite Consulting Inc."
        $cfg.fiscal_year_end | Should -Be "2026-03-31"
        $cfg.tax_rates.federal_part_i_rate_before_sbd | Should -Be 0.28
        $cfg.tax_rates.federal_small_business_deduction_rate | Should -Be 0.19
        $cfg.bc_tax_rates.bc_general_rate | Should -Be 0.12
        $cfg.bc_tax_rates.bc_small_business_rate | Should -Be 0.02
        $cfg.business_limits.federal | Should -Be 500000
        $cfg.business_limits.bc | Should -Be 500000
        $cfg.gst.rate | Should -Be 0.05
        $cfg.aii_threshold | Should -Be 50000
    }

    It "Returns GIFI mapping with income and expenses" {
        $cfg.gifi.income.Count | Should -Be 2
        $cfg.gifi.expenses.Count | Should -Be 12
        $cfg.gifi.income[0].gifi | Should -Be 8299
    }

    It "Returns CCA classes with 4 standard classes" {
        $cfg.cca_classes.Count | Should -Be 4
        $cfg.cca_classes[0].class | Should -Be 8
        $cfg.cca_classes[1].class | Should -Be 10
        $cfg.cca_classes[2].class | Should -Be 50
        $cfg.cca_classes[3].class | Should -Be 12
    }

    It "Returns GST vendor categories" {
        $cfg.gst_vendor_categories.Count | Should -BeGreaterThan 5
    }

    It "Accepts overrides via -Override" {
        $cfg2 = Get-DraftT2Config -Override @{ "tax_rates.federal_part_i_rate_before_sbd" = 0.18 }
        $cfg2.tax_rates.federal_part_i_rate_before_sbd | Should -Be 0.18
        $cfg2.business_limits.federal | Should -Be 500000  # unchanged
    }
}

Describe "Get-Schedule1NetIncome" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Computes net income from P&L data" {
        $pl = @{
            "Consulting Revenue" = 100000
            "Interest Income"    = 2000
            "Advertising"        = 3000
            "Automobile"         = 4000
            "Bank Fees"          = 500
            "Insurance"          = 2000
            "IT & Internet"      = 4000
            "Lease"              = 14000
            "Office Expenses"    = 1000
            "Professional Fees"  = 3000
            "Repairs & Maintenance" = 1000
            "Telephone"          = 800
            "Travel"             = 600
            "Other Expenses"     = 400
        }
        $s1 = Get-Schedule1NetIncome -Config $cfg -PandLData $pl
        $s1.income.consulting_revenue | Should -Be 100000
        $s1.income.interest_income | Should -Be 2000
        $s1.total_expenses | Should -Be 34300
        $s1.net_income_before_cca | Should -Be 67700
        $s1.net_income_for_tax_purposes | Should -Be 67700
    }

    It "Applies meals add-back adjustment" {
        $pl = @{ "Consulting Revenue" = 50000; "Advertising" = 1000 }
        $s1 = Get-Schedule1NetIncome -Config $cfg -PandLData $pl -MealsExpensesTotal 2000
        $s1.adjustments.meals_add_back | Should -Be 1000
        $s1.net_income_for_tax_purposes | Should -Be ($s1.net_income_before_cca + 1000)
    }

    It "Handles empty data gracefully" {
        $s1 = Get-Schedule1NetIncome -Config $cfg -PandLData @{}
        $s1.income.total_revenue | Should -Be 0
        $s1.total_expenses | Should -Be 0
    }
}

Describe "Get-Schedule8CCA" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Returns zero CCA when no classes provided" {
        $s8 = Get-Schedule8CCA -Config $cfg
        $s8.total_cca_claimed | Should -Be 0
        $s8.classes.Count | Should -Be 4
    }

    It "Computes CCA with half-year rule for additions" {
        $classes = @(
            @{ class = 8; rate = 0.20; opening_ucc = 15000; additions = 2000; disposals = 0 }
        )
        $s8 = Get-Schedule8CCA -Config $cfg -Classes $classes
        $s8.classes.Count | Should -Be 1
        # Declining balance: 15000 - 0 + (2000 * 0.5) = 16000
        # CCA: 16000 * 0.20 = 3200
        $s8.classes[0].ucc_before_cca | Should -Be 16000
        $s8.classes[0].cca_claimed | Should -Be 3200
        $s8.classes[0].closing_ucc | Should -Be 12800
    }

    It "Handles Class 12 as 100% immediate" {
        $classes = @(
            @{ class = 12; rate = 1.00; opening_ucc = 0; additions = 500; disposals = 0 }
        )
        $s8 = Get-Schedule8CCA -Config $cfg -Classes $classes
        $s8.classes[0].cca_claimed | Should -Be 500
        $s8.classes[0].closing_ucc | Should -Be 0
    }

    It "Handles disposals correctly" {
        $classes = @(
            @{ class = 10; rate = 0.30; opening_ucc = 8000; additions = 0; disposals = 1500 }
        )
        $s8 = Get-Schedule8CCA -Config $cfg -Classes $classes
        # Declining balance: 8000 - 1500 + 0 = 6500
        # CCA: 6500 * 0.30 = 1950
        $s8.classes[0].cca_claimed | Should -Be 1950
        $s8.classes[0].closing_ucc | Should -Be 4550
    }

    It "Applies half-year rule to additions only (not net of disposals)" {
        $classes = @(
            @{ class = 8; rate = 0.20; opening_ucc = 10000; additions = 2000; disposals = 500 }
        )
        $s8 = Get-Schedule8CCA -Config $cfg -Classes $classes
        # Declining balance: 10000 - 500 + (2000 * 0.5) = 10500
        # CCA: 10500 * 0.20 = 2100
        # Closing: 10500 - 2100 = 8400
        $s8.classes[0].ucc_before_cca | Should -Be 10500
        $s8.classes[0].cca_claimed | Should -Be 2100
        $s8.classes[0].closing_ucc | Should -Be 8400
    }
}

Describe "Get-Schedule3Shareholder" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Computes closing balance correctly" {
        $s3 = Get-Schedule3Shareholder -OpeningBalance 5000 -AdvancesTotal 12000 -RepaymentsTotal 8000 -DividendsTotal 15000
        $s3.closing_balance | Should -Be 9000
        $s3.non_eligible_dividends | Should -Be 15000
    }

    It "Produces correct schedule line numbers" {
        $s3 = Get-Schedule3Shareholder -OpeningBalance 5000 -AdvancesTotal 12000 -RepaymentsTotal 8000 -DividendsTotal 15000
        $s3.schedule_lines.line_170 | Should -Be 5000
        $s3.schedule_lines.line_180 | Should -Be 17000
        $s3.schedule_lines.line_186 | Should -Be 9000
        $s3.schedule_lines.line_270 | Should -Be 15000
    }

    It "Flags negative closing balance as company owes shareholder" {
        $s3 = Get-Schedule3Shareholder -OpeningBalance 1000 -AdvancesTotal 500 -RepaymentsTotal 3000 -DividendsTotal 0
        # closing = 1000 + 500 - 3000 = -1500 (repayments > advances → company owes shareholder)
        $s3.note | Should -Match "Company owes shareholder"
    }

    It "Flags positive closing balance as shareholder owes company" {
        $s3 = Get-Schedule3Shareholder -OpeningBalance 0 -AdvancesTotal 7614 -RepaymentsTotal 5020.06 -DividendsTotal 1959.36
        # closing = 0 + 7614 - 5020.06 = 2593.94 (advances > repayments → shareholder owes company)
        $s3.note | Should -Match "Shareholder owes company"
    }
}

Describe "Get-Schedule4SBD" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Computes SBD and tax estimate" {
        $s4 = Get-Schedule4SBD -Config $cfg -NetIncomeForTax 65000 -InterestIncome 1200 -InstalmentsPaid 4000
        $s4.active_business_income | Should -Be 63800
        $s4.aggregate_investment_income | Should -Be 1200
        $s4.sbd_federal_reduction | Should -BeGreaterThan 0
        $s4.sbd_provincial_reduction | Should -BeGreaterThan 0
        $s4.tax_estimate.total_tax_payable | Should -BeGreaterThan 0
    }

    It "Applies AII threshold reduction when AII > $50k" {
        $s4 = Get-Schedule4SBD -Config $cfg -NetIncomeForTax 200000 -InterestIncome 120000 -InstalmentsPaid 0
        $s4.business_limit_federal | Should -BeLessThan 500000
    }

    It "Handles zero income" {
        $s4 = Get-Schedule4SBD -Config $cfg -NetIncomeForTax 0 -InstalmentsPaid 0
        $s4.active_business_income | Should -Be 0
        $s4.tax_estimate.total_tax_payable | Should -Be 0
    }

    It "Reduces business limit precisely for partial AII excess over threshold" {
        $s4 = Get-Schedule4SBD -Config $cfg -NetIncomeForTax 500000 -InterestIncome 55000 -InstalmentsPaid 0
        # AII = 55000, excess = 5000, Ceiling(5000/10000) = 1, reduction = 5000
        # Limit = 500000 - 5000 = 495000
        $s4.business_limit_federal | Should -Be 495000
    }
}

Describe "Get-GSTReconciliation" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Computes GST and ITCs from expense data" {
        $expenses = @{
            "Zoho Canada"    = 2400
            "Petro-Canada"   = 3200
            "ICBC"           = 1800
            "OpenRouter Inc" = 600
            "RBC Royal Bank" = 300
        }
        $gst = Get-GSTReconciliation -Config $cfg -ConsultingRevenue 85000 -ExpensesByVendor $expenses
        $gst.gst_collected | Should -Be 4250
        $gst.itcs_claimed | Should -BeGreaterThan 0
        $gst.net_gst_remittable | Should -BeGreaterThan 0
    }

    It "Handles empty expenses" {
        $gst = Get-GSTReconciliation -Config $cfg -ConsultingRevenue 0 -ExpensesByVendor @{}
        $gst.gst_collected | Should -Be 0
        $gst.itcs_claimed | Should -Be 0
    }
}

Describe "Get-PriorYearComparison" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Compares current vs prior year" {
        $cy = @{ revenue = 85000; net_income = 45000; taxable_income = 42000; sbd_claimed = 30000; cca_claimed = 5000; dividends_paid = 15000; tax_payable = 4000 }
        $py = @{ revenue = 72000; net_income = 38000; taxable_income = 35000; sbd_claimed = 25000; cca_claimed = 4500; dividends_paid = 12000; tax_payable = 3500 }
        $comp = Get-PriorYearComparison -Config $cfg -CurrentYear $cy -PriorYearValues $py
        $comp.comparisons.revenue.variance_pct | Should -BeGreaterThan 0
        $comp.has_flags | Should -Be $false
    }

    It "Flags variance above threshold" {
        $cy = @{ revenue = 200000; net_income = 1000; taxable_income = 1000; sbd_claimed = 500; cca_claimed = 100; dividends_paid = 500; tax_payable = 100 }
        $py = @{ revenue = 50000; net_income = 1000; taxable_income = 1000; sbd_claimed = 500; cca_claimed = 100; dividends_paid = 500; tax_payable = 100 }
        $comp = Get-PriorYearComparison -Config $cfg -CurrentYear $cy -PriorYearValues $py
        $comp.has_flags | Should -Be $true
        $comp.variance_flags.Count | Should -BeGreaterThan 0
    }

    It "Handles empty data" {
        $comp = Get-PriorYearComparison -Config $cfg -CurrentYear @{} -PriorYearValues @{}
        $comp.has_flags | Should -Be $false
    }
}

Describe "New-DraftT2Worksheet" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Generates worksheet and JSON files" {
        $s1 = Get-Schedule1NetIncome -Config $cfg -PandLData @{ "Consulting Revenue" = 85000 }
        $s8 = Get-Schedule8CCA -Config $cfg
        $s3 = Get-Schedule3Shareholder -OpeningBalance 5000 -AdvancesTotal 12000 -RepaymentsTotal 8000 -DividendsTotal 15000
        $s4 = Get-Schedule4SBD -Config $cfg -NetIncomeForTax $s1.net_income_for_tax_purposes -InterestIncome 0
        $gst = Get-GSTReconciliation -Config $cfg -ConsultingRevenue 85000 -ExpensesByVendor @{}
        $comp = Get-PriorYearComparison -Config $cfg -CurrentYear @{ revenue=85000; net_income=45000; taxable_income=42000; sbd_claimed=30000; cca_claimed=5000; dividends_paid=15000; tax_payable=4000 } -PriorYearValues @{}

        $outDir = Join-Path $env:TEMP "draft-t2-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        $output = New-DraftT2Worksheet -Config $cfg -Schedule1 $s1 -Schedule8 $s8 -Schedule3 $s3 -Schedule4 $s4 -GST $gst -PriorYear $comp -OutputDir $outDir

        $output.worksheet_path | Should -Exist
        $output.json_path | Should -Exist

        # Verify JSON structure
        $json = Get-Content $output.json_path -Raw | ConvertFrom-Json
        $json.schedule_1.revenue_8299.amount | Should -Be 85000
        $json.schedule_3.opening_balance | Should -Be 5000

        # Verify markdown worksheet content — no raw PowerShell expressions
        $wsContent = Get-Content $output.worksheet_path -Raw
        $wsContent | Should -Not -Match 'System\.Collections\.Hashtable'
        $wsContent | Should -Match '\$85,000\.00'

        Remove-Item -Path $outDir -Recurse -Force
    }
}

Describe "Invoke-DraftT2Filing" -Tag "Bookkeeping", "T2Draft", "Regression-Only" {
    It "Runs full pipeline end-to-end" {
        $outDir = Join-Path $env:TEMP "draft-t2-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        $result = Invoke-DraftT2Filing -PandLData @{ "Consulting Revenue" = 85000 } -OpeningSHLBalance 5000 -DividendsTotal 15000 -InstalmentsPaid 4000 -OutputDir $outDir

        $result.schedule1 | Should -Not -Be $null
        $result.schedule8 | Should -Not -Be $null
        $result.schedule3 | Should -Not -Be $null
        $result.schedule4 | Should -Not -Be $null
        $result.gst | Should -Not -Be $null
        $result.prior_year_comparison | Should -Not -Be $null
        $result.output.worksheet_path | Should -Exist
        $result.output.json_path | Should -Exist

        Remove-Item -Path $outDir -Recurse -Force
    }
}
