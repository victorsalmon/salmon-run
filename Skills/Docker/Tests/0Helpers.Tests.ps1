#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    $script:TargetPath = Join-Path $script:RepoRoot "Skills" "Docker" "0Helpers.ps1"
}

Describe "0Helpers.ps1" -Tag "Docker" {
    It "exists at expected path" {
        Test-Path $script:TargetPath | Should -Be $true
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "does not need [OutputType()] — helper script calls Import-Module only" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Not -Match 'OutputType'
    }

    It "param block parses correctly" {
        $null = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:TargetPath, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "contains DEPRECATED warning" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match 'DEPRECATED'
    }
}
