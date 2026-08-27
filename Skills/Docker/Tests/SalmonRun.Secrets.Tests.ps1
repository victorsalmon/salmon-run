#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for secrets tests')]
param()

# ==============================================================================
# SalmonRun.Secrets Module Tests
# ==============================================================================

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }

    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $OrchestratorModules = Join-Path $RepoRoot 'Orchestrator\Modules'
    $DockerModules = Join-Path $RepoRoot 'Skills\Docker\Modules'
    foreach ($modulePath in @($OrchestratorModules, $DockerModules)) {
        if ($env:PSModulePath -notlike "*$modulePath*") {
            $env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Identity\SalmonRun.Identity.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Private\module-state.ps1")

    Mock Write-SetupLog { }
    Mock Write-Host { }
    Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
    # Default docker / Invoke-Docker: simulate successful create flow so
    # Set-SwarmSecretSafe doesn't throw. Individual Set-SwarmSecretSafe Context
    # tests override these with call-logging mocks.
    Mock docker {
        $global:LASTEXITCODE = 0
    } -ModuleName SalmonRun.Secrets
    Mock Invoke-Docker {
        if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') { return 'fake_id' }
        if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'create') { return 'fake_id' }
        return $null
    } -ModuleName SalmonRun.Secrets

    # Coverage test setup
    $global:CovTarget2 = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Test-FleetSecretResolution.ps1"
    $global:CovTarget3 = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Public\Publish-WebMcpSecrets.ps1"
    $e2 = $null
    [System.Management.Automation.Language.Parser]::ParseFile($global:CovTarget2, [ref]$null, [ref]$e2)
    $global:CovErrors2 = $e2
}

