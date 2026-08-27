#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    $script:TargetPath = Join-Path $script:RepoRoot "Skills" "Docker" "Simulate-Fleet.ps1"
}

Describe "Simulate-Fleet.ps1" -Tag "Docker" {
    It "exists at expected path" {
        Test-Path $script:TargetPath | Should -Be $true
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "does not need [OutputType()] — load test script with no pipeline output" {
        Get-Content $script:TargetPath -Raw | Should -Not -Match 'OutputType'
    }

    It "param block parses correctly" {
        $null = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:TargetPath, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "has param block with Profile, TargetAgents, and DurationMs parameters" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match 'Profile'
        $content | Should -Match 'TargetAgents'
        $content | Should -Match 'DurationMs'
    }
}
