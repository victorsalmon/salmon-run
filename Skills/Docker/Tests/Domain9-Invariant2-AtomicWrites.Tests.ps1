#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Domain9 Invariant 2 — Atomic File Writes" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $ownerConfigPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Config\Public\Set-OwnerPlaceholders.ps1"
        $installPath = Join-Path $PSScriptRoot "..\1Install.ps1"
        $sentryTopPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Test-FleetAqeTopology.ps1"
        $simulatePath = Join-Path $PSScriptRoot "..\Simulate-Fleet.ps1"
        $corePubPath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Write-AtomicJson.ps1"
    }

    It "Write-AtomicJson helper exists in SalmonRun.Core Public" {
        Test-Path $corePubPath | Should -Be $true
    }

    It "Write-AtomicJson uses .tmp + Move-Item pattern" {
        $content = Get-Content -LiteralPath $corePubPath -Raw
        $content | Should -Match '\.tmp'
        $content | Should -Match '(Move-Item|\[System\.IO\.File\]::Move|System\.IO\.File\.Move)'
    }

    It "Set-OwnerPlaceholders uses Write-AtomicJson" {
        $content = Get-Content -LiteralPath $ownerConfigPath -Raw
        $content | Should -Match 'Write-AtomicJson'
        $content | Should -Not -Match 'Set-Content.*OwnerConfigPath'
        $content | Should -Not -Match 'Move-Item.*OwnerConfigPath'
    }

    It "1Install.ps1 line 178 uses Write-AtomicJson for InstallJson" {
        $content = Get-Content -LiteralPath $installPath -Raw
        $content | Should -Match 'Write-AtomicJson.*InstallJsonPath'
    }

    It "1Install.ps1 line 366 uses Write-AtomicJson for Docker settings" {
        $content = Get-Content -LiteralPath $installPath -Raw
        $content | Should -Match 'Write-AtomicJson.*DockerSettingsPath'
    }

    It "Test-FleetAqeTopology uses Write-AtomicJson for HistoryPath" {
        $content = Get-Content -LiteralPath $sentryTopPath -Raw
        $content | Should -Match 'Write-AtomicJson.*HistoryPath'
        $content | Should -Not -Match 'Set-Content.*HistoryPath'
    }

    It "Simulate-Fleet uses Write-AtomicJson for ReportFile" {
        $content = Get-Content -LiteralPath $simulatePath -Raw
        $content | Should -Match 'Write-AtomicJson.*ReportFile'
        $content | Should -Not -Match 'Out-File.*ReportFile'
    }
}
