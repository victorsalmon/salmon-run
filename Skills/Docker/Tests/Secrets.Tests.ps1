#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Secrets tests')]
param()

# ==============================================================================
# SalmonRun.Secrets Get-SecretFromAws stale-cache TTL fallback tests
# Regression coverage for the SecretCacheTtl -> SecretsCacheTtl typo fix:
# the AWS-unavailable fallback must honor the configured TTL (default 60s) and
# return the cached value while the cache is fresh, instead of always null.
# ==============================================================================

Describe "Get-SecretFromAws stale-cache TTL fallback" -Tag "Secrets", "Regression" {
    BeforeAll {
        $script:SavedInstallProject = $env:INSTALL_PROJECT
        if (-not $env:INSTALL_PROJECT) { $env:INSTALL_PROJECT = "FRAD" }
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Identity\SalmonRun.Identity.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
        $script:FakeBinDir = Join-Path $env:TEMP "Interclaw-Secrets-FakeBin-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:FakeBinDir -Force
        $script:OrigPath = $env:PATH
        InModuleScope SalmonRun.Secrets {
            $script:TestSid = "Interclaw/FRAD/Orchestrator"
        }
    }
    AfterAll {
        if ($script:SavedInstallProject) { $env:INSTALL_PROJECT = $script:SavedInstallProject } else { Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue }
        if (Test-Path $script:FakeBinDir) { Remove-Item -Recurse -Force $script:FakeBinDir }
    }
    BeforeEach {
        # Cut PATH to an empty bin dir — the `aws` command inside the fetch
        # scriptblock is unresolvable, so it throws CommandNotFoundException,
        # driving Get-SecretFromAws into the AWS-unavailable catch block (the
        # stale-cache TTL fallback path under test).
        $env:PATH = $script:FakeBinDir
        Clear-SecretCache
        InModuleScope SalmonRun.Secrets {
            $script:SecretsCache[$script:TestSid] = "{`"TEST_KEY`":`"cached-secret-value`"}" | ConvertFrom-Json
            $script:SecretsCacheTimestamps[$script:TestSid] = [datetime]::UtcNow.AddSeconds(-1)
            $script:SecretsCacheLoaded[$script:TestSid] = $false
        }
    }
    AfterEach {
        $env:PATH = $script:OrigPath
    }

    It "returns the cached value when AWS is down and cache is within TTL" {
        $result = Get-SecretFromAws -KeyName "TEST_KEY"
        $result | Should -Be "cached-secret-value" -Because "a fresh cache (< TTL) must survive an AWS outage instead of returning null"
    }

    It "returns stale cached value with -AllowStale when cache exceeds TTL" {
        InModuleScope SalmonRun.Secrets {
            $script:SecretsCacheTimestamps[$script:TestSid] = [datetime]::UtcNow.AddSeconds(-120)
        }
        $result = Get-SecretFromAws -KeyName "TEST_KEY" -AllowStale
        $result | Should -Be "cached-secret-value" -Because "-AllowStale accepts degraded data beyond TTL"
    }

    It "returns null fail-closed when cache exceeds TTL and -AllowStale is not set" {
        InModuleScope SalmonRun.Secrets {
            $script:SecretsCacheTimestamps[$script:TestSid] = [datetime]::UtcNow.AddSeconds(-120)
        }
        $result = Get-SecretFromAws -KeyName "TEST_KEY"
        $result | Should -BeNullOrEmpty -Because "fail-closed: stale cache beyond TTL returns null without -AllowStale"
    }
}
