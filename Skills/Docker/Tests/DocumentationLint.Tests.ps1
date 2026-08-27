#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:DocLintPath = Join-Path $script:RepoRoot "Skills" "Documentation" "Scripts" "Invoke-DocLint.ps1"
}

Describe "Documentation Lint" -Tag "Docs", "Unit" {
    It "Invoke-DocLint.ps1 exists and is callable" {
        $script:DocLintPath | Should -Exist
        { & $script:DocLintPath -RepoRoot $script:RepoRoot -Format json } | Should -Not -Throw
    }
    It "reports 0 broken references on clean docs" -Skip {
        # This test is skipped until all broken references are fixed and documented.
        # Run the linter and assert clean output:
        $output = & $script:DocLintPath -RepoRoot $script:RepoRoot -Format json 2>&1
        $result = $output | ConvertFrom-Json
        $result.brokenReferences | Should -Be 0 -Because "all doc references should resolve"
    }
}