Describe "SalmonRun.Secrets Module" -Tag "Secrets", "Regression-Only" {
    Context "Publish-CodingKeySecrets" -Tag "Secrets" {
        BeforeEach {
            $env:OPENCODE_GO1_KEY = "test-key-1"
            $env:OPENCODE_GO2_KEY = "test-key-2"
            $env:OPENCODE_GO3_KEY = "test-key-3"
            $env:OPENCODE_GO4_KEY = "test-key-4"
            $env:OPENCODE_GO5_KEY = "test-key-5"
            $env:OPENCODE_GO1_EMAIL = "go1@test.local"
            $env:OPENCODE_GO2_EMAIL = "go2@test.local"
            $env:OPENCODE_GO3_EMAIL = "go3@test.local"
            $env:OPENCODE_GO4_EMAIL = "go4@test.local"
            $env:OPENCODE_GO5_EMAIL = "go5@test.local"
            $env:OPENCODE_GO1_ON = "true"
            $env:OPENCODE_GO2_ON = "true"
            $env:OPENCODE_GO3_ON = "true"
            $env:OPENCODE_GO4_ON = "true"
            $env:OPENCODE_GO5_ON = "true"
            $env:OPENROUTER_CODE_KEY = "test-openrouter-code"
            $env:GITHUB_TOKEN_READALL = "test-github-token"
            $env:GITHUB_TOKEN_PUSHSELECT = "test-github-pushselect"
            $env:OPENCODE_SERVER_PASSWORD = "test-server-password"
        }
        AfterEach {
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_CODE_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_SERVER_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item Env:\WORKTREE_MCP_OPENCODE_TOKEN -ErrorAction SilentlyContinue
        }

        It "creates secrets for available keys" {
            $result = Publish-CodingKeySecrets
            $result | Should -BeGreaterThan 0
        }

        It "returns 0 when no keys available" {
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_CODE_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_SERVER_PASSWORD -ErrorAction SilentlyContinue
            Mock Set-SwarmSecretSafe { }
            { Publish-CodingKeySecrets } | Should -Throw
        }

        It "ON flag env vars are set when provided" {
            $env:OPENCODE_GO1_ON | Should -Be "true"
            $env:OPENCODE_GO1_KEY | Should -Be "test-key-1"
        }

        It "includes keys with ON=false in bundle for runtime gating" {
            $env:OPENCODE_GO2_ON = "false"
            $result = Publish-CodingKeySecrets
            # Read bundle: 5 keys + 5 emails + 5 ON flags + OPENROUTER_CODE_KEY + OPENCODE_SERVER_PASSWORD + GITHUB_TOKEN_READALL = 17
            # Write bundle: GITHUB_TOKEN_READALL + GITHUB_TOKEN_PUSHSELECT = 2. All present regardless of ON flag.
            $result | Should -Be 19
        }

        It "includes WORKTREE_CA_TOKEN in the write bundle when WORKTREE_MCP_OPENCODE_TOKEN is set" {
            $env:WORKTREE_MCP_OPENCODE_TOKEN = "test-worktree-token"
            $captured = @{}
            Mock Set-ContainerSecretBundle { param($BundleName, $Entries, $Label); $captured[$BundleName] = $Entries; return 1 } -ModuleName SalmonRun.Secrets
            try {
                $null = Publish-CodingKeySecrets
                $captured['coding_write_secrets_bundle']['WORKTREE_CA_TOKEN'] | Should -Be "test-worktree-token"
            } finally {
                Remove-Item Env:\WORKTREE_MCP_OPENCODE_TOKEN -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Test-SecretBundleSchema (required/optional keys)" -Tag "Secrets" {
        It "passes when only required keys present despite missing optional" {
            $schema = Get-ManifestSchemaForBundle -BundleName "coding_read_secrets_bundle"
            $entries = @{}
            foreach ($req in $schema.Required) { $entries[$req] = "x" }
            $result = Test-SecretBundleSchema -BundleName "coding_read_secrets_bundle" -Entries $entries
            $result.Valid | Should -BeTrue
            $result.Missing.Count | Should -Be 0
            $result.MissingOptional.Count | Should -BeGreaterThan 0
        }

        It "fails when required keys are missing" {
            $schema = Get-ManifestSchemaForBundle -BundleName "coding_read_secrets_bundle"
            $entries = @{ }
            $result = Test-SecretBundleSchema -BundleName "coding_read_secrets_bundle" -Entries $entries
            $result.Valid | Should -BeFalse
            $result.Missing.Count | Should -Be $schema.Required.Count
        }

        It "reports no missing optional when all keys present" {
            $schema = Get-ManifestSchemaForBundle -BundleName "coding_read_secrets_bundle"
            $entries = @{}
            foreach ($key in ($schema.Required + $schema.Optional)) { $entries[$key] = "x" }
            $result = Test-SecretBundleSchema -BundleName "coding_read_secrets_bundle" -Entries $entries
            $result.Valid | Should -BeTrue
            $result.MissingOptional.Count | Should -Be 0
        }
    }

    Context "Publish-CodingKeySecrets AWS fallback" -Tag "Secrets" {
        BeforeEach {
            Mock Set-SwarmSecretSafe { }
            # Return values for all coding-read keys — prevents infinite loop from
            # the dynamic key iterator and satisfies the promoted-required schema
            Mock Get-SecretFromAws {
                return "aws-fallback-value"
            } -ModuleName SalmonRun.Secrets -ParameterFilter {
                $KeyName -match '^OPENCODE_GO[1-5]_(KEY|ON|EMAIL)$' -or
                $KeyName -eq 'GITHUB_TOKEN_READALL' -or
                $KeyName -eq 'GITHUB_TOKEN_PUSHSELECT' -or
                $KeyName -eq 'OPENROUTER_CODE_KEY' -or
                $KeyName -eq 'OPENCODE_SERVER_PASSWORD'
            }
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO1_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO3_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO4_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO5_ON -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_CODE_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_PUSHSELECT -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_SERVER_PASSWORD -ErrorAction SilentlyContinue
        }
        AfterEach {
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_GO2_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READALL -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENCODE_SERVER_PASSWORD -ErrorAction SilentlyContinue
        }

        It "falls back to AWS SM when env vars are missing" {
            $result = Publish-CodingKeySecrets -SsoProfile "test-profile"
            $result | Should -BeGreaterThan 0
        }

        It "skips AWS SM fallback when SsoProfile is null" {
            { Publish-CodingKeySecrets } | Should -Throw
        }
    }

    Context "Import-SecretsFromAws hydration warnings" -Tag "Secrets" {
        BeforeEach {
            Mock Write-Warning { } -ModuleName SalmonRun.Secrets
            Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
        }

        It "warns when keys are not found in AWS SM or env" {
            Import-SecretsFromAws -Keys @("__TEST_MISSING_1__", "__TEST_MISSING_2__")
            Should -Invoke -CommandName Write-Warning -Times 1 -ModuleName SalmonRun.Secrets -ParameterFilter { $Message -match "keys not found in AWS SM or environment" }
        }

        It "does not warn when key is already in environment" {
            $env:__TEST_EXISTING_KEY__ = "test-value"
            Import-SecretsFromAws -Keys @("__TEST_EXISTING_KEY__")
            Remove-Item Env:\__TEST_EXISTING_KEY__ -ErrorAction SilentlyContinue
            Should -Invoke -CommandName Write-Warning -Times 0 -ModuleName SalmonRun.Secrets
        }
    }

    Context "Publish-GatewayPasswordSecret" -Tag "Secrets" {
        BeforeEach {
            Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
            Mock Set-SwarmSecretSafe { } -ModuleName SalmonRun.Secrets
        }
        It "returns false when password not found" {
            Publish-GatewayPasswordSecret -ProjectCode "TEST" -SsoProfile "test" | Should -BeFalse
        }

        It "creates secret when password found" {
            Mock Get-SecretFromAws { return "test-password" } -ModuleName SalmonRun.Secrets
            Publish-GatewayPasswordSecret -ProjectCode "TEST" -SsoProfile "test" | Should -BeTrue
        }
    }

    Context "FLEET_GITHUB_TOKEN_READALL" -Tag "Secrets" {
        It "is in SecretsOwnedKeys" {
            $owned = Get-SecretsOwnedKeys
            $owned | Should -Contain "FLEET_GITHUB_TOKEN_READALL"
        }

        It "is in bundle-manifest Fleet section" {
            $m = Get-BundleManifest
            $m.Fleet.Optional | Should -Contain "FLEET_GITHUB_TOKEN_READALL"
            $m.Fleet.SourceKeys | Should -Contain "FLEET_GITHUB_TOKEN_READALL"
        }

        It "is in SecretSchema FleetGithubToken" {
            $schema = Get-SecretSchema
            $schema.FleetGithubToken.Suffix | Should -Be "fleet_github_token"
            $schema.FleetGithubToken.Target | Should -Be "fleet_github_token"
        }
    }

    Context "Publish-GitHubTokenSecret" -Tag "Secrets" {
        It "is removed (replaced by SalmonRun.Git module)" {
            # Publish-GitHubTokenSecret was deleted — fleet now has its own
            # FLEET_GITHUB_TOKEN_READALL (published via New-FleetIamUser/Publish-FleetStack)
            # and token access is via SalmonRun.Git Get-GitHubToken / Select-GitHubToken
            { Get-Command Publish-GitHubTokenSecret -ErrorAction Stop } | Should -Throw
        }
    }

    Context "Secrets cache mutex — concurrent access" -Tag "Secrets", "Regression-Only" {
        BeforeEach {
            Mock Get-SecretFromAws { return $null }
            Mock Get-AwsSecretId { return "Interclaw/FRAD/Orchestrator" }
            Mock Write-SetupLog { }
            Mock Write-Warning { }
        }

        It "Clear-SecretCache runs without error" {
            { Clear-SecretCache } | Should -Not -Throw
        }

        It "Clear-SecretCache can be called multiple times" {
            Clear-SecretCache
            Clear-SecretCache
            Clear-SecretCache
            # No throw is the assertion
            $true | Should -Be $true
        }
    }

    Context "Get-SecretName" -Tag "Secrets" {
        It "constructs secret name from prefix and secret type" {
            $result = Get-SecretName -Prefix "TEST_ORCH" -Type "AwsId"
            $result | Should -Be "TEST_ORCH_aws_id"
        }
    }

    Context "Get-SecretObject" -Tag "Secrets" {
        BeforeEach {
            Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
            Mock Get-AwsSecretId { return "Interclaw/FRAD/Orchestrator" } -ModuleName SalmonRun.Secrets
        }
        It "returns null when secret not found" {
            $result = Get-SecretObject -Purpose "Orchestrator"
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Get-SecretsOwnedKeys" -Tag "Secrets" {
        It "returns the canonical list of secret-owned keys" {
            $result = Get-SecretsOwnedKeys
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Contain "INTERCLAW_GATEWAY_TOKEN"
        }

        It "reports AWS_REGION in the Aws-owned list" {
            $result = Get-SecretsOwnedKeys -List Aws
            $result | Should -Contain "AWS_REGION"
        }
    }

    Context "Test-ModuleState" -Tag "Secrets" {
        It "succeeds without throwing when module loaded correctly" {
            { Test-ModuleState } | Should -Not -Throw
        }
    }

    Context "Confirm-SecretWritePermission" -Tag "Secrets" {
        It "blocks writes when DRONE_MODE is true" {
            $env:DRONE_MODE = "true"
            try {
                Confirm-SecretWritePermission -Target "test" -Description "test write" | Should -Be $false
            } finally { Remove-Item Env:\DRONE_MODE -ErrorAction SilentlyContinue }
        }
    }

    Context "Invoke-CredentialCleanup" -Tag "Secrets", "DeployState" {
        BeforeAll {
            . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.DeployState\SalmonRun.DeployState.psm1")
        }
        It "runs without errors" {
            Mock Test-Path { return $true }
            Mock Get-ChildItem { return @() }
            { Invoke-CredentialCleanup } | Should -Not -Throw
        }
    }


    Context "Fallback Secret Chain" -Tag "Secrets" {
        BeforeEach {
            $script:SavedInstallProject = $env:INSTALL_PROJECT
            $env:INSTALL_PROJECT = "FRAD"
        }
        AfterEach {
            if ($null -eq $script:SavedInstallProject) { Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue }
            else { $env:INSTALL_PROJECT = $script:SavedInstallProject }
        }

        It "FallbackSecretIds contains Provisioning when INSTALL_PROJECT_FALLBACKS is not set" {
            $prev = $env:INSTALL_PROJECT_FALLBACKS
            Remove-Item Env:\INSTALL_PROJECT_FALLBACKS -ErrorAction SilentlyContinue
            $result = Get-FallbackSecretIds
            if ($prev) { $env:INSTALL_PROJECT_FALLBACKS = $prev }
            $result.Count | Should -Be 1
            $result[0] | Should -Be "Interclaw/FRAD/Provisioning"
        }

        It "FallbackSecretIds parses comma-separated env var" {
            $prev = $env:INSTALL_PROJECT_FALLBACKS
            $env:INSTALL_PROJECT_FALLBACKS = "FRAD,SHARED"
            $result = Get-FallbackSecretIds
            $env:INSTALL_PROJECT_FALLBACKS = $prev
            $result.Count | Should -Be 3
            $result[0] | Should -Be "Interclaw/FRAD/Provisioning"
            $result[1] | Should -Be "Interclaw/FRAD/FRAD"
            $result[2] | Should -Be "Interclaw/FRAD/SHARED"
        }

        It "Get-SecretFromAws contains fallback loop logic" {
            $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Public\Get-SecretFromAws.ps1") -Raw
            $content | Should -Match 'FallbackSecretIds'
        }

        It "Get-SecretFromAws iterates secret IDs" {
            $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Public\Get-SecretFromAws.ps1") -Raw
            $content | Should -Match 'foreach.*\$SecretIds'
        }
    }

    Context "Set-SwarmSecretSafe" -Tag "Secrets" {
        BeforeEach {
            $global:CallLog = @()
            $global:dockerCallLog = @()
            $global:dockerCreateCount = 0
            # Module-scoped mocks: Set-SwarmSecretSafe runs inside the SalmonRun.Secrets
            # module scope, so & docker / Invoke-Docker calls only resolve to mocks
            # applied with -ModuleName SalmonRun.Secrets. State is shared via $global:
            # because mock bodies execute in the module scope, not the test scope.
            Mock docker {
                $global:dockerCallLog += "$($args -join ' ')"
                if ($args[0] -eq 'secret' -and $args[1] -eq 'create') {
                    $global:dockerCreateCount++
                }
                $global:LASTEXITCODE = 0
            } -ModuleName SalmonRun.Secrets
            $env:ROTATE_PREEXISTING_KEYS = "true"
        }
        AfterEach {
            Remove-Item Env:\ROTATE_PREEXISTING_KEYS -ErrorAction SilentlyContinue
        }

        It "creates a new secret when none exists" {
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') { return 'created_id' }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'rm') { return $null }
                return $null
            } -ModuleName SalmonRun.Secrets

            Set-SwarmSecretSafe -SecretName 'test_secret' -SecretValue (ConvertTo-SecureString 'test_value' -AsPlainText -Force)

            $global:dockerCreateCount | Should -Be 1
            ($global:dockerCallLog -match 'secret create.*test_secret ').Count | Should -Be 1
            ($global:CallLog -match '^secret rm').Count | Should -Be 0
        }

        It "throws when secret value is empty" {
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                return $null
            } -ModuleName SalmonRun.Secrets

            $emptySecureString = New-Object System.Security.SecureString
            { Set-SwarmSecretSafe -SecretName 'test_secret' -SecretValue $emptySecureString } | Should -Throw
        }

        It "rotates existing secret safely" {
            # Current Set-SwarmSecretSafe flow: initial create succeeds but ls is empty,
            # so it rotates by creating a temp secret, removing the old, and recreating.
            Mock docker {
                $global:dockerCallLog += "$($args -join ' ')"
                if ($args[0] -eq 'secret' -and $args[1] -eq 'create') {
                    $global:dockerCreateCount++
                    # Initial (count 1), temp (test_secret_new), and final (count 3) all succeed
                    $global:LASTEXITCODE = 0
                    return ""
                }
                $global:LASTEXITCODE = 0
            } -ModuleName SalmonRun.Secrets
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') {
                    # ls for temp becomes truthy after it is created (count >= 2)
                    if ($DockerArgs -match 'name=test_secret_new' -and $global:dockerCreateCount -ge 2) { return 'truthy' }
                    # ls for final becomes truthy after the final create (count >= 3)
                    if ($DockerArgs -match 'name=test_secret' -and $global:dockerCreateCount -ge 3) { return 'truthy' }
                    return $null
                }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'inspect') {
                    # Return non-matching hash so rotation proceeds
                    return 'old_hash'
                }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'rm') { return $null }
                return $null
            } -ModuleName SalmonRun.Secrets

            Set-SwarmSecretSafe -SecretName 'test_secret' -SecretValue (ConvertTo-SecureString 'new_value' -AsPlainText -Force)

            # docker secret create called: initial + temp + final
            $global:dockerCreateCount | Should -Be 3
            ($global:dockerCallLog -match 'secret create.*test_secret_new').Count | Should -Be 1
            ($global:CallLog -match '^secret rm').Count | Should -Be 2
        }

        It "preserves temp fallback when final creation fails after rotation" {
            # First & docker create succeeds, re-run returns "already exists"
            # Temp creation succeeds, final creation fails - old secret rm'd, temp kept until cleanup
            Mock docker {
                $global:dockerCallLog += "$($args -join ' ')"
                if ($args[0] -eq 'secret' -and $args[1] -eq 'create') {
                    $global:dockerCreateCount++
                    if ($args -contains 'test_secret_new') {
                        $global:LASTEXITCODE = 0
                        return ""
                    }
                    if ($global:dockerCreateCount -eq 1) {
                        $global:LASTEXITCODE = 0
                        return ""
                    }
                    if ($global:dockerCreateCount -eq 4) {
                        # Final creation after rotation fails
                        $global:LASTEXITCODE = 1
                        return "Error response from daemon: rpc error: ..."
                    }
                    $global:LASTEXITCODE = 1
                    return "Error response from daemon: rpc error: ... already exists"
                }
                $global:LASTEXITCODE = 0
            } -ModuleName SalmonRun.Secrets
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') {
                    $isTarget = $DockerArgs -match 'name=test_secret'
                    $isNew = $DockerArgs -match 'name=test_secret_new'
                    if ($isNew) { return 'temp_id' }
                    if ($isTarget) { return $null }
                    return $null
                }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'inspect') { return 'old_hash' }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'rm') { return $null }
                return $null
            } -ModuleName SalmonRun.Secrets

            { Set-SwarmSecretSafe -SecretName 'test_secret' -SecretValue (ConvertTo-SecureString 'new_value' -AsPlainText -Force) } | Should -Throw

            ($global:CallLog -match '^secret rm test_secret$').Count | Should -Be 1
            # Temp secret rm'd in orphan cleanup and again in failure cleanup
            ($global:CallLog -match '^secret rm test_secret_new').Count | Should -Be 2
        }

        It "preserves Unicode characters in round-trip through Set-SwarmSecretSafe" {
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') { return 'created_id' }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'rm') { return $null }
                return $null
            } -ModuleName SalmonRun.Secrets

            $unicodeValue = @{ key = "café résumé 中文 español日本語" } | ConvertTo-Json -Compress
            Set-SwarmSecretSafe -SecretName 'unicode_test' -SecretValue (ConvertTo-SecureString $unicodeValue -AsPlainText -Force)

            $global:dockerCreateCount | Should -Be 1
        }

        It "keeps existing secret when temp creation fails" {
            # & docker create for test_secret fails with "already exists";
            # & docker create for test_secret_new fails → rotation aborts
            Mock docker {
                $global:dockerCallLog += "$($args -join ' ')"
                if ($args[0] -eq 'secret' -and $args[1] -eq 'create') {
                    $global:dockerCreateCount++
                    if ($args -contains 'test_secret') {
                        # First call succeeds (line 104), re-run (line 120) returns already-exists
                        if ($global:dockerCreateCount -eq 1) {
                            $global:LASTEXITCODE = 0
                            return ""
                        }
                        $global:LASTEXITCODE = 1
                        return "Error response from daemon: rpc error: ... already exists"
                    }
                    # Temp create (test_secret_new) fails
                    $global:LASTEXITCODE = 1
                    return "Error response from daemon: rpc error: ..."
                }
                $global:LASTEXITCODE = 0
            } -ModuleName SalmonRun.Secrets
            Mock Invoke-Docker {
                $global:CallLog += ($DockerArgs -join ' ')
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls') {
                    $isNew = $DockerArgs -match 'name=test_secret_new'
                    if ($isNew) { return $null }
                    return $null
                }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'inspect') { return 'old_hash' }
                if ($DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'rm') { return $null }
                return $null
            } -ModuleName SalmonRun.Secrets

            { Set-SwarmSecretSafe -SecretName 'test_secret' -SecretValue (ConvertTo-SecureString 'new_value' -AsPlainText -Force) } | Should -Throw

            ($global:dockerCallLog -match 'secret create.*test_secret_new').Count | Should -Be 1
            # Temp create failed before old secret removal - original secret unaffected
            ($global:CallLog -match '^secret rm test_secret_new').Count | Should -Be 0
            ($global:CallLog -match '^secret rm test_secret$').Count | Should -Be 0
        }
    }
}

