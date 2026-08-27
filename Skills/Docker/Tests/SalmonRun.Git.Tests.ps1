#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Git\SalmonRun.Git.psm1")) -Force -DisableNameChecking

    function global:Write-SetupLog { }
    function global:Get-SecretFromAws { return $null }
    function global:Get-ServiceApiToken { return [pscustomobject]@{ Value = 'test-token'; Persisted = $false } }
}

Describe "SalmonRun.Git Module" -Tag "Git", "Regression-Only" {
    Context "Get-GitHubToken" -Tag "Git" {
        It "returns FleetRead token from env var" {
            $env:FLEET_GITHUB_TOKEN_READALL = "fleet-token-value"
            $result = Get-GitHubToken -TokenType FleetRead
            $result | Should -Be "fleet-token-value"
            Remove-Item Env:\FLEET_GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
        }

        It "returns CodingRead token from env var" {
            $env:GITHUB_TOKEN_READALL = "coding-read-token"
            $result = Get-GitHubToken -TokenType CodingRead
            $result | Should -Be "coding-read-token"
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
        }

        It "returns CodingWrite token from env var" {
            $env:GITHUB_TOKEN_PUSHSELECT = "coding-write-token"
            $result = Get-GitHubToken -TokenType CodingWrite
            $result | Should -Be "coding-write-token"
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
        }

        It "uses SecretEnv hashtable priority over env var" {
            $env:FLEET_GITHUB_TOKEN_READALL = "env-var-value"
            $result = Get-GitHubToken -TokenType FleetRead -SecretEnv @{ "FLEET_GITHUB_TOKEN_READALL" = "secret-env-value" }
            $result | Should -Be "secret-env-value"
            Remove-Item Env:\FLEET_GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
        }

        It "falls back to AWS SM when env var is missing" {
            Mock Get-SecretFromAws { return "aws-token-value" }
            $result = Get-GitHubToken -TokenType FleetRead -SsoProfile "test-profile"
            $result | Should -Be "aws-token-value"
        }

        It "returns null when no source provides the token" {
            $result = Get-GitHubToken -TokenType FleetRead
            $result | Should -BeNullOrEmpty
        }

        It "returns null with SsoProfile when AWS SM also fails" {
            Mock Get-SecretFromAws { throw "AWS SM error" }
            $result = Get-GitHubToken -TokenType CodingRead -SsoProfile "test-profile"
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Select-GitHubToken" -Tag "Git" {
        It "selects CodingRead for read operation" {
            $env:GITHUB_TOKEN_READALL = "read-token"
            $result = Select-GitHubToken -Operation read
            $result | Should -Be "read-token"
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
        }

        It "selects CodingWrite for write operation" {
            $env:GITHUB_TOKEN_PUSHSELECT = "write-token"
            $result = Select-GitHubToken -Operation write
            $result | Should -Be "write-token"
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
        }

        It "selects CodingWrite for push operation" {
            $env:GITHUB_TOKEN_PUSHSELECT = "push-token"
            $result = Select-GitHubToken -Operation push
            $result | Should -Be "push-token"
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
        }

        It "selects FleetRead for fleet_read operation" {
            $env:FLEET_GITHUB_TOKEN_READALL = "fleet-read-token"
            $result = Select-GitHubToken -Operation fleet_read
            $result | Should -Be "fleet-read-token"
            Remove-Item Env:\FLEET_GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
        }

        It "rejects invalid operation values" {
            { Select-GitHubToken -Operation invalid_op } | Should -Throw
        }
    }
}
