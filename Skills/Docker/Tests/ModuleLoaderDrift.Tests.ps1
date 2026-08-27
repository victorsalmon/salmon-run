#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $DriftScript = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Private\Test-ModuleLoaderDrift.ps1"
    $RepoRoot = Resolve-Path "$PSScriptRoot\..\.."
}

Describe "Test-ModuleLoaderDrift" -Tag "Core", "Regression-Only" {
    It "script file exists" {
        $DriftScript | Should -Exist
    }

    It "loads without error" {
        { . $DriftScript } | Should -Not -Throw
    }

    It "reports zero drifted modules" {
        . $DriftScript
        Test-ModuleLoaderDrift | Should -Be $true
    }

    It "all modules have both .psm1 and .ps1 loaders" {
        . $DriftScript
        $results = Test-ModuleLoaderDrift -PassThru
        $missing = $results | Where-Object DriftType -eq 'MissingLoader'
        $missing.Count | Should -Be 0 -Because "all scanned modules must have both loader files"
    }

    It "classifies known wrapper modules correctly" {
        . $DriftScript
        $results = Test-ModuleLoaderDrift -PassThru
        $wrapperModules = @('SalmonRun.Constants', 'SalmonRun.Config', 'SalmonRun.Core', 'SalmonRun.Host',
                            'Interclaw.Constants', 'Interclaw.Config', 'Interclaw.Core', 'Interclaw.Host')
        foreach ($mod in $wrapperModules) {
            $result = $results | Where-Object Module -eq $mod
            $result | Should -Not -BeNullOrEmpty -Because "$mod should be found"
            $result.DriftType | Should -Be 'Wrapper' -Because "$mod uses wrapper pattern"
        }
    }
}