Describe "Get-AwsSecretId" -Tag "Secrets" {
    BeforeAll {
        $script:SavedInstallProject = $env:INSTALL_PROJECT
        $env:INSTALL_PROJECT = "FRAD"
    }
    AfterAll {
        if ($null -eq $script:SavedInstallProject) { Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue }
        else { $env:INSTALL_PROJECT = $script:SavedInstallProject }
    }

    It "returns the Orchestrator path by default" {
        Get-AwsSecretId | Should -Be "Interclaw/FRAD/Orchestrator"
    }

    It "returns the Provisioning path when specified" {
        Get-AwsSecretId -Purpose Provisioning | Should -Be "Interclaw/FRAD/Provisioning"
    }
}

Describe "Read-CredentialManifest and template helpers" -Tag "Secrets" {
    BeforeAll {
        $script:ManifestTestDir = Join-Path $env:TEMP "Interclaw-Manifest-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ManifestTestDir "Infrastructure" "manifests") -Force
        $script:SavedRepoRootFn = Get-Content -Path function:Get-SalmonRunRepoRoot -ErrorAction SilentlyContinue
        Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:ManifestTestDir } -Force
    }
    AfterAll {
        if (Test-Path $script:ManifestTestDir) { Remove-Item -Recurse -Force $script:ManifestTestDir }
        if ($script:SavedRepoRootFn) {
            $null = Set-Content -Path function:Get-SalmonRunRepoRoot -Value $script:SavedRepoRootFn -Force
        }
    }

    It "Read-CredentialManifest returns parsed JSON" {
        $manifestData = '{"version":1,"secrets":[]}'
        Set-Content -Path (Join-Path $script:ManifestTestDir "Infrastructure" "manifests" "test-manifest.json") -Value $manifestData -Encoding utf8
        $result = Read-CredentialManifest -ManifestName "test"
        $result.version | Should -Be 1
    }

    It "Resolve-ManifestTemplate replaces <Project> placeholder" {
        $result = Resolve-ManifestTemplate -Template "secret_<Project>" -Context @{ ProjectCode = "FRAD" }
        $result | Should -Be "secret_FRAD"
    }

    It "Resolve-ManifestTemplate replaces all known placeholders" {
        $result = Resolve-ManifestTemplate -Template "<Project>/<Role>/<InstanceID>/<Prefix>/<Tier>" -Context @{ ProjectCode = "P"; RoleCode = "R"; InstanceId = "1"; Prefix = "P_R"; Tier = "global" }
        $result | Should -Be "P/R/1/P_R/global"
    }

    It "Resolve-ManifestTemplate returns null input unchanged" {
        Resolve-ManifestTemplate -Template $null -Context @{} | Should -BeNullOrEmpty
    }
}

