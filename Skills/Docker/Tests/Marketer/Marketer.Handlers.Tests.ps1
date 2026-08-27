#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for SalmonRun.Marketer Handlers
# ==============================================================================
#
# (a) This file tests that SalmonRun.Marketer's Handlers/<Name>.ps1 files
#     follow the expected container-handler contract: function definitions,
#     capability gates, and audit entries.
#
# (b) The Skip gate was removed in marketer-04 (2026-07-15) now that the
#     is-marketer container ships. Tests run during Review as normal.
#
# (c) (Unused — kept for forward compatibility if re-gating is needed.)
#
# ==============================================================================

Describe "Marketer Handlers" -Tag "Marketer" {

    It "Marketer module files exist" {
        $ModulePath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer"
        $ModulePath | Should -Exist
        $ModuleMain = Join-Path $ModulePath "SalmonRun.Marketer.psm1"
        $ModuleMain | Should -Exist
    }

    It "Write-MarketerAuditEntry is defined exactly once" {
        $moduleDir = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer"
        $count = 0
        Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw
            if ($content -match 'function Write-MarketerAuditEntry') { $count++ }
        }
        $count | Should -Be 1
    }

    It "Private/load-secrets.ps1 exists and references Get-MarketerSecretBundle" {
        $loaderPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\load-secrets.ps1"
        $loaderPath | Should -Exist
        $content = Get-Content -Path $loaderPath -Raw
        $content | Should -Match "Get-MarketerSecretBundle"
    }

    It "Private/Common.ps1 does not exist (duplicate removed)" {
        $commonPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\Common.ps1"
        $commonPath | Should -Not -Exist
    }

    It "SalmonRun.Marketer.psm1 calls Initialize-MarketerSecrets" {
        $psm1Path = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\SalmonRun.Marketer.psm1"
        $psm1Path | Should -Exist
        $content = Get-Content -Path $psm1Path -Raw
        $content | Should -Match "Initialize-MarketerSecrets"
    }

    It "Invoke-ApolloSearch no longer throws NotImplementedException" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1"
        $handlerPath | Should -Exist
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Not -Match "NotImplementedException"
    }

    It "Invoke-ApolloEnrich no longer throws NotImplementedException" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1"
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Not -Match "NotImplementedException"
    }

    It "Test-MarketerCapability apollo:search gate checks ApolloSearchKey" {
        $capPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\Test-MarketerCapability.ps1"
        $capPath | Should -Exist
        $content = Get-Content -Path $capPath -Raw
        $content | Should -Match "ApolloSearchKey"
    }

    It "Test-MarketerCapability has apollo:enrich entry" {
        $capPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\Test-MarketerCapability.ps1"
        $content = Get-Content -Path $capPath -Raw
        $content | Should -Match "apollo:enrich"
    }

    It "Get-MarketerSecretBundle returns ApolloEnrichKey" {
        $bundlePath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Public\Get-MarketerSecretBundle.ps1"
        $bundlePath | Should -Exist
        $content = Get-Content -Path $bundlePath -Raw
        $content | Should -Match "ApolloEnrichKey"
    }

    It "Invoke-ApolloSearch has capability gate call" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1"
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Match "Test-MarketerCapability.*apollo:search"
    }

    It "Invoke-ApolloEnrich has capability gate call" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1"
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Match "Test-MarketerCapability.*apollo:enrich"
    }

    It "Secret names in load-secrets.ps1 match Test-MarketerCapability variable names" {
        $loaderPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\load-secrets.ps1"
        $capPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\Test-MarketerCapability.ps1"
        $loaderContent = Get-Content -Path $loaderPath -Raw
        $capContent = Get-Content -Path $capPath -Raw
        $capContent | Select-String -Pattern '\$script:(\w+)' -AllMatches | ForEach-Object {
            $_.Matches | ForEach-Object {
                $varName = $_.Groups[1].Value
                if ($varName -notmatch '^(ApolloSearchKey|ApolloEnrichKey)$') {
                    $loaderContent | Should -Match "\`$script:$varName"
                }
            }
        }
    }

    It "Invoke-ZeroBounceValidate no longer throws NotImplementedException" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\ZeroBounce\EmailValidation.ps1"
        $handlerPath | Should -Exist
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Not -Match "NotImplementedException"
    }

    It "Invoke-ZeroBounceValidate has capability gate call" {
        $handlerPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\ZeroBounce\EmailValidation.ps1"
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Match "Test-MarketerCapability.*zerobounce:validate"
    }

    It "Test-MarketerCapability zerobounce:validate gate checks ZerobounceApiKey" {
        $capPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Private\Test-MarketerCapability.ps1"
        $content = Get-Content -Path $capPath -Raw
        $content | Should -Match "ZerobounceApiKey"
    }

    It "ZeroBounce/EmailValidation.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Marketer\Handlers\ZeroBounce\EmailValidation.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}
