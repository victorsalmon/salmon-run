#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $scriptsDir = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\reconciliation"
}

Describe "Build-HelocInterestJournal" -Tag "Bookkeeping", "YearEnd" {
    It "Exists as a parseable PowerShell script" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $path | Should -Exist
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "Requires -TotalInterest parameter" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true) | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'TotalInterest'
        }
        $params | Should -Not -BeNullOrEmpty
    }

    It "Has DryRun switch" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\[switch\]\$DryRun'
    }

    It "Has PassThru switch" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\[switch\]\$PassThru'
    }

    It "Defaults booksRoot to userprofile intersite-docs path" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\$env:USERPROFILE\\intersite-docs'
    }

    It "Filters Mortgage/HELOC categories correctly" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\$cat -match.*mortgage'
        $content | Should -Match '\$cat -match.*HELOC'
    }

    It "Outputs a summary with total payments and interest ratio" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match 'Total Mortgage/HELOC Payments'
        $content | Should -Match 'Interest Ratio'
    }

    It "Generates a proposed journal entry with debit/credit" {
        $path = Join-Path $scriptsDir "Build-HelocInterestJournal.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match 'Proposed Journal Entry'
        $content | Should -Match 'Debit.*Credit'
        $content | Should -Match 'Mortgage Interest'
    }
}

Describe "Invoke-T776Prep" -Tag "Bookkeeping", "YearEnd" {
    It "Exists as a parseable PowerShell script" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $path | Should -Exist
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "Accepts room-rentals organization only" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "ValidateSet\('room-rentals'\)"
    }

    It "Has DryRun switch" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\[switch\]\$DryRun'
    }

    It "Has PassThru switch" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\[switch\]\$PassThru'
    }

    It "Defaults to USERPROFILE intersite-docs path" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match '\$env:USERPROFILE'
    }

    It "Maps Rent Income/Rent Revenue to T776 line 8000" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Rent Income'.*8000"
        $content | Should -Match "'Rent Revenue'.*8000"
    }

    It "Maps Mortgage Interest to T776 line 8710" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Mortgage Interest'.*8710"
    }

    It "Maps Insurance to T776 line 8690" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Insurance'.*8690"
    }

    It "Maps Property Tax and Strata Fees to T776 line 8810" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Property Tax'.*8810"
        $content | Should -Match "'Strata Fees'.*8810"
    }

    It "Maps Repairs to T776 line 8870" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Repairs and Maintenance'.*8870"
    }

    It "Excludes Mortgage, Transfer Out, Credit Card Payment from T776" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match "'Mortgage'"
        $content | Should -Match "'Transfer Out'"
        $content | Should -Match "'Credit Card Payment'"
    }

    It "Outputs summary with gross rents and net rental income" {
        $path = Join-Path $scriptsDir "Invoke-T776Prep.ps1"
        $content = Get-Content $path -Raw
        $content | Should -Match 'Gross Rents'
        $content | Should -Match 'Net Rental Income'
    }
}

Describe "Room-Rentals Year-End Tasks File" -Tag "Bookkeeping", "YearEnd", "docs" {
    It "Exists with populated placeholders" {
        $path = Join-Path $repoRoot "Tasks\ToDo\room-rentals-year-end-tasks.md"
        $path | Should -Exist
        $content = Get-Content $path -Raw
        $content | Should -Not -Match 'to be populated as work progresses'
    }

    It "Documents Build-HelocInterestJournal.ps1 usage" {
        $path = Join-Path $repoRoot "Tasks\ToDo\room-rentals-year-end-tasks.md"
        $content = Get-Content $path -Raw
        $content | Should -Match 'Build-HelocInterestJournal'
    }

    It "Documents Invoke-T776Prep.ps1 usage" {
        $path = Join-Path $repoRoot "Tasks\ToDo\room-rentals-year-end-tasks.md"
        $content = Get-Content $path -Raw
        $content | Should -Match 'Invoke-T776Prep'
    }

    It "References the ready-for-manual-review rubric" {
        $path = Join-Path $repoRoot "Tasks\ToDo\room-rentals-year-end-tasks.md"
        $content = Get-Content $path -Raw
        $content | Should -Match 'ready-for-manual-review'
    }
}