Describe "Set-ContainerSecretBundle" -Tag "Secrets" {
    Context "Set-ContainerSecretBundle" -Tag "Secrets" {
        BeforeEach {
            Mock Set-SwarmSecretSafe { } -ModuleName SalmonRun.Secrets
            Mock Write-Warning { } -ModuleName SalmonRun.Secrets
            Mock Write-Verbose { }
            Mock Write-SetupLog { }
            # Disable install.json feature promotion so tests are deterministic
            # against the mocked manifest (Merge-BundleSchema is exercised elsewhere).
            Mock Get-InstallJsonFeatureSecrets { return @{} } -ModuleName SalmonRun.Secrets
            Mock Read-InstallJson { return $null } -ModuleName SalmonRun.Secrets
            Mock Get-BundleManifest { return @{
                Agent = @{ BASE = @{ Required = @('aws_id', 'aws_secret', 'gateway_token', 'openrouter_api_key'); Optional = @('telegram_bot_token') } }
                CodingRead = @{ Required = @('OPENCODE_GO1_KEY'); Optional = @('OPENCODE_GO2_KEY', 'OPENCODE_GO3_KEY') }
                CodingWrite = @{ Required = @('GITHUB_TOKEN_PUSHSELECT'); Optional = @('GITHUB_TOKEN_READALL') }
            } }
        }

        It "creates a secret bundle with entries" {
            $result = Set-ContainerSecretBundle -BundleName "TST_BASE_secrets_bundle" -Entries @{ aws_id = "x"; aws_secret = "x"; gateway_token = "x"; openrouter_api_key = "x" }
            $result | Should -Be 1
            Should -Invoke -CommandName Set-SwarmSecretSafe -Times 1 -ModuleName SalmonRun.Secrets
        }

        It "returns 1 for empty bundle" {
            $result = Set-ContainerSecretBundle -BundleName "TST_BASE_secrets_bundle" -Entries @{}
            $result | Should -Be 1
            Should -Invoke -CommandName Set-SwarmSecretSafe -Times 1 -ModuleName SalmonRun.Secrets
        }

        It "throws when required keys are missing" {
            Mock Get-BundleManifest { return @{
                Agent = @{ BASE = @{ Required = @('aws_id', 'aws_secret', 'gateway_token', 'openrouter_api_key'); Optional = @() } }
            } }
            { Set-ContainerSecretBundle -BundleName "TST_BASE_secrets_bundle" -Entries @{ unrelated_key = "val" } } | Should -Throw
        }

        It "warns when optional keys are missing" {
            Mock Get-BundleManifest { return @{
                Agent = @{ BASE = @{ Required = @('aws_id', 'aws_secret', 'gateway_token', 'openrouter_api_key'); Optional = @('telegram_bot_token') } }
            } }
            $result = Set-ContainerSecretBundle -BundleName "TST_BASE_secrets_bundle" -Entries @{ aws_id = "x"; aws_secret = "x"; gateway_token = "x"; openrouter_api_key = "x" }
            $result | Should -Be 1
            Should -Invoke -CommandName Write-Warning -Times 1 -ModuleName SalmonRun.Secrets
        }

        It "uses custom label when provided" {
            $result = Set-ContainerSecretBundle -BundleName "TST_BASE_secrets_bundle" -Entries @{ aws_id = "x"; aws_secret = "x"; gateway_token = "x"; openrouter_api_key = "x" } -Label "custom-label"
            $result | Should -Be 1
        }
    }
}

