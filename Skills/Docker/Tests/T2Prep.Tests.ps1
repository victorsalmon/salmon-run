#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $scriptsDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $repoRoot "Skills") "Bookkeeper") "tax-filing") "draft-financials") "scripts"

    . (Join-Path $scriptsDir "Invoke-T2Prep.ps1")

    $testReportsDir = Join-Path $PSScriptRoot "fixtures\t2-prep-test-reports"
}

Describe "Parse-TaxSummary" -Tag "Bookkeeping", "T2Prep", "Regression-Only" {
    It "Returns null when tax-summary.json does not exist" {
        $result = Parse-TaxSummary -ReportsDir "C:\nonexistent"
        $result | Should -Be $null
    }

    It "Returns null when tax-summary.json has no taxsummary data" {
        $dir = Join-Path $testReportsDir "empty"
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        @{ } | ConvertTo-Json | Out-File -FilePath (Join-Path $dir "tax-summary.json") -Encoding utf8
        $result = Parse-TaxSummary -ReportsDir $dir
        $result | Should -Be $null
    }
}

Describe "Parse-ARAging" -Tag "Bookkeeping", "T2Prep", "Regression-Only" {
    It "Returns null when ar-aging.json does not exist" {
        $result = Parse-ARAging -ReportsDir "C:\nonexistent"
        $result | Should -Be $null
    }

    It "Parses AR aging with customer entries" {
        $dir = Join-Path $testReportsDir "ar-test"
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $agingData = @{
            accountsreceivableaging = @(
                @{ customer_name = "Client A"; total = "1500.00"; current = "1500.00" }
                @{ customer_name = "Client B"; total = "750.00"; current = "0"; aging_periods = @(@{ range = "31-60"; total = "750.00" }) }
            )
        }
        $agingData | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $dir "ar-aging.json") -Encoding utf8

        $result = Parse-ARAging -ReportsDir $dir
        $result.total_outstanding | Should -Be 2250.00
        $result.customer_count | Should -Be 2
    }
}

Describe "Parse-APAging" -Tag "Bookkeeping", "T2Prep", "Regression-Only" {
    It "Returns null when ap-aging.json does not exist" {
        $result = Parse-APAging -ReportsDir "C:\nonexistent"
        $result | Should -Be $null
    }
}

Describe "Parse-FixedAssetSchedule" -Tag "Bookkeeping", "T2Prep", "Regression-Only" {
    It "Returns null when fixed-asset-schedule.json does not exist" {
        $result = Parse-FixedAssetSchedule -ReportsDir "C:\nonexistent"
        $result | Should -Be $null
    }

    It "Parses fixed asset schedule with class entries" {
        $dir = Join-Path $testReportsDir "fas-test"
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $fasData = @{
            fixedassetschedule = @(
                @{ class = 8; name = "Class 8 (20%)"; opening_balance = "15000.00"; additions = "2000.00"; disposals = "0"; depreciation = "3000.00"; closing_balance = "14000.00" }
                @{ class = 10; name = "Class 10 (30%)"; opening_balance = "8000.00"; additions = "0"; disposals = "1500.00"; depreciation = "1800.00"; closing_balance = "4700.00" }
            )
        }
        $fasData | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $dir "fixed-asset-schedule.json") -Encoding utf8

        $result = Parse-FixedAssetSchedule -ReportsDir $dir
        $result.Count | Should -Be 2
        $result[0].class | Should -Be 8
        $result[0].opening_ucc | Should -Be 15000.00
        $result[1].class | Should -Be 10
    }
}

Describe "Parse-PerAccountGLs" -Tag "Bookkeeping", "T2Prep", "Regression-Only" {
    It "Returns empty array when no GL files exist" {
        $result = Parse-PerAccountGLs -ReportsDir "C:\nonexistent"
        $result.Count | Should -Be 0
    }

    It "Parses per-account GL files" {
        $dir = Join-Path $testReportsDir "gl-test"
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

        $glData = @{
            generalledger = @(
                @{ name = "Shareholder Loan"; account_id = "93310000000146154"; debit_total = 12000.00; credit_total = 8000.00; balance = 4000.00; is_debit = $true }
            )
        }
        $glData | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $dir "gl-shl.json") -Encoding utf8

        $result = Parse-PerAccountGLs -ReportsDir $dir
        $result.Count | Should -Be 1
        $result[0].name | Should -Match "Shareholder"
        $result[0].debit_total | Should -Be 12000.00
    }
}
