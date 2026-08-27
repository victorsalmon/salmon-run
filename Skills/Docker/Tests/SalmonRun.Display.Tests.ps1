#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Skills", "Docker", "Modules")

    $script:DisplayModuleDir = Join-Path $__modulesDir "SalmonRun.Display"
    $script:DisplayPsd1 = Join-Path $script:DisplayModuleDir "SalmonRun.Display.psd1"
    $script:DisplayPublic = Join-Path $script:DisplayModuleDir "Public"

    # Dot-source both Public files
    Get-ChildItem -Path $script:DisplayPublic -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }
}

Describe "SalmonRun.Display Module Manifest" -Tag "Display", "Regression-Only" {

    It "psd1 file exists" {
        Test-Path $script:DisplayPsd1 | Should -Be $true
    }

    It "exports exactly 2 functions" {
        $manifest = Import-PowerShellDataFile -Path $script:DisplayPsd1
        $manifest.FunctionsToExport.Count | Should -Be 2
        $manifest.FunctionsToExport | Should -Contain "Write-ParallelSectionHeader"
        $manifest.FunctionsToExport | Should -Contain "Write-ParallelSectionSummary"
    }

    It "has a valid GUID" {
        $manifest = Import-PowerShellDataFile -Path $script:DisplayPsd1
        { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
    }
}

Describe "Write-ParallelSectionHeader" -Tag "Display" {

    It "can be dot-sourced without error" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionHeader.ps1")
        { Get-Command Write-ParallelSectionHeader } | Should -Not -Throw
    }

    It "accepts mandatory Title and Workers parameters" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionHeader.ps1")
        { Write-ParallelSectionHeader -Title "Test" -Workers @("W1") } | Should -Not -Throw
        { Write-ParallelSectionHeader -Workers @("W1") } | Should -Throw
        { Write-ParallelSectionHeader -Title "Test" } | Should -Throw
    }

    It "writes output without throwing" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionHeader.ps1")
        { Write-ParallelSectionHeader -Title "Test Section" -Workers @("Worker1","Worker2") } | Should -Not -Throw
    }
}

Describe "Write-ParallelSectionSummary" -Tag "Display" {

    It "can be dot-sourced without error" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionSummary.ps1")
        { Get-Command Write-ParallelSectionSummary } | Should -Not -Throw
    }

    It "accepts mandatory Title and Results parameters" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionSummary.ps1")
        { Write-ParallelSectionSummary -Title "Test" -Results @(@{Name="A"; Detail="ok"}) } | Should -Not -Throw
        { Write-ParallelSectionSummary -Results @(@{Name="A"}) } | Should -Throw
        { Write-ParallelSectionSummary -Title "Test" } | Should -Throw
    }

    It "writes output without throwing for array of results" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionSummary.ps1")
        { Write-ParallelSectionSummary -Title "Test" -Results @(@{Name="A"; Detail="ok"}) } | Should -Not -Throw
    }

    It "displays [FAIL] for results with Passed = false" {
        . (Join-Path $script:DisplayPublic "Write-ParallelSectionSummary.ps1")
        { Write-ParallelSectionSummary -Title "Test" -Results @(@{Name="B"; Detail="fail"; Passed=$false}) } | Should -Not -Throw
    }
}

Describe "Display functions accessible via canonical module" -Tag "Display", "Regression-Only" {

    It "both function names appear in SalmonRun.Display FunctionsToExport" {
        $manifest = Import-PowerShellDataFile -Path $script:DisplayPsd1
        $manifest.FunctionsToExport | Should -Contain "Write-ParallelSectionHeader"
        $manifest.FunctionsToExport | Should -Contain "Write-ParallelSectionSummary"
    }
}