Describe "Get-SecretExpiry" -Tag "Secrets" {
    BeforeAll {
        $script:ExpiryTestDir = Join-Path $env:TEMP "Interclaw-Expiry-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:ExpiryTestDir -Force
    }
    AfterAll {
        if (Test-Path $script:ExpiryTestDir) { Remove-Item -Recurse -Force $script:ExpiryTestDir }
    }

    It "returns empty array when docker secret ls returns nothing" {
        Mock Invoke-Docker { $global:LASTEXITCODE = 0; return $null } -ModuleName SalmonRun.Secrets
        $result = Get-SecretExpiry -ThresholdDays 30
        $result | Should -BeNullOrEmpty
    }
}

Describe "Import-ProxyApiFromAws" -Tag "Secrets" {
    BeforeEach {
        Mock Invoke-AwsCommand {
            return [pscustomobject]@{ Output = "AccessDenied"; Success = $false }
        } -ModuleName SalmonRun.Secrets
        Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
        $env:INSTALL_PROJECT = "TEST"
    }
    AfterEach {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
    }

    It "returns false when secrets are not found" {
        Import-ProxyApiFromAws -ProjectCode "TEST" | Should -Be $false
    }

    It "returns true when secrets are successfully imported" {
        Mock Invoke-AwsCommand {
            return [pscustomobject]@{ Output = '{"ATTIO_READ_KEY":"test-value"}'; Success = $true }
        } -ModuleName SalmonRun.Secrets
        $result = Import-ProxyApiFromAws -ProjectCode "TEST"
        $result | Should -Be $true
    }
}

