#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    $script:TargetPath = Join-Path $script:RepoRoot "Skills" "Docker" "Rotate-BundleSecret.ps1"
}

Describe "Rotate-BundleSecret.ps1" -Tag "Docker" {
    It "exists at expected path" {
        Test-Path $script:TargetPath | Should -Be $true
    }

    It "has .SYNOPSIS help comment" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It "does not need [OutputType()] — rotation script with no pipeline output" {
        Get-Content $script:TargetPath -Raw | Should -Not -Match 'OutputType'
    }

    It "param block parses correctly" {
        $null = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:TargetPath, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "has param block with BundleName, ServiceName, and SecretValue parameters" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match 'BundleName'
        $content | Should -Match 'ServiceName'
        $content | Should -Match 'SecretValue'
    }

    It "captures prior secret content from the running container, not inspect metadata" -Tag "Regression" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Not -Match 'Spec\.Name'
        $content | Should -Match 'docker exec \$ServiceName sh -c "cat /run/secrets/\$MountTarget"'
    }

    It "validates captured prior value is valid JSON before rollback" -Tag "Regression" {
        $content = Get-Content $script:TargetPath -Raw
        $content | Should -Match 'ConvertFrom-Json -ErrorAction Stop'
        $content | Should -Match 'not valid JSON'
    }
}
