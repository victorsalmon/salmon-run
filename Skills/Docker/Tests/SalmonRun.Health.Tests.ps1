#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Health Module" -Tag "Health", "Regression-Only" {
    It "exports the 13 expected Test-Fleet* functions" {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Health\SalmonRun.Health.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Contain "Test-FleetStackHealth"
        $exports | Should -Contain "Test-FleetCodeHealth"
        $exports | Should -Contain "Test-FleetVolumeIntegrity"
        $exports | Should -Contain "Test-FleetSecretHydration"
        $exports | Should -Contain "Test-FleetContainerHealth"
        $exports | Should -Contain "Test-FleetSecretResolution"
        $exports | Should -Contain "Test-FleetNetworkConnectivity"
        $exports | Should -Contain "Test-FleetSidecarHealth"
        $exports | Should -Contain "Test-FleetSelfHealth"
        $exports | Should -Contain "Test-FleetTelegramPolling"
        $exports | Should -Contain "Test-FleetAqeTopology"
        $exports | Should -Contain "Test-FleetSwarmReality"
        $exports | Should -Contain "Test-FleetServiceEndpoints"
    }

    It "has the correct RequiredModules" {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Health\SalmonRun.Health.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.RequiredModules | Should -Contain "SalmonRun.Core"
        $manifest.RequiredModules | Should -Contain "SalmonRun.Process"
    }
}
