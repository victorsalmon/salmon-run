#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Modules'

    function Get-SalmonRunRepoRoot { return $__RepoRoot }

    Remove-Module 'SalmonRun.AQE' -Force -ErrorAction SilentlyContinue

    $script:AqePsd1 = Join-Path $__ModulesDir 'SalmonRun.AQE' 'SalmonRun.AQE.psd1'
    Import-Module $script:AqePsd1 -Force -ErrorAction Stop
}

Describe 'SalmonRun.AQE Module Manifest' -Tag 'AQE', 'Regression-Only' {
    It 'psd1 exists' {
        Test-Path $script:AqePsd1 | Should -Be $true
    }

    It 'exports the expected functions' {
        $manifest = Import-PowerShellDataFile -Path $script:AqePsd1
        $manifest.FunctionsToExport | Should -Contain 'Invoke-SalmonRunAQE'
        $manifest.FunctionsToExport | Should -Contain 'Invoke-SalmonRunPesterSuite'
        $manifest.FunctionsToExport | Should -Contain 'Invoke-SalmonRunDocLint'
        $manifest.FunctionsToExport | Should -Contain 'Invoke-SalmonRunAQEBridge'
    }
}

Describe 'Invoke-SalmonRunPesterSuite' -Tag 'AQE', 'Regression-Only' {
    It 'returns an empty summary when no test files are found' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty-tests') -Force
        $result = Invoke-SalmonRunPesterSuite -Path $td.FullName
        $result.Totals | Should -Be 0
        $result.Passed | Should -Be 0
        $result.Failed | Should -Be 0
    }
}

Describe 'Invoke-SalmonRunAQEBridge' -Tag 'AQE', 'Regression-Only' {
    It 'skips gracefully when the bridge URI is not configured' {
        $saved = $env:SALMON_AQE_BRIDGE_URI
        try {
            $env:SALMON_AQE_BRIDGE_URI = ''
            $result = Invoke-SalmonRunAQEBridge -Payload @{ test = $true }
            $result.Skipped | Should -Be $true
            $result.Reason | Should -Match 'not set'
        } finally {
            $env:SALMON_AQE_BRIDGE_URI = $saved
        }
    }
}

Describe 'Invoke-SalmonRunDocLint' -Tag 'AQE', 'Regression-Only' {
    It 'returns a result for the public salmon-run repo' {
        $result = Invoke-SalmonRunDocLint -RepoDir $__RepoRoot
        $result.Passed | Should -Not -Be $null
    }
}
