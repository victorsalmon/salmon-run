#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Alignment 2026-08-04 plan 1: error-swallowing-hygiene —
# no empty catch blocks, no bogus -ErrorAction args on native commands,
# AWS/docker failure paths capture stderr or check $LASTEXITCODE.

Describe "Alignment error-swallowing hygiene (plan 1 target files)" -Tag "Core", "Regression" {
    BeforeAll {
        $script:TargetFiles = @(
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Public\Start-Orchestrator.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetHealthHandlers.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Cleanup.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Publish-FleetStack.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Queue.ps1")
        )
    }

    It "all plan-1 target files exist and parse without syntax errors" {
        foreach ($f in $script:TargetFiles) {
            Test-Path -LiteralPath $f | Should -Be $true -Because $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because $f
        }
    }

    It "no empty catch blocks remain in plan-1 target files" {
        foreach ($f in $script:TargetFiles) {
            $content = Get-Content -LiteralPath $f -Raw
            $content | Should -Not -Match 'catch\s*\{\s*\}' -Because $f
        }
    }

    It "native docker/aws commands never receive PowerShell -ErrorAction parameters" {
        foreach ($f in $script:TargetFiles) {
            $content = Get-Content -LiteralPath $f -Raw
            $content | Should -Not -Match 'docker .*-ErrorAction\s+SilentlyContinue' -Because $f
            $content | Should -Not -Match 'aws .*-ErrorAction\s+SilentlyContinue' -Because $f
        }
    }

    It "AWS Secrets Manager reads in fleet health handlers capture stderr into an error variable" {
        $fleetHandlers = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetHealthHandlers.ps1"
        $content = Get-Content -LiteralPath $fleetHandlers -Raw
        $awsCalls = [regex]::Matches($content, 'aws secretsmanager get-secret-value')
        $awsCalls.Count | Should -BeGreaterThan 0
        foreach ($m in $awsCalls) {
            $start = [Math]::Max(0, $m.Index - 120)
            $window = $content.Substring($start, [Math]::Min(400, $content.Length - $start))
            $window | Should -Match '\$awsErr' -Because "AWS call at offset $($m.Index) must capture stderr"
        }
    }

    It "secret rotation sequences check \$LASTEXITCODE after docker service update" {
        $fleetHandlers = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetHealthHandlers.ps1"
        $content = Get-Content -LiteralPath $fleetHandlers -Raw
        $updates = [regex]::Matches($content, 'docker service update')
        $updates.Count | Should -BeGreaterThan 0
        foreach ($m in $updates) {
            $after = $content.Substring($m.Index + $m.Length, [Math]::Min(300, $content.Length - $m.Index - $m.Length))
            $after | Should -Match '\$LASTEXITCODE' -Because "docker service update at offset $($m.Index) must be followed by an exit-code check"
        }
    }
}

# Alignment 2026-08-06 plan 1 (repair pass): the 5 module files flagged by
# Scan 4 (silent error swallowing) must never regress to empty catch bodies.
Describe "Alignment error-swallowing hygiene (2026-08-06 repair targets)" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $script:RepairFiles = @(
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Orphan.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Stream.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Public\Start-Orchestrator.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Public\Invoke-RotationVerification.ps1")
        )
    }

    It "all repair-target files exist and parse without syntax errors" {
        foreach ($f in $script:RepairFiles) {
            Test-Path -LiteralPath $f | Should -Be $true -Because $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because $f
        }
    }

    It "no empty catch blocks remain in the repair-target files" {
        foreach ($f in $script:RepairFiles) {
            $content = Get-Content -LiteralPath $f -Raw
            $content | Should -Not -Match 'catch\s*\{\s*\}' -Because $f
        }
    }
}