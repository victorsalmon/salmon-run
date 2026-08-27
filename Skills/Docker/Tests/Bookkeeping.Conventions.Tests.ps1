#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $accountantScripts = @(
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule1NetIncome.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule8CCA.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule3Shareholder.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule4SBD.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-GSTReconciliation.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-PriorYearComparison.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftReports.ps1"
        Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftGSTFiling.ps1"
    )
}

Describe "Anti-Pattern: [Math]::Max/Max with bare 0 (int coercion)" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "All bookkeeping scripts use [decimal]0 in [Math]::Max calls" {
        $violations = @()
        foreach ($script in $accountantScripts) {
            $content = Get-Content $script -Raw
            $matches = [regex]::Matches($content, '\[Math\]::(Max|Min)\(0,')
            foreach ($m in $matches) {
                $line = ($content.Substring(0, $m.Index) -split "`n").Count
                $violations += "$([System.IO.Path]::GetFileName($script)):line $line - $($m.Value)"
            }
        }
        if ($violations.Count -gt 0) {
            Write-Warning "Found $($violations.Count) [Math]::Max/Min(0, calls (int coercion risk):`n$($violations -join "`n")"
        }
        $violations.Count | Should -Be 0
    }
}

Describe "Anti-Pattern: Missing else on trial-balance Test-Path" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Invoke-DraftT2Filing warns when TB file not found" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1") -Raw
        $content | Should -Match '(?s)else \{.*Write-Warning.*Trial balance not found'
    }
}

Describe "Anti-Pattern: Empty ExpensesByVendor passed to GST without notice" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Orchestrator emits notice before empty GST call" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1") -Raw
        $content | Should -Match 'ITCs will be \$0'
    }
}

Describe "Anti-Pattern: P&L-only SHL lookup without fallback" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Orchestrator discovers SHL from GL, not just P&L hashtable" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1") -Raw
        $content | Should -Match 'shlDiscovered'
    }
}

Describe "Anti-Pattern: Silent CCA zero when prior year had CCA" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Orchestrator warns when CCA=0 but prior year > 0" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1") -Raw
        $content | Should -Match 'prior.year.cca_claimed -gt 0'
    }
}

Describe "Anti-Pattern: Missing post-pipeline diagnostic summary" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Orchestrator ends with diagnostic summary" {
        $content = Get-Content (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Invoke-DraftT2Filing.ps1") -Raw
        $content | Should -Match 'DRAFT DIAGNOSTICS'
    }
}

Describe "Convention: Each function script has a self-test mode" -Tag "Bookkeeping", "Convention" {
    It "Get-Schedule1NetIncome runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule1NetIncome.ps1") 2>&1 | Should -Not -Be $null
    }
    It "Get-Schedule8CCA runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule8CCA.ps1") 2>&1 | Should -Not -Be $null
    }
    It "Get-Schedule3Shareholder runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule3Shareholder.ps1") 2>&1 | Should -Not -Be $null
    }
    It "Get-Schedule4SBD runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-Schedule4SBD.ps1") 2>&1 | Should -Not -Be $null
    }
    It "Get-GSTReconciliation runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-GSTReconciliation.ps1") 2>&1 | Should -Not -Be $null
    }
    It "Get-PriorYearComparison runs self-test with demo data" {
        & (Join-Path $repoRoot "Skills\Bookkeeping\tax-filing\draft-financials\scripts\Get-PriorYearComparison.ps1") 2>&1 | Should -Not -Be $null
    }
}

Describe "Anti-Pattern: New pipeline-stage or entrypoint skills must register in skills.json" -Tag "Bookkeeping", "Convention", "AntiPattern", "Regression-Only" {
    It "Skill .md files with 'type:' field in YAML frontmatter are registered" {
        $skillsJson = Get-Content (Join-Path $repoRoot "Skills\skills.json") -Raw | ConvertFrom-Json
        $registeredPaths = $skillsJson.path | ForEach-Object { $_ -replace '/', '\' }
        $unregistered = @()
        Get-ChildItem -Path (Join-Path $repoRoot "Skills\Bookkeeping") -Recurse -Filter "*.md" | Where-Object {
            $_.FullName -notmatch '\\_deprecated\\' -and $_.Name -ne 'README.md'
        } | ForEach-Object {
            $content = Get-Content $_.FullName -Raw
            if ($content -match '^---\s*\n(?:.|\n)*?\ntype:\s*\S') {
                $rel = $_.FullName.Substring($repoRoot.Length + 1)
                if ($rel -notin $registeredPaths) {
                    $unregistered += $rel
                }
            }
        }
        if ($unregistered.Count -gt 0) {
            Write-Warning "Skill .md files with type: field but not in skills.json:`n$($unregistered -join "`n")"
        }
        $unregistered.Count | Should -Be 0
    }
}
