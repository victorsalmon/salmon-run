#Requires -Modules Pester

# Alignment 2026-08-04 plan 2: retry-toctou-patterns —
# retry loops use bounded exponential backoff; no Test-Path write-guard TOCTOU.

Describe "Alignment retry/TOCTOU hygiene (plan 2 target files)" -Tag "Core", "Regression" {
    BeforeAll {
        $script:TargetFiles = @(
            (Join-Path $PSScriptRoot "..\1Fleet.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Attio\Persons.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Hunter\EmailFinder.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Smartlead\Outreach.ps1")
        )
    }

    It "all plan-2 target files exist and parse without syntax errors" {
        foreach ($f in $script:TargetFiles) {
            Test-Path -LiteralPath $f | Should -Be $true -Because $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because $f
        }
    }

    It "marketer API handlers declare a bounded max-retry guard" {
        foreach ($f in $script:TargetFiles) {
            if ($f -match 'Marketer') {
                $content = Get-Content -LiteralPath $f -Raw
                $content | Should -Match 'MaxRetries\s*=\s*\d+' -Because $f
            }
        }
    }

    It "marketer API handlers use non-fixed (exponential/jittered) backoff for all retries" {
        foreach ($f in $script:TargetFiles) {
            if ($f -match 'Marketer') {
                $content = Get-Content -LiteralPath $f -Raw
                $fixedSleeps = [regex]::Matches($content, 'Start-Sleep -Milliseconds \d+')
                $fixedSleeps.Count | Should -Be 0 -Because "fixed-interval sleeps remain in $f"
                $content | Should -Match 'Start-Sleep -Milliseconds \(\[math\]::Pow|Start-Sleep -Milliseconds \$backoff' -Because $f
            }
        }
    }

    It "1Fleet.ps1 has no Test-Path write-guard blocks" {
        $fleet = Join-Path $PSScriptRoot "..\1Fleet.ps1"
        $content = Get-Content -LiteralPath $fleet -Raw
        $content | Should -Not -Match 'if \(-not \(Test-Path[^)]*\)\)\s*\{' -Because "Test-Path preceding a write in $fleet"
        $content | Should -Match 'New-Item -ItemType Directory -Path \$FleetReportsDir -Force' -Because "idempotent dir create in $fleet"
    }

    It "1Fleet.ps1 crash-retry uses jittered backoff, not a fixed sleep" {
        $fleet = Join-Path $PSScriptRoot "..\1Fleet.ps1"
        $content = Get-Content -LiteralPath $fleet -Raw
        $content | Should -Match 'Start-Sleep -Seconds \(30 \+ \(Get-Random' -Because "jittered backoff in $fleet"
    }
}
