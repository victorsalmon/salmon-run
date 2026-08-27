#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Hydration Readiness Tests — pre-flight validation of the entire secret pipeline
# ==============================================================================
# These tests exercise Test-HydrationReadiness, which is the same function
# that 0setup.ps1 runs during pre-flight (Phase 8.5). If all tests pass here,
# the secret-hydration portion of 0setup.ps1 should succeed.
# ==============================================================================

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")

    Mock Write-SetupLog { }
    Mock Write-Warning { }
    function Read-InstallJson { return @{ features = @{} } }
    Mock Write-Verbose { }
    Mock Get-SecretFromAws { return $null }
}

Describe "HydrationReadiness" -Tag "HydrationReadiness", "Secrets", "Preflight", "Regression-Only" {

    Context "Function structure" -Tag "HydrationReadiness" {
        It "exports Test-HydrationReadiness" {
            (Get-Command Test-HydrationReadiness -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }

        It "returns a collection of result objects" {
            $results = Test-HydrationReadiness
            $results | Should -Not -BeNullOrEmpty
            $results.Count | Should -BeGreaterThan 5
        }

        It "each result has Check, Passed, Detail, Remediation, Source properties" {
            $results = Test-HydrationReadiness
            foreach ($r in $results) {
                $r.Check | Should -Not -BeNullOrEmpty
                $r.Passed | Should -BeOfType [bool]
                $r.Detail | Should -Not -BeNullOrEmpty
                $r.Remediation | Should -BeOfType [string]
                $r.Source | Should -Not -BeNullOrEmpty
            }
        }

        It "reports manifest loaded successfully" {
            $results = Test-HydrationReadiness
            $manifest = $results | Where-Object { $_.Check -eq 'ManifestLoaded' }
            $manifest | Should -Not -BeNullOrEmpty
            $manifest.Passed | Should -BeTrue
        }

        It "includes an overall summary result" {
            $results = Test-HydrationReadiness
            $summary = $results | Where-Object { $_.Check -eq 'Overall' }
            $summary | Should -Not -BeNullOrEmpty
            $summary.Detail | Should -Match '\d+ passed'
        }
    }

    Context "Bundle type coverage" -Tag "HydrationReadiness" {
        It "covers agent role BASE" {
            $results = Test-HydrationReadiness
            $results.Check -contains 'BASE' | Should -BeTrue
        }

        It "covers Sentry, Coding, Proxy, WebMcp bundles" {
            $results = Test-HydrationReadiness
            $results.Check -contains 'Sentry' | Should -BeTrue
            $results.Check -contains 'Coding' | Should -BeTrue
            $results.Check -contains 'Proxy' | Should -BeTrue
            $results.Check -contains 'WebMcp' | Should -BeTrue
        }

        It "does not check Bookkeeper by default" {
            $results = Test-HydrationReadiness
            $results.Check -contains 'Bookkeeper' | Should -BeFalse
        }
    }

    Context "Key resolution without AWS" -Tag "HydrationReadiness" {
        It "OPENCODE_GO1_KEY resolves from env var when set" {
            $env:OPENCODE_GO1_KEY = "test-key-1"
            $results = Test-HydrationReadiness -BundleTypes @('Coding')
            $check = $results | Where-Object { $_.Check -eq 'Coding:OPENCODE_GO1_KEY' }
            $check | Should -Not -BeNullOrEmpty
            $check.Passed | Should -BeTrue
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
        }

        It "OPENCODE_GO1_KEY fails when env var and AWS are both unavailable" {
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
            $results = Test-HydrationReadiness -BundleTypes @('Coding')
            $check = $results | Where-Object { $_.Check -eq 'Coding:OPENCODE_GO1_KEY' }
            $check | Should -Not -BeNullOrEmpty
            $check.Passed | Should -BeFalse
        }

        It "GATEWAY_TOKEN resolves from env var when set" {
            $env:INTERCLAW_GATEWAY_TOKEN = "test-gateway"
            $results = Test-HydrationReadiness -BundleTypes @('BASE')
            $check = $results | Where-Object { $_.Check -eq 'BASE:gateway_token' }
            $check | Should -Not -BeNullOrEmpty
            $check.Passed | Should -BeTrue
            $check.Detail | Should -Match 'env'
            Remove-Item Env:\INTERCLAW_GATEWAY_TOKEN -ErrorAction SilentlyContinue
        }

        It "IAM-generated agent keys are reported as provisioned" {
            $results = Test-HydrationReadiness -BundleTypes @('BASE')
            $idEntry = $results | Where-Object { $_.Check -eq 'BASE:aws_id' } | Select-Object -First 1
            $idEntry | Should -Not -BeNullOrEmpty
            $idEntry.Passed | Should -BeTrue
            $idEntry.Source | Should -Be 'provisioned'
        }
    }

    Context "Selective bundle check" -Tag "HydrationReadiness" {
        It "checks only specified bundle types" {
            $results = Test-HydrationReadiness -BundleTypes @('WebMcp')
            $results.Check -contains 'WebMcp' | Should -BeTrue
            $results.Check -contains 'BASE' | Should -BeFalse
            $results.Check -contains 'Coding' | Should -BeFalse
        }

        It "passes WebMcp required keys when env vars are set" {
            $env:TAVILY_API_KEY = "tv-key"
            $env:FIRECRAWL_API_KEY = "fc-key"
            $results = Test-HydrationReadiness -BundleTypes @('WebMcp')
            $tavilyCheck = $results | Where-Object { $_.Check -eq 'WebMcp:tavily_api_key' }
            $firecrawlCheck = $results | Where-Object { $_.Check -eq 'WebMcp:firecrawl_api_key' }
            $tavilyCheck | Should -Not -BeNullOrEmpty
            $tavilyCheck.Passed | Should -BeTrue
            $firecrawlCheck | Should -Not -BeNullOrEmpty
            $firecrawlCheck.Passed | Should -BeTrue
            Remove-Item Env:\TAVILY_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\FIRECRAWL_API_KEY -ErrorAction SilentlyContinue
        }
    }
}
