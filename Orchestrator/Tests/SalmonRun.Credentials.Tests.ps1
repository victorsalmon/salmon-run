#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Orchestrator' 'Modules'

    Remove-Module 'SalmonRun.Credentials', 'SalmonRun.Core' -Force -ErrorAction SilentlyContinue

    $script:CredPsd1 = Join-Path $__ModulesDir 'SalmonRun.Credentials' 'SalmonRun.Credentials.psd1'
    Import-Module $script:CredPsd1 -Force -ErrorAction Stop
}

Describe 'SalmonRun.Credentials Module' -Tag 'Credentials' {
    It 'manifest exists and is importable' {
        Test-Path $script:CredPsd1 | Should -Be $true
        Get-Module 'SalmonRun.Credentials' | Should -Not -BeNullOrEmpty
    }

    It 'exports the expected functions' {
        $manifest = Import-PowerShellDataFile -Path $script:CredPsd1
        $expected = @('Get-SalmonRunCredential', 'Get-SalmonRunEnvFile', 'Register-SalmonRunCredentialResolver', 'Resolve-SalmonRunCredentialValue')
        foreach ($name in $expected) {
            $manifest.FunctionsToExport | Should -Contain $name
        }
    }
}

Describe 'Get-SalmonRunEnvFile' -Tag 'Credentials' {
    It 'parses KEY=VALUE lines' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "cred-$(Get-Random)") -Force
        $path = Join-Path $td '.env'
        @'
A=1
B=2 # inline comment
C="three"

# line comment
D=four
'@ | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline

        $env = & (Get-Module SalmonRun.Credentials) { param($p) Get-SalmonRunEnvFile -Path $p } $path
        $env['A'] | Should -Be '1'
        $env['B'] | Should -Be '2'
        $env['C'] | Should -Be 'three'
        $env['D'] | Should -Be 'four'
    }
}

Describe 'Resolve-SalmonRunCredentialValue' -Tag 'Credentials' {
    It 'returns literals when no resolver matches' {
        & (Get-Module SalmonRun.Credentials) { Resolve-SalmonRunCredentialValue -Value 'plain-secret' } | Should -Be 'plain-secret'
    }

    It 'uses the Env resolver' {
        $prev = $env:SALMON_TEST_FOO
        try {
            $env:SALMON_TEST_FOO = 'bar'
            & (Get-Module SalmonRun.Credentials) { Resolve-SalmonRunCredentialValue -Value 'Env SALMON_TEST_FOO' } | Should -Be 'bar'
        } finally {
            if ($null -ne $prev) { $env:SALMON_TEST_FOO = $prev } else { Remove-Item -Path 'Env:\SALMON_TEST_FOO' -ErrorAction SilentlyContinue }
        }
    }

    It 'falls back to joined arguments if the Env variable is not set' {
        & (Get-Module SalmonRun.Credentials) { Resolve-SalmonRunCredentialValue -Value 'Env NotSet fallback value' } | Should -Be 'NotSet fallback value'
    }

    It 'uses the File resolver' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "cred-$(Get-Random)") -Force
        $file = Join-Path $td 'secret.txt'
        'secret-value' | Set-Content -LiteralPath $file -Encoding utf8 -NoNewline

        & (Get-Module SalmonRun.Credentials) { param($p) Resolve-SalmonRunCredentialValue -Value "File $p" } $file | Should -Be 'secret-value'
    }

    It 'uses a custom registered resolver' {
        & (Get-Module SalmonRun.Credentials) {
            Register-SalmonRunCredentialResolver -Name 'Reverse' -ScriptBlock {
                param([string[]]$Arguments)
                $joined = $Arguments -join ''
                $charArray = $joined.ToCharArray()
                [array]::Reverse($charArray)
                return -join $charArray
            }
            Resolve-SalmonRunCredentialValue -Value 'Reverse abc' | Should -Be 'cba'
        }
    }
}

Describe 'Get-SalmonRunCredential' -Tag 'Credentials' {
    It 'resolves a named credential from a file' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "cred-$(Get-Random)") -Force
        $path = Join-Path $td '.env'
        "TOKEN=File $td/token.txt" | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline
        'my-token' | Set-Content -LiteralPath (Join-Path $td 'token.txt') -Encoding utf8 -NoNewline

        & (Get-Module SalmonRun.Credentials) { param($p) Get-SalmonRunCredential -Name 'TOKEN' -EnvPath $p } $path | Should -Be 'my-token'
    }

    It 'returns null for a missing key' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "cred-$(Get-Random)") -Force
        $path = Join-Path $td '.env'
        'OTHER=1' | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline

        & (Get-Module SalmonRun.Credentials) { param($p) Get-SalmonRunCredential -Name 'MISSING' -EnvPath $p } $path | Should -BeNullOrEmpty
    }
}
