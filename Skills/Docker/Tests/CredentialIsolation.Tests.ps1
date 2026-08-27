#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for credential isolation tests')]
param()

# ==============================================================================
# Interclaw — CredentialIsolation.Tests.ps1
# Source: credential isolation (Scripts/1Provision.ps1)
# ==============================================================================
# LIVE integration tests validating the three-tier credential model against real AWS.
#
# Requires: INTERCLAW_RUN_INTEGRATION_TESTS=true
#           Agent/Drone/Installer credentials available via env vars or Docker secrets.
#
# Pester 5 syntax. When the env var is not set, tests short-circuit inside each
# It block (matching Pester 3 pattern for compatibility).
# ==============================================================================

$HelpersPath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"

Describe "Credential Isolation — static unit tests" -Tag "CredentialIsolation", "Security", "Regression" {
    It "Invoke-WithCredentialSwap function exists in Core module" {
        $modulePath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"
        if (Test-Path $modulePath) {
            . $modulePath
            { Get-Command -Name Invoke-WithCredentialSwap -ErrorAction Stop } | Should -Not -Throw
        }
    }
}

Describe "Interclaw Credential Isolation Integration Tests" -Tag "CredentialIsolation", "Regression-Only" {

    BeforeAll {
        $script:SkipIntegration = ($env:INTERCLAW_RUN_INTEGRATION_TESTS -ne "true")

        if ($script:SkipIntegration) {
            Write-Host "Skipping integration tests. Set INTERCLAW_RUN_INTEGRATION_TESTS=true to enable."
            return
        }

        if (-not (Test-Path $HelpersPath)) {
            throw "Helpers script not found at: $HelpersPath"
        }

        . $HelpersPath

        function Get-TestCredential {
            param(
                [Parameter(Mandatory = $true)]
                [ValidateSet("AGENT", "DRONE", "INSTALLER")]
                [string]$Role,
                [Parameter(Mandatory = $true)]
                [ValidateSet("AccessKeyId", "SecretAccessKey")]
                [string]$Type
            )

            $suffix = if ($Type -eq "AccessKeyId") { "ACCESS_KEY_ID" } else { "SECRET_ACCESS_KEY" }
            $dockerSuffix = if ($Type -eq "AccessKeyId") { "aws_id" } else { "aws_secret" }

            # 1. Explicit env vars (e.g. ORCHESTRATOR_TEST_AGENT_ACCESS_KEY_ID)
            $explicitVar = "ORCHESTRATOR_TEST_${Role}_${suffix}"
            $explicitValue = [Environment]::GetEnvironmentVariable($explicitVar)
            if (-not [string]::IsNullOrWhiteSpace($explicitValue)) { return $explicitValue }

            # 2. Role-specific env vars (e.g. AGENT_ACCESS_KEY_ID)
            $roleVar = if ($Role -eq "AGENT") { "AGENT_${suffix}" }
                       elseif ($Role -eq "DRONE") { "DRONE_${suffix}" }
                       else { "INSTALLER_${suffix}" }
            $roleValue = [Environment]::GetEnvironmentVariable($roleVar)
            if (-not [string]::IsNullOrWhiteSpace($roleValue)) { return $roleValue }

            # 3. Docker secret paths (container context)
            $dockerPaths = @()
            if ($Role -eq "AGENT") {
                $dockerPaths += "/run/secrets/${dockerSuffix}"
            }
            elseif ($Role -eq "DRONE") {
                $dockerPaths += "/run/secrets/drone_${dockerSuffix}"
            }

            foreach ($path in $dockerPaths) {
                if (Test-Path $path) {
                    $value = (Get-Content $path -Raw).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
                }
            }

            # 4. Installer fallback to current shell credentials
            if ($Role -eq "INSTALLER") {
                $fallbackVar = if ($Type -eq "AccessKeyId") { "AWS_ACCESS_KEY_ID" } else { "AWS_SECRET_ACCESS_KEY" }
                $fallbackValue = [Environment]::GetEnvironmentVariable($fallbackVar)
                if (-not [string]::IsNullOrWhiteSpace($fallbackValue)) { return $fallbackValue }
            }

            return $null
        }

        $script:AgentKeyId     = Get-TestCredential -Role AGENT -Type AccessKeyId
        $script:AgentSecretKey = Get-TestCredential -Role AGENT -Type SecretAccessKey
        $script:DroneKeyId     = Get-TestCredential -Role DRONE -Type AccessKeyId
        $script:DroneSecretKey = Get-TestCredential -Role DRONE -Type SecretAccessKey
        $script:InstallerKeyId = Get-TestCredential -Role INSTALLER -Type AccessKeyId
        $script:InstallerSecretKey = Get-TestCredential -Role INSTALLER -Type SecretAccessKey

        $missing = @()
        if ([string]::IsNullOrWhiteSpace($script:AgentKeyId))     { $missing += "Agent AccessKeyId" }
        if ([string]::IsNullOrWhiteSpace($script:AgentSecretKey)) { $missing += "Agent SecretAccessKey" }
        if ([string]::IsNullOrWhiteSpace($script:DroneKeyId))     { $missing += "Drone AccessKeyId" }
        if ([string]::IsNullOrWhiteSpace($script:DroneSecretKey)) { $missing += "Drone SecretAccessKey" }
        if ([string]::IsNullOrWhiteSpace($script:InstallerKeyId)) { $missing += "Installer AccessKeyId" }
        if ([string]::IsNullOrWhiteSpace($script:InstallerSecretKey)) { $missing += "Installer SecretAccessKey" }

        if ($missing.Count -gt 0) {
            throw "Missing credentials for integration tests: $($missing -join ', ')"
        }
    }

    It "Agent credentials: iam list-users should return AccessDenied" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:AgentKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:AgentSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws iam list-users 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -ne 0 -and $output -match "AccessDenied") { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Not -Be 0
            $output | Should -Match "AccessDenied"
        }
    }

    It "Agent credentials: bedrock list-inference-profiles should succeed" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:AgentKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:AgentSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            while ($retry -lt 10) {
                $raw = aws bedrock list-inference-profiles 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) { break }
                if (($raw -join "`n") -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Be 0
        }
    }

    It "Agent credentials: sso-admin list-instances should return AccessDenied" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:AgentKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:AgentSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws sso-admin list-instances 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -ne 0 -and $output -match "AccessDenied") { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Not -Be 0
            $output | Should -Match "AccessDenied"
        }
    }

    It "Drone credentials: iam list-users should succeed" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:DroneKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:DroneSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws iam list-users 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -eq 0) { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            if ($exitCode -ne 0) {
                Write-Host "DEBUG: Drone IAM list-users failed after $retry retries. Exit=$exitCode Output=$output" -ForegroundColor Red
            }
            $exitCode | Should -Be 0
        }
    }

    It "Drone credentials: sso-admin list-instances should return AccessDenied" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:DroneKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:DroneSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws sso-admin list-instances 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -ne 0 -and $output -match "AccessDenied") { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Not -Be 0
            $output | Should -Match "AccessDenied"
        }
    }

    It "Drone credentials: iam list-roles should return AccessDenied" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:DroneKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:DroneSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws iam list-roles 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -ne 0 -and $output -match "AccessDenied") { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Not -Be 0
            $output | Should -Match "AccessDenied"
        }
    }

    It "Drone credentials: organizations list-accounts should return AccessDenied" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:DroneKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:DroneSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            $output = ""
            while ($retry -lt 10) {
                $raw = aws organizations list-accounts 2>&1
                $exitCode = $LASTEXITCODE
                $output = ($raw -join "`n")
                if ($exitCode -ne 0 -and $output -match "AccessDenied") { break }
                if ($output -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Not -Be 0
            $output | Should -Match "AccessDenied"
        }
    }

    It "Installer credentials: iam list-users should succeed" {
        if ($script:SkipIntegration) { return }

        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString $script:InstallerKeyId -AsPlainText -Force) `
                                  -SecretAccessKey (ConvertTo-SecureString $script:InstallerSecretKey -AsPlainText -Force) `
                                  -ScriptBlock {
            $retry = 0
            $exitCode = -1
            while ($retry -lt 10) {
                $raw = aws iam list-users 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) { break }
                if (($raw -join "`n") -match "InvalidClientTokenId|SignatureDoesNotMatch") {
                    Start-Sleep -Seconds 5
                    $retry++
                    continue
                }
                break
            }
            $exitCode | Should -Be 0
        }
    }
}
