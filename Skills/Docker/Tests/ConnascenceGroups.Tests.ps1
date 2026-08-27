#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $ScriptPath = Join-Path $RepoRoot "Skills\\Orchestration\Get-ConnascenceGroups.ps1"
    $TempDir = Join-Path $env:TEMP "ConnascenceTest_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $TempDir -Force

    # Dot-source the script to load its functions
    . $ScriptPath
}

AfterAll {
    if (Test-Path $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force }
}

Describe "Get-FilesField" -Tag "Connascence" {
    It "parses inline comma-separated format" {
        $content = @"
**Files**: a.mjs, b.mjs, c.mjs
"@
        $result = Get-FilesField -Content $content
        $result | Should -Be @("a.mjs", "b.mjs", "c.mjs")
    }

    It "parses bulleted-list format with annotations" {
        $content = @"
**Files**:
- a.mjs (new)
- b.mjs (extend)
- c.mjs (existing)
"@
        $result = Get-FilesField -Content $content
        $result | Should -Be @("a.mjs", "b.mjs", "c.mjs")
    }

    It "parses bulleted-list format without annotations" {
        $content = @"
**Files**:
- a.mjs
- b.mjs
"@
        $result = Get-FilesField -Content $content
        $result | Should -Be @("a.mjs", "b.mjs")
    }

    It "returns empty array for **Files**: None" {
        $content = "**Files**: None"
        $result = Get-FilesField -Content $content
        $result | Should -BeNullOrEmpty
    }

    It "returns empty array for **Files**: with no following bullets" {
        $content = @"
**Files**:

## Overview
"@
        $result = Get-FilesField -Content $content
        $result | Should -BeNullOrEmpty
    }

    It "stops collecting bullets at the next ** header" {
        $content = @"
**Files**:
- a.mjs (new)
- b.mjs

**Token budget**: 60000
"@
        $result = Get-FilesField -Content $content
        $result | Should -Be @("a.mjs", "b.mjs")
        $result.Count | Should -Be 2
    }
}

Describe "Get-DependsOn" -Tag "Connascence" {
    It "parses single dependency with status" {
        $content = "**DependsOn**: foo-01 (status: complete)"
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 1
        $result[0].Ref | Should -Be "foo-01"
        $result[0].Status | Should -Be "complete"
    }

    It "parses multiple comma-separated dependencies" {
        $content = "**DependsOn**: a-01 (status: reviewed), b-02 (status: complete)"
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 2
        $result[0].Ref | Should -Be "a-01"
        $result[0].Status | Should -Be "reviewed"
        $result[1].Ref | Should -Be "b-02"
        $result[1].Status | Should -Be "complete"
    }

    It "parses '(none — root)' as no dependencies" {
        $content = "**DependsOn**: (none — root)"
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 0
    }

    It "parses 'ready' status gate" {
        $content = "**DependsOn**: ingest-02 (status: ready), provider-01 (status: ready)"
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 2
        $result[0].Status | Should -Be "ready"
        $result[1].Status | Should -Be "ready"
    }

    It "parses multi-line DependsOn (one entry per continuation line)" -Tag "Regression" {
        $content = @"
**DependsOn**: arch-0 (status: complete)
             arch-1 (status: complete)
             arch-2 (status: complete)
**Repair passes**: 2
"@
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 3
        $result[0].Ref | Should -Be "arch-0"
        $result[1].Ref | Should -Be "arch-1"
        $result[2].Ref | Should -Be "arch-2"
        $result | ForEach-Object { $_.Status | Should -Be "complete" }
    }

    It "multi-line parse stops at the next header field (no over-capture)" -Tag "Regression" {
        $content = @"
**DependsOn**: a-0 (status: complete)
             a-1 (status: ready)
**Status**: ready
**Date**: 2026-08-13
"@
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 2
        $result[0].Ref | Should -Be "a-0"
        $result[1].Ref | Should -Be "a-1"
        $result[1].Status | Should -Be "ready"
    }

    It "parses a large multi-line DependsOn (18 entries) - regression for alignment-2 loop" -Tag "Regression" {
        $lines = @("**DependsOn**: upscale-havens-architectural-0 (status: complete)")
        foreach ($i in 1..17) {
            $lines += ("             upscale-havens-architectural-$i (status: complete)")
        }
        $content = $lines -join "`n"
        $result = Get-DependsOn -Content $content
        $result.Count | Should -Be 18
    }
}

Describe "Get-ReadySet status gates" -Tag "Connascence", "Regression" {
    It "root plans (no deps) are always ready" {
        $graph = @{
            "root-plan.md" = @{ Deps = @(); Files = @("a.mjs") }
        }
        $result = Get-ReadySet -DepGraph $graph -CompletedDir (Join-Path $TempDir "Complete")
        $result.ReadySet | Should -Contain "root-plan.md"
        $result.BlockedSet.Count | Should -Be 0
        $result.DanglingDeps.Count | Should -Be 0
    }

    It "plans with dangling deps appear in DanglingDeps" {
        $graph = @{
            "child.md" = @{
                Deps = @(@{ Ref = "nonexistent-01"; Status = "ready" })
                Files = @("b.mjs")
            }
        }
        $result = Get-ReadySet -DepGraph $graph -CompletedDir (Join-Path $TempDir "Complete")
        $result.DanglingDeps.Count | Should -Be 1
        $result.BlockedSet | Should -Contain "child.md"
    }
}

Describe "Get-ConnascenceGroups integration" -Tag "Connascence" {
    It "script exists and is syntactically valid" {
        Test-Path $ScriptPath | Should -Be $true
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content -Raw -LiteralPath $ScriptPath),
            [ref]$errors
        )
        $errors | Should -BeNullOrEmpty
    }
}
Describe "connascence cache signature includes parser self-hash" -Tag "Connascence", "Regression" {
    It "perturbing the parser script body invalidates the cache (no plan file changed)" {
        $sandbox = Join-Path $TempDir "parser-self-hash"
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $tempRepo = Join-Path $sandbox "repo"
        $tempTaskDir = Join-Path $tempRepo "Tasks" "Code"
        $null = New-Item -ItemType Directory -Path $tempTaskDir -Force
        $cacheFile = Join-Path $tempRepo "Tasks" "Logs" ".connascence-cache" "cache.json"
        $fixture = Join-Path $tempTaskDir "2026-08-13-fixture-0-plan.md"
        @"
# Session Plan: fixture plan

**Status**: ready
**Files**: None
"@ | Set-Content -Path $fixture -Encoding utf8

        $scriptCopy = Join-Path $sandbox "Get-ConnascenceGroups-copy.ps1"
        Copy-Item -LiteralPath $ScriptPath -Destination $scriptCopy -Force

        & $scriptCopy -RepoRoot $tempRepo -TaskDir $tempTaskDir | Out-Null
        $sigBefore = ((Get-Content $cacheFile -Raw | ConvertFrom-Json).signature)

        Add-Content -Path $scriptCopy -Value "`n# perturbed parser body" -Encoding utf8

        & $scriptCopy -RepoRoot $tempRepo -TaskDir $tempTaskDir | Out-Null
        $sigAfter = ((Get-Content $cacheFile -Raw | ConvertFrom-Json).signature)

        $sigAfter | Should -Not -Be $sigBefore
    }
}