#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

$script:repoRoot = $null

Describe "CI Pipeline" -Tag "CI" {
    BeforeAll {
        if (-not $script:repoRoot) {
            $p = $PSCommandPath
            if (-not $p) { $p = $MyInvocation.MyCommand.Path }
            $script:repoRoot = Split-Path -Parent $p
            foreach ($i in 1..3) { $script:repoRoot = Split-Path -Parent $script:repoRoot }
        }
    }

    It "Workflow file exists" {
        Join-Path $script:repoRoot ".github\workflows\pester.yml" | Should -Exist
    }

    It "Pre-commit hook references Skills/Docker/Tests/" {
        $content = Get-Content -Raw (Join-Path $script:repoRoot ".githooks\pre-commit") -ErrorAction SilentlyContinue
        $content | Should -Match "Skills/Docker/Tests/"
    }

    It "README has status badge" {
        $content = Get-Content -Raw (Join-Path $script:repoRoot "README.md") -ErrorAction SilentlyContinue
        $content | Should -Match "pester\.yml/badge\.svg"
    }
}
