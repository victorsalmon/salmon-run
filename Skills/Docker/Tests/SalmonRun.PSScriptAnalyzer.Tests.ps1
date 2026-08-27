#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0
# Install PSScriptAnalyzer: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $ModulesRoot = Join-Path $RepoRoot "Skills" "Docker" "Modules"
    $script:PublicFiles = Get-ChildItem -Path $ModulesRoot -Recurse -Filter "*.ps1" |
        Where-Object { $_.FullName -match '[\\/]Public[\\/]' }
    $script:PssaAvailable = [bool](Get-Module -ListAvailable PSScriptAnalyzer)
    if (-not $script:PssaAvailable) {
        Write-Warning "PSScriptAnalyzer not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck"
    }
}

$skipPSSA = -not [bool](Get-Module -ListAvailable PSScriptAnalyzer)

Describe "PSScriptAnalyzer - Module Quality Gate" -Tag "StaticAnalysis", "Regression-Only" {
    It "All public functions pass PSScriptAnalyzer with no errors" -Skip:$skipPSSA {
        $issues = @()
        foreach ($file in $script:PublicFiles) {
            $results = Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error
            $issues += $results
        }
        if ($issues) {
            Write-Warning "$($issues.Count) PSScriptAnalyzer Error-severity issues found"
        }
        $issues | Should -BeNullOrEmpty -Because "any Error severity would indicate a runtime crash risk"
    }

    It "No PSUseApprovedVerbs violations" -Skip:$skipPSSA {
        $violations = @()
        foreach ($file in $script:PublicFiles) {
            $results = Invoke-ScriptAnalyzer -Path $file.FullName -IncludeRule PSUseApprovedVerbs
            $violations += $results
        }
        if ($violations) {
            Write-Warning "$($violations.Count) PSUseApprovedVerbs violations found"
        }
        $violations | Should -BeNullOrEmpty
    }
}
