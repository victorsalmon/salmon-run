#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Locking Module" -Tag "Locking", "Regression-Only" {
    It "exports the 4 expected locking functions" {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Locking\SalmonRun.Locking.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Contain "Lock-File"
        $exports | Should -Contain "Unlock-File"
        $exports | Should -Contain "Register-Namespace"
        $exports | Should -Contain "Remove-NamespaceReservation"
    }

    It "exports the 5 expected aliases" {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Locking\SalmonRun.Locking.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $aliases = $manifest.AliasesToExport
        $aliases | Should -Contain "Acquire-FileLock"
        $aliases | Should -Contain "Release-FileLock"
        $aliases | Should -Contain "Acquire-NamespaceReservation"
        $aliases | Should -Contain "Release-NamespaceReservation"
        $aliases | Should -Contain "Reserve-Namespace"
    }

    It "requires SalmonRun.Paths for task root resolution" {
        $manifestPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Locking\SalmonRun.Locking.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.RequiredModules | Should -Contain 'SalmonRun.Paths'
    }
}

Describe "Lock-File behavioral tests" -Tag "Locking", "Regression-Only" {
    BeforeAll {
        $script:LockTestDir = Join-Path $env:TEMP "Interclaw-LockingTests-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:LockTestDir -Force
        $script:SavedSALMON_RUN_HOME = $env:SALMON_RUN_HOME
        $env:SALMON_RUN_HOME = $script:LockTestDir

        $pathsModule = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        if (Test-Path -LiteralPath $pathsModule) { . $pathsModule }

        $corePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        if (Test-Path -LiteralPath $corePath) { . $corePath }

        $lockingDir = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Locking\Public'
        if (Test-Path $lockingDir) {
            Get-ChildItem -Path $lockingDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }

        $lockingPrivateDir = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Locking\Private'
        if (Test-Path $lockingPrivateDir) {
            Get-ChildItem -Path $lockingPrivateDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }

        function global:Get-InterclawConstants { @{ NamespaceReclaimThresholdSeconds = 120 } }
    }
    AfterAll {
        if (Test-Path $script:LockTestDir) { Remove-Item -Recurse -Force $script:LockTestDir }
        if ($script:SavedSALMON_RUN_HOME) { $env:SALMON_RUN_HOME = $script:SavedSALMON_RUN_HOME } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Remove-Item "$script:LockTestDir/Tasks/Locks" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Lock-File creates .lock files" {
        Lock-File -FileNames @("test-plan") | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/test-plan.lock" | Should -Be $true
    }

    It "Lock-File returns false when lock already held" {
        Lock-File -FileNames @("contested") | Should -Be $true
        Lock-File -FileNames @("contested") -MaxWaitMs 500 | Should -Be $false
    }

    It "Lock-File acquires multiple locks" {
        Lock-File -FileNames @("a", "b", "c") | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/a.lock" | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/b.lock" | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/c.lock" | Should -Be $true
    }

    It "Unlock-File removes .lock files" {
        Lock-File -FileNames @("to-release") | Should -Be $true
        Unlock-File -FileNames @("to-release")
        Test-Path "$script:LockTestDir/Tasks/Locks/to-release.lock" | Should -Be $false
    }

    It "Unlock-File does not throw on missing lock" {
        { Unlock-File -FileNames @("nonexistent") } | Should -Not -Throw
    }

    It "Lock-File reclaims stale lock from dead PID" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        Set-Content -Path "$script:LockTestDir/Tasks/Locks/stale.lock" -Value "dead-agent|99999999|2000-01-01T00:00:00Z" -NoNewline
        Lock-File -FileNames @("stale") -MaxWaitMs 1000 | Should -Be $true
    }

    It "Lock-File cannot reclaim lock held by live PID with recent timestamp" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        $recentTimestamp = (Get-Date).AddMinutes(-1).ToString('o')
        Set-Content -Path "$script:LockTestDir/Tasks/Locks/live.lock" -Value "live-agent|$PID|$recentTimestamp" -NoNewline
        Lock-File -FileNames @("live") -MaxWaitMs 500 | Should -Be $false
    }

    It "Remove-NamespaceReservation does not throw on missing reservation" {
        { Remove-NamespaceReservation -NamespacePrefix "nonexistent-ns-" } | Should -Not -Throw
    }
}
