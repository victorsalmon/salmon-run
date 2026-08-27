#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeDiscovery {
    $baseDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { (Get-Location).Path }
    $script:reconTasPath     = Join-Path $baseDir "intersite-docs" "Taxes and Bookkeeping" "intersite-consulting" "TAS-2026.csv"
    $script:reconPeriodsPath = Join-Path $baseDir "intersite-docs" "Taxes and Bookkeeping" "intersite-consulting" "reconciliation-periods.md"
    $script:skipRecon        = (-not (Test-Path $script:reconTasPath)) -or (-not (Test-Path $script:reconPeriodsPath))
}

BeforeAll {
    $script:repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $reconCheckPath = Join-Path $script:repoRoot "Skills" "Bookkeeping" "Scripts" "reconciliation" "Invoke-ReconciliationCheck-TAS.ps1"
    $tasBuildPath   = Join-Path $script:repoRoot "Skills" "Bookkeeping" "Scripts" "reconciliation" "Build-IntersiteTAS.ps1"
    if (-not $script:skipRecon) {
        . $reconCheckPath
        . $tasBuildPath
    }
}

Describe "Convert-Date function" -Skip:$script:skipRecon -Tag "Bookkeeping", "Reconciliation", "Unit" {
    It "Converts M/D/YYYY to YYYY-MM-DD" {
        Convert-Date "1/13/2026" | Should -Be "2026-01-13"
    }
    It "Converts M/D/YYYY single-digit month" {
        Convert-Date "3/5/2026" | Should -Be "2026-03-05"
    }
    It "Passes through ISO dates unchanged" {
        Convert-Date "2026-01-13" | Should -Be "2026-01-13"
    }
    It "Handles Dec dates" {
        Convert-Date "12/25/2026" | Should -Be "2026-12-25"
    }
}

Describe "Room-rentals periods match reconciliation-periods.md" -Skip:$script:skipRecon -Tag "Bookkeeping", "Reconciliation", "Unit" {
    It "RBC-FRA has 5 periods ending at 2026-05-21" {
        $acct = $accounts["RBC-FRA"]
        $acct.periods.Count | Should -Be 5
        $acct.periods[-1].end | Should -Be "2026-05-21"
        $acct.periods[-1].closing | Should -Be 4115.75
    }
    It "TD-MLM has 5 periods ending at 2026-05-29" {
        $acct = $accounts["TD-MLM"]
        $acct.periods.Count | Should -Be 5
        $acct.periods[-1].end | Should -Be "2026-05-29"
        $acct.periods[-1].closing | Should -Be 4496.21
    }
    It "SCOTIA-TMH has 5 periods ending at 2026-05-20" {
        $acct = $accounts["SCOTIA-TMH"]
        $acct.periods.Count | Should -Be 5
        $acct.periods[-1].end | Should -Be "2026-05-20"
        $acct.periods[-1].closing | Should -Be 5642.10
    }
    It "RBC-VISA has 6 periods ending at 2026-06-09" {
        $acct = $accounts["RBC-VISA"]
        $acct.periods.Count | Should -Be 6
        $acct.periods[-1].end | Should -Be "2026-06-09"
        $acct.periods[-1].closing | Should -Be 180.32
    }
    It "RBC-FRA is not a credit card" {
        $accounts["RBC-FRA"].isCreditCard | Should -Be $false
    }
    It "RBC-VISA is a credit card" {
        $accounts["RBC-VISA"].isCreditCard | Should -Be $true
    }
}

Describe "Build-IntersiteTAS: zohoKeys scoping" -Skip:$script:skipRecon -Tag "Bookkeeping", "Reconciliation", "Regression", "Unit" {
    It "Add-ZohoKey stores account-scoped keys" {
        $script:zohoKeys = @{}
        $neg27 = -27.00
        Add-ZohoKey "2025-04-04" $neg27 "MC 6258 (MasterCard 6241)"
        $script:zohoKeys.ContainsKey("MC 6258 (MasterCard 6241)|2025-04-04|-27.00") | Should -Be $true
    }

    It "Test-ZohoKey finds matching account-scoped key" {
        $neg27 = -27.00
        Add-ZohoKey "2025-04-04" $neg27 "MC 6258 (MasterCard 6241)"
        Test-ZohoKey "2025-04-04" $neg27 "MC 6258 (MasterCard 6241)" | Should -Be $true
    }

    It "Cross-account same amount does not collide" {
        $script:zohoKeys = @{}
        $pos27 = 27.00; $neg27 = -27.00
        Add-ZohoKey "2025-04-04" $pos27 "RBC Intersite (Chequing 6632)"
        Add-ZohoKey "2025-04-04" $neg27 "MC 6258 (MasterCard 6241)"
        $script:zohoKeys.ContainsKey("RBC Intersite (Chequing 6632)|2025-04-04|27.00") | Should -Be $true
        $script:zohoKeys.ContainsKey("MC 6258 (MasterCard 6241)|2025-04-04|27.00") | Should -Be $false
        $script:zohoKeys.ContainsKey("MC 6258 (MasterCard 6241)|2025-04-04|-27.00") | Should -Be $true
    }

    It "No zohoKeys collision between accounts with same date+amount" {
        $script:zohoKeys = @{}
        $neg50 = -50.00
        Add-ZohoKey "2025-04-04" $neg50 "RBC Intersite (Chequing 6632)"
        Add-ZohoKey "2025-04-04" $neg50 "MC 6258 (MasterCard 6241)"
        $script:zohoKeys.Count | Should -Be 2
    }
}

Describe "Build-IntersiteTAS: Parse-RawFiscalYear signature" -Skip:$script:skipRecon -Tag "Bookkeeping", "Reconciliation", "Regression", "Unit" {
    It "Parse-RawFiscalYear accepts 3 parameters (filePath, acctLabel, sourceLabel)" {
        $params = (Get-Command Parse-RawFiscalYear).Parameters
        $params.ContainsKey("filePath") | Should -Be $true
        $params.ContainsKey("acctLabel") | Should -Be $true
        $params.ContainsKey("sourceLabel") | Should -Be $true
    }
}
