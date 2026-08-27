#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Display Module" -Tag "Display", "Regression-Only" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.Display' 'SalmonRun.Display.psd1'
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }

    AfterAll {
        Remove-Module SalmonRun.Display -Force -ErrorAction SilentlyContinue
    }

    It "exports the two display functions" {
        $manifestPath = Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.Display' 'SalmonRun.Display.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.FunctionsToExport | Should -Contain 'Write-ParallelSectionHeader'
        $manifest.FunctionsToExport | Should -Contain 'Write-ParallelSectionSummary'
        $manifest.Author | Should -Be 'Salmon Run'
    }

    It "Write-ParallelSectionHeader writes to the information stream" {
        $output = Write-ParallelSectionHeader -Title 'Test' -Workers @('A', 'B') 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match 'Test'
        $joined | Should -Match 'A'
        $joined | Should -Match 'B'
    }

    It "Write-ParallelSectionSummary renders result objects" {
        $results = @(
            [pscustomobject]@{ Name = 'A'; Detail = 'ok'; Passed = $true },
            [pscustomobject]@{ Name = 'B'; Detail = 'bad'; Passed = $false }
        )
        $output = Write-ParallelSectionSummary -Title 'Results' -Results $results 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match '\[OK\]\s+A:\s+ok'
        $joined | Should -Match '\[FAIL\]\s+B:\s+bad'
    }

    It "Write-ParallelSectionSummary renders plain strings" {
        $output = Write-ParallelSectionSummary -Title 'Strings' -Results @('one', 'two') 6>&1
        $joined = $output -join "`n"
        $joined | Should -Match 'one'
        $joined | Should -Match 'two'
    }
}
