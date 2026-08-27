#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Pester tests for Invoke-ComplianceScan.ps1
# Source: Skills/Workflows/Audit/Invoke-ComplianceScan.ps1
# Covers: hermetic scan, SOV-1 region detection (incl. CDK .ts IaC per compliance-audit.md),
# ca-central-1 line skipping, and JSON output shape.

BeforeAll {
    $RepoRoot = $PSScriptRoot
    while ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $RepoRoot -Parent
        if ($parent -eq $RepoRoot) { break }
        $RepoRoot = $parent
    }
    $Script:ScriptPath = Join-Path $RepoRoot "Skills/Workflows/Audit/Invoke-ComplianceScan.ps1"
    $Script:TempDir = Join-Path $env:TEMP "compliance-scan-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
}

AfterAll {
    if (Test-Path $Script:TempDir) { Remove-Item $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe "Compliance Scan script" -Tag "Audit", "Regression" {
    It "script file exists" {
        $Script:ScriptPath | Should -Exist
    }

    It "script has valid PowerShell syntax" {
        $content = Get-Content $Script:ScriptPath -Raw
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It "script has param block with expected parameters" {
        $content = Get-Content $Script:ScriptPath -Raw
        $content | Should -Match '\$RepoRoot'
        $content | Should -Match '\$OutputFile'
        $content | Should -Match '\$ExcludeDirs'
    }

    Context "region scan (SOV-1)" {
        It "flags a non-ca-central-1 region seeded in a CDK .ts file" {
            $repo = Join-Path $Script:TempDir "scanrepo"
            New-Item -ItemType Directory -Path (Join-Path $repo "backend/cdk") -Force | Out-Null
            'export const region = "us-east-1";' | Set-Content (Join-Path $repo "backend/cdk/stack.ts") -Encoding utf8
            $out = Join-Path $Script:TempDir "scan.json"
            & $Script:ScriptPath -RepoRoot $repo -OutputFile $out 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $scan = Get-Content $out -Raw | ConvertFrom-Json -Depth 10
            $usEast = @($scan.categories.regions | Where-Object { $_.file -match 'stack\.ts' -and $_.pattern -match 'non-ca-central-1' })
            $usEast.Count | Should -BeGreaterThan 0
        }

        It "skips lines that reference the sanctioned ca-central-1 region" {
            $repo = Join-Path $Script:TempDir "scanrepo2"
            New-Item -ItemType Directory -Path (Join-Path $repo "backend/cdk") -Force | Out-Null
            'export const region = "ca-central-1";' | Set-Content (Join-Path $repo "backend/cdk/canada.ts") -Encoding utf8
            $out = Join-Path $Script:TempDir "scan2.json"
            & $Script:ScriptPath -RepoRoot $repo -OutputFile $out 2>&1 | Out-Null
            $scan = Get-Content $out -Raw | ConvertFrom-Json -Depth 10
            @($scan.categories.regions | Where-Object { $_.file -match 'canada\.ts' }).Count | Should -Be 0
        }
    }

    Context "output shape" {
        It "emits date/repoRoot/categories and exits 0" {
            $repo = Join-Path $Script:TempDir "scanrepo3"
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            'x = 1' | Set-Content (Join-Path $repo "a.ts") -Encoding utf8
            $out = Join-Path $Script:TempDir "scan3.json"
            & $Script:ScriptPath -RepoRoot $repo -OutputFile $out 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $scan = Get-Content $out -Raw | ConvertFrom-Json -Depth 10
            $scan.date | Should -Match '^\d{4}-\d{2}-\d{2}$'
            $scan.repoRoot | Should -Be $repo
            $scan.categories.regions | Should -Not -Be $null
        }
    }
}
