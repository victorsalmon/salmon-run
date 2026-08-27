#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Domain9 Invariant 7 — Secret Bundle Key Alignment" -Tag "Secrets", "Regression-Only" {
    BeforeAll {
        $manifestPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\manifests\docker-manifest.json"
        $bundleManifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\Private\bundle-manifest.ps1"
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        . $bundleManifestPath
        $bm = Get-BundleManifest
    }

    It "bundle-manifest.ps1 has comment explaining sentry deviation" {
        $bmContent = Get-Content -LiteralPath $bundleManifestPath -Raw
        $bmContent | Should -Match 'intentionally excluded from SourceKeys'
        $bmContent | Should -Match 'New-SentryIamUser'
    }

    It "docker-manifest.json has cross-reference note for sentry bundle" {
        $sentryEntry = $manifest.secrets | Where-Object { $_.swarmName -eq "sentry_secrets_bundle" }
        $sentryEntry | Should -Not -BeNullOrEmpty
        $sentryEntry.notes | Should -Match 'bundle-manifest'
    }

    It "all bundle types have matching keys between manifests (with sentry + proxy exceptions)" {
        $bundleMap = @{
            "proxy_secrets_bundle" = "Proxy"
            "bookkeeping_secrets_bundle" = "Bookkeeper"
            "coding_secrets_bundle" = "Coding"
            "web_mcp_secrets_bundle" = "WebMcp"
            "docusign_secrets_bundle" = "Docusign"
            "tailscale_secrets_bundle" = "Tailscale"
        }

        $mismatches = @()
        foreach ($entry in $manifest.secrets) {
            $bundleName = $entry.swarmName
            if (-not $bundleMap.ContainsKey($bundleName)) { continue }

            $bundleKey = $bundleMap[$bundleName]
            $manifestContains = @($entry.contains)

            $bundleType = $bm[$bundleKey]
            $bmKeys = @($bundleType.Required) + @($bundleType.Optional)

            $missingInManifest = $bmKeys | Where-Object { $_ -notin $manifestContains }
            $extraInManifest = $manifestContains | Where-Object { $_ -notin $bmKeys }

            # Known deviations:
            # - Proxy: proxy_aws_id/secret are IAM-generated (not in bundle-manifest Required/Optional)
            # - Proxy: openrouter_api_key vs OPENROUTER_ORCH_KEY naming mismatch
            if ($bundleKey -eq "Proxy") {
                $extraInManifest = $extraInManifest | Where-Object { $_ -notin @("proxy_aws_id", "proxy_aws_secret", "OPENROUTER_ORCH_KEY") }
                $missingInManifest = $missingInManifest | Where-Object { $_ -notin @("openrouter_api_key") }
            }

            if ($missingInManifest.Count -gt 0 -or $extraInManifest.Count -gt 0) {
                $mismatches += @{
                    Bundle = $bundleKey
                    SwarmName = $bundleName
                    MissingInManifest = $missingInManifest
                    ExtraInManifest = $extraInManifest
                }
            }
        }

        if ($mismatches.Count -gt 0) {
            foreach ($m in $mismatches) {
                Write-Host "Mismatch in $($m.Bundle) ($($m.SwarmName)):" -ForegroundColor Yellow
                if ($m.MissingInManifest.Count -gt 0) {
                    Write-Host "  Missing from docker-manifest: $($m.MissingInManifest -join ', ')" -ForegroundColor Red
                }
                if ($m.ExtraInManifest.Count -gt 0) {
                    Write-Host "  Extra in docker-manifest: $($m.ExtraInManifest -join ', ')" -ForegroundColor Red
                }
            }
        }

        $mismatches.Count | Should -Be 0
    }

    It "sentry deviation is documented in both manifests" {
        $bmContent = Get-Content -LiteralPath $bundleManifestPath -Raw
        $sentryEntry = $manifest.secrets | Where-Object { $_.swarmName -eq "sentry_secrets_bundle" }
        $sentryEntry.notes | Should -Match 'sentry_aws_id'
        $sentryEntry.notes | Should -Match 'sentry_aws_secret'
        $bmContent | Should -Match 'sentry_aws_id'
        $bmContent | Should -Match 'sentry_aws_secret'
    }
}
