#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Alignment 2026-08-04 plan 0: concurrency-silent-discards —
# no un-commented Out-Null/[void] discards, no $script: writes inside parallel blocks.

Describe "Alignment concurrency-silent-discards (plan 0 target files)" -Tag "Core", "Regression" {
    BeforeAll {
        $script:TargetFiles = @(
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Public\Start-Orchestrator.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Public\Get-SecretFromAws.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Orchestrate\Private\Orphan.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Handlers\Search\Firecrawl.ps1"),
            (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Handlers\Search\Tavily.ps1")
        )
    }

    It "all plan-0 target files exist" {
        foreach ($f in $script:TargetFiles) {
            Test-Path -LiteralPath $f | Should -Be $true -Because $f
        }
    }

    It "all plan-0 target files parse without syntax errors" {
        foreach ($f in $script:TargetFiles) {
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because $f
        }
    }

    It "every Out-Null or [void] discard carries a justification comment above it" {
        foreach ($f in $script:TargetFiles) {
            $lines = Get-Content -LiteralPath $f
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'Out-Null|\[void\]') {
                    $justified = $false
                    for ($j = [Math]::Max(0, $i - 3); $j -lt $i; $j++) {
                        if ($lines[$j] -match '^\s*#') { $justified = $true; break }
                    }
                    $justified | Should -Be $true -Because "line $($i + 1) in $f lacks a safe-discard justification: $($lines[$i])"
                }
            }
        }
    }

    It 'no $script: write occurs inside ForEach-Object -Parallel or Start-ThreadJob blocks' {
        foreach ($f in $script:TargetFiles) {
            $content = Get-Content -LiteralPath $f -Raw
            $parallelBlocks = [regex]::Matches($content, '(?ms)(ForEach-Object\s+-Parallel|Start-ThreadJob).*?(?=\n\s*\}|\z)')
            foreach ($block in $parallelBlocks) {
                $block.Value -match '\$script:\s*=' | Should -Be $false -Because "parallel block in $f writes module-scope state"
            }
        }
    }
}