Describe "Publish-WebMcpSecrets" -Tag "Secrets" {
    It "returns false when no keys are available" {
        Mock Get-SecretFromAws { return $null } -ModuleName SalmonRun.Secrets
        Mock Invoke-Docker { return $null } -ModuleName SalmonRun.Secrets
        Mock Write-Warning { }
        Publish-WebMcpSecrets | Should -Be $false
    }
}

# === Coverage tests (merged from legacy coverage suite) ===

#Requires -Version 7.0

Describe "Test-SentrySecretResolution" -Tag "Coverage", "Sentry", "Regression-Only" {
    It "is syntactically valid PowerShell" { $global:CovErrors2 | Should -BeNullOrEmpty }
}

Describe "Publish-WebMcpSecrets" -Tag "Coverage", "Secrets", "Regression-Only" {
    It "is syntactically valid PowerShell" {
        $e3 = $null
        [System.Management.Automation.Language.Parser]::ParseFile($global:CovTarget3, [ref]$null, [ref]$e3)
        $e3 | Should -BeNullOrEmpty
    }
}

Describe "Cross-module bundle helper exports" -Tag "Secrets", "Regression-Only" {
    It "exports bundle helpers consumed cross-module by Publish-FleetStack and Test-FleetSecretHydration" {
        Get-Command Get-BundleManifest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-BookkeepingBundleName -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-BookkeepingBundleSuffix -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-SecretSchema -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Resolve-ManifestTemplate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-CredentialCrossReference -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "keeps bundle helpers listed in both the manifest FunctionsToExport and the psm1 Export-ModuleMember" {
        $psd1 = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.psd1") -Raw
        $psm1 = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.psm1") -Raw
        foreach ($fn in @('Get-BundleManifest', 'Get-BookkeepingBundleName', 'Get-BookkeepingBundleSuffix', 'Get-SecretSchema')) {
            $psd1 | Should -Match "'$fn'"
            $psm1 | Should -Match "'$fn'"
        }
    }
}


