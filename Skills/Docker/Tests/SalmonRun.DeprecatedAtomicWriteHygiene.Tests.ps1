#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Alignment 2026-08-04 plan 3: deprecated-atomic-write-hygiene —
# no deprecated patterns (Write-Host in handlers, Select-Object -Property *,
# unencoded Add-Content); direct writes use atomic temp-file+move.

Describe "Alignment deprecated/atomic-write hygiene (plan 3 target files)" -Tag "Core", "Regression" {
    BeforeAll {
        $script:TargetFiles = @(
            (Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\handlers\SalmonRun.Bookkeeping\Handlers\Zoho\Expenses.ps1"),
            (Join-Path $PSScriptRoot "ci-unit-filter.ps1"),
            (Join-Path $PSScriptRoot "Bookkeeper.OrphanReconciliation.Tests.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Public\Start-Orchestrator.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Process.ps1")
        )
    }

    It "all plan-3 target files exist and parse without syntax errors" {
        foreach ($f in $script:TargetFiles) {
            Test-Path -LiteralPath $f | Should -Be $true -Because $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because $f
        }
    }

    It "Zoho Expenses handler has no Write-Host (non-interactive handler)" {
        $expenses = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\handlers\SalmonRun.Bookkeeping\Handlers\Zoho\Expenses.ps1"
        Get-Content -LiteralPath $expenses -Raw | Should -Not -Match 'Write-Host' -Because $expenses
    }

    It "no Select-Object -Property * wildcard in plan-3 target files" {
        foreach ($f in $script:TargetFiles) {
            Get-Content -LiteralPath $f -Raw | Should -Not -Match 'Select-Object\s+-Property\s+\*' -Because $f
        }
    }

    It "every Add-Content call specifies -Encoding" {
        foreach ($f in $script:TargetFiles) {
            $lines = Get-Content -LiteralPath $f
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'Add-Content') {
                    $lines[$i] | Should -Match '-Encoding' -Because "line $($i + 1) in $f"
                }
            }
        }
    }

    It "Process.ps1 has no direct Set-Content/Out-File writes (all atomic)" {
        $process = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Process.ps1"
        $content = Get-Content -LiteralPath $process -Raw
        $content | Should -Not -Match 'Set-Content' -Because $process
        $content | Should -Not -Match 'Out-File' -Because $process
        $content | Should -Match 'Write-AtomicFile' -Because "atomic writes in $process"
    }

    It "Process.ps1 writes the spawned-PID registry atomically" {
        $process = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Process.ps1"
        $content = Get-Content -LiteralPath $process -Raw
        $content | Should -Match 'Write-AtomicFile -Path \$script:SpawnedPidsRegistryPath' -Because "registry writes in $process"
    }
}

Describe "Alignment 2026-08-06 file-append encoding hygiene (active script sweep)" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $script:SweepBases = @("Infrastructure", "Skills\Docker")
        $script:SweepFiles = @()
        foreach ($base in $script:SweepBases) {
            $fullBase = Join-Path $script:RepoRoot $base
            if (-not (Test-Path $fullBase)) { continue }
            $script:SweepFiles += Get-ChildItem -Path $fullBase -Recurse -Filter "*.ps1" -File | ForEach-Object {
                $rel = $_.FullName.Substring($script:RepoRoot.Length + 1)
                if ($rel -match 'Archived|DEPRECATED-|Skills\\Docker\\Tests') { return }
                $rel
            }
        }
        $script:SweepFiles = $script:SweepFiles | Sort-Object -Unique
    }

    It "sweep enumerates the active script set (non-empty)" {
        $script:SweepFiles.Count | Should -BeGreaterThan 100 -Because "402 active .ps1 files exist under Infrastructure/ and Skills/Docker/"
    }

    It "no Add-Content call omits -Encoding (scan regex parity)" {
        $violations = @()
        foreach ($rel in $script:SweepFiles) {
            $content = Get-Content -LiteralPath (Join-Path $script:RepoRoot $rel) -Raw
            if ($content -match 'Add-Content\s(?!.*-Encoding)') {
                $violations += $rel
            }
        }
        $violations | Should -BeNullOrEmpty -Because "every Add-Content call must carry an explicit -Encoding"
    }
}
