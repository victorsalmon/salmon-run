#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:ModulesDir = Join-Path $script:RepoRoot "Skills\Docker\Modules"
    $script:OrchestratorModules = Join-Path $script:RepoRoot "Orchestrator\Modules"
    foreach ($modulePath in @($script:OrchestratorModules, $script:ModulesDir)) {
        if ($env:PSModulePath -notlike "*$modulePath*") {
            $env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    $env:INSTALL_PROJECT = 'TEST'
    $env:TELEGRAM_BOT_TOKEN_ORCH = 'TEST'
    $env:TELEGRAM_OWNER_USERID = '123'

    Import-Module (Join-Path $script:ModulesDir 'SalmonRun.Audit\SalmonRun.Audit.psd1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ModulesDir 'SalmonRun.Fleet\SalmonRun.Fleet.psd1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ModulesDir 'SalmonRun.Secrets\SalmonRun.Secrets.psd1') -Force -DisableNameChecking -ErrorAction Stop

    Mock -ModuleName SalmonRun.Secrets Write-FleetLog { }
    Mock Write-AuditEntry { }
    Mock Write-Warning { }
    Mock Write-Debug { }
    Mock Write-Verbose { }

    $global:dockerCallLog = [System.Collections.Generic.List[string]]::new()
    $global:awsCallLog = [System.Collections.Generic.List[string]]::new()
    $global:httpCallLog = [System.Collections.Generic.List[string]]::new()
    $global:telegramCalls = [System.Collections.Generic.List[string]]::new()

    Mock -ModuleName SalmonRun.Secrets Invoke-Docker {
        $cmd = $DockerArgs -join ' '
        if ($DockerArgs[0] -eq 'secret' -or ($DockerArgs[0] -eq 'service' -and $DockerArgs[1] -eq 'update')) {
            $global:dockerCallLog.Add("docker $cmd")
        }
        if ($DockerArgs[0] -eq 'service' -and $DockerArgs[1] -eq 'ps') {
            return 'test_service.1.abc Running'
        }
        $global:LASTEXITCODE = 0
    }

    Mock -ModuleName SalmonRun.Secrets Invoke-AwsCommand {
        $cmd = $Command.ToString()
        $global:awsCallLog.Add($cmd)
        return [PSCustomObject]@{ Output = '{ "AccessKeyLastUsed": { "LastUsedDate": "2026-06-20T10:00:00Z" } }'; ExitCode = 0; Success = $true }
    }

    Mock -ModuleName SalmonRun.Secrets Send-RotationAlert { }

    Mock -ModuleName SalmonRun.Secrets Invoke-WebRequest {
        $global:httpCallLog.Add("$($Method ?? 'GET') $Uri")
        $mockResponse = [PSCustomObject]@{ StatusCode = 200; Content = '{}' }
        return $mockResponse
    } -ParameterFilter { $Uri -notlike '*api.telegram.org*' }

    Mock -ModuleName SalmonRun.Secrets Invoke-WebRequest {
        $global:telegramCalls.Add($Uri)
        $mockResponse = [PSCustomObject]@{ StatusCode = 200; Content = '{"ok":true}' }
        return $mockResponse
    } -ParameterFilter { $Uri -like '*api.telegram.org*' }
}

Describe "Invoke-SecretRotation" -Tag "Secrets", "Rotation", "Unit" {
    BeforeEach {
        $global:dockerCallLog.Clear()
        $global:awsCallLog.Clear()
        $global:httpCallLog.Clear()
        $global:telegramCalls.Clear()
    }

    Context "Basic rotation" -Tag "Secrets", "Rotation", "Unit" {
        It "rotates a secret bundle successfully" {
            $result = Invoke-SecretRotation -ServiceName "test_service" `
                -BundleData @{ KEY = "value" } -MountTarget "test_bundle"

            $result.Success | Should -BeTrue
            $result.RotationDone | Should -BeTrue
            ($global:dockerCallLog -match 'secret create.*test_service_secrets_bundle_rotating').Count | Should -BeGreaterThan 0
            ($global:dockerCallLog -match 'service update').Count | Should -BeGreaterThan 0
        }

        It "creates temp secret, swaps, removes old, re-creates final, swaps back, cleans up" {
            Invoke-SecretRotation -ServiceName "test_service" `
                -BundleData @{ KEY = "val" } -MountTarget "bundle"

            $global:dockerCallLog[0] | Should -Match 'secret create.*_rotating'
            $global:dockerCallLog[1] | Should -Match 'service update.*--secret-rm.*--secret-add'
            $global:dockerCallLog[2] | Should -Match 'secret rm.*_secrets_bundle$'
            $global:dockerCallLog[3] | Should -Match 'secret create.*_secrets_bundle -'
            $global:dockerCallLog[4] | Should -Match 'service update.*--secret-rm.*_rotating.*--secret-add.*_secrets_bundle'
            $global:dockerCallLog[5] | Should -Match 'secret rm.*_rotating'
        }

        It "returns hashtable report" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" -BundleData @{ K = "v" }
            $result -is [hashtable] | Should -BeTrue
            $result.Keys | Should -Contain "Success"
            $result.Keys | Should -Contain "ServiceName"
            $result.Keys | Should -Contain "SecretName"
            $result.Keys | Should -Contain "RotationDone"
        }
    }

    Context "Rotation with verification" -Tag "Secrets", "Rotation", "Unit" {
        It "runs verification when -Verify is specified" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ KEY = "value" } -Verify

            $result.VerifyPassed | Should -Not -BeNullOrEmpty
            $result.VerifyDetails | Should -Not -BeNullOrEmpty
            $result.VerifyDetails[0] | Should -Match "Post-rotation verification"
        }

        It "verifies IAM keys with aws iam get-access-key-last-used" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ aws_id = "AKIA123"; aws_secret = "secret123" } `
                -Verify -SecretType "iam"

            $result.VerifyPassed | Should -BeTrue
            ($global:awsCallLog -match 'iam get-access-key-last-used').Count | Should -BeGreaterThan 0
        }

        It "verifies fleet API tokens with HTTP call" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ fleet_api_token = "test-token" } `
                -Verify -SecretType "fleet-api"

            $result.VerifyPassed | Should -BeTrue
            ($global:httpCallLog -match 'localhost').Count | Should -BeGreaterThan 0
        }

        It "reports null verify when -Verify not specified" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ K = "v" }

            $result.VerifyPassed | Should -BeNullOrEmpty
            $result.VerifyDetails | Should -BeNullOrEmpty
        }

        It "passes verification for unknown secret types" {
            $result = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ K = "v" } -Verify -SecretType "unknown"

            $result.VerifyPassed | Should -BeTrue
        }
    }

    Context "Verification failure alerting" -Tag "Secrets", "Rotation", "Unit" {
        BeforeEach {
            Mock -ModuleName SalmonRun.Secrets Invoke-RotationVerification {
                return @{
                    Passed = $false
                    Errors = @("Simulated verification failure")
                    Details = @("Verification attempted")
                }
            }
        }

        It "logs CRITICAL on verification failure" {
            $null = Invoke-SecretRotation -ServiceName "test_svc" `
                -BundleData @{ KEY = "value" } -Verify

            Should -Invoke -ModuleName SalmonRun.Secrets -CommandName Write-FleetLog -Times 1 -ParameterFilter {
                $Level -eq "CRITICAL"
            }
        }
    }

    Context "Rotation failure" -Tag "Secrets", "Rotation", "Unit" {
        It "throws on docker secret create failure" {
            Mock -ModuleName SalmonRun.Secrets Invoke-Docker {
                $global:LASTEXITCODE = 1
                return "error"
            } -ParameterFilter { $DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'create' -and $DockerArgs[2] -match '_rotating' }

            { Invoke-SecretRotation -ServiceName "test_svc" -BundleData @{ K = "v" } } | Should -Throw
        }

        It "throws on service update failure" {
            Mock -ModuleName SalmonRun.Secrets Invoke-Docker {
                $global:LASTEXITCODE = 1
                return "error"
            } -ParameterFilter { $DockerArgs[0] -eq 'service' -and $DockerArgs[1] -eq 'update' }

            { Invoke-SecretRotation -ServiceName "test_svc" -BundleData @{ K = "v" } } | Should -Throw
        }

        It "cleans up temp secret on failure" {
            Mock -ModuleName SalmonRun.Secrets Invoke-Docker {
                $global:LASTEXITCODE = 1
                return "error"
            } -ParameterFilter { $DockerArgs[0] -eq 'service' -and $DockerArgs[1] -eq 'update' }

            { Invoke-SecretRotation -ServiceName "test_svc" -BundleData @{ K = "v" } } | Should -Throw

            ($global:dockerCallLog -match 'secret rm.*_rotating').Count | Should -BeGreaterThan 0
        }
    }

    Context "Secret name resolution" -Tag "Secrets", "Rotation", "Unit" {
        It "derives secret name from service name" {
            Invoke-SecretRotation -ServiceName "FRAD_is-bookkeeping" `
                -BundleData @{ KEY = "value" }

            ($global:dockerCallLog[0] -match 'FRAD_is-bookkeeping_secrets_bundle_rotating').Count | Should -BeGreaterThan 0
        }

        It "accepts explicit OldSecretName and NewSecretName" {
            Invoke-SecretRotation -ServiceName "svc" -OldSecretName "old_bundle" `
                -NewSecretName "new_bundle" -BundleData @{ K = "v" }

            $global:dockerCallLog[0] | Should -Match 'new_bundle_rotating'
            $global:dockerCallLog[2] | Should -Match 'secret rm old_bundle'
            $global:dockerCallLog[3] | Should -Match 'secret create new_bundle -'
        }
    }
}

Describe "Get-SecretExpiry" -Tag "Secrets", "Rotation", "Unit" {
    BeforeEach {
        Mock -ModuleName SalmonRun.Secrets Invoke-Docker {
            $now = Get-Date
            $lines = @(
                ("ID1`tsecret_alpha`t" + $now.AddDays(-100).ToString('yyyy-MM-dd HH:mm:ss'))
                ("ID2`tsecret_beta`t" + $now.AddDays(-70).ToString('yyyy-MM-dd HH:mm:ss'))
                ("ID3`tsecret_gamma`t" + $now.AddDays(-40).ToString('yyyy-MM-dd HH:mm:ss'))
                ("ID4`tsecret_delta`t" + $now.AddDays(-10).ToString('yyyy-MM-dd HH:mm:ss'))
            )
            $global:LASTEXITCODE = 0
            return $lines -join "`n"
        } -ParameterFilter { $DockerArgs[0] -eq 'secret' -and $DockerArgs[1] -eq 'ls' }
    }

    Context "Age classification" -Tag "Secrets", "Rotation", "Unit" {
        It "classifies secrets by age with default 30-day threshold" {
            $results = Get-SecretExpiry
            $types = $results | ForEach-Object { $_.Status }

            $types | Should -Contain "expired"
            $types | Should -Contain "stale"
            $types | Should -Contain "fresh"
        }

        It "returns all expected properties" {
            $results = Get-SecretExpiry
            $results.Count | Should -BeGreaterThan 0

            $entry = $results[0]
            $entry.Keys | Should -Contain "SecretName"
            $entry.Keys | Should -Contain "CreatedAt"
            $entry.Keys | Should -Contain "AgeDays"
            $entry.Keys | Should -Contain "Status"
            $entry.Keys | Should -Contain "RecommendedAction"
        }

        It "recommends rotate-urgent for expired secrets" {
            $results = Get-SecretExpiry
            $expired = $results | Where-Object { $_.Status -eq "expired" }
            $expired | ForEach-Object { $_.RecommendedAction | Should -Be "rotate-urgent" }
        }
    }

    Context "Custom threshold" -Tag "Secrets", "Rotation", "Unit" {
        It "classifies with custom -ThresholdDays" {
            $results = Get-SecretExpiry -ThresholdDays 60
            $results | Where-Object { $_.Status -eq "fresh" } | Should -Not -BeNullOrEmpty
        }
    }

    Context "Policy file" -Tag "Secrets", "Rotation", "Unit" {
        It "handles missing policy file gracefully" {
            $results = Get-SecretExpiry -PolicyPath (Join-Path $TestDrive "missing-policy.json")
            $results.Count | Should -BeGreaterThan 0
        }
    }
}

Describe "Send-RotationAlert" -Tag "Secrets", "Rotation", "Unit" {
    BeforeEach {
        $global:telegramCalls.Clear()
    }

    It "sends Telegram alert when tokens are available" {
        Send-RotationAlert -Message "Test alert" -Level "CRITICAL"

        Should -Invoke -ModuleName SalmonRun.Secrets -CommandName Invoke-WebRequest -Times 1 -ParameterFilter {
            $Uri -like '*api.telegram.org*'
        }
    }

    It "does not throw on failure" {
        Mock Invoke-WebRequest { throw "Network error" }
        { Send-RotationAlert -Message "test" -Level "CRITICAL" } | Should -Not -Throw
    }
}
