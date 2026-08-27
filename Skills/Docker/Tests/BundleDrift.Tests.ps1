#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Bundle Drift Detection Tests
# Validates that every bundle type in the manifest is self-consistent and
# that Test-SecretBundleSchema correctly validates against manifest data.
# ==============================================================================

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")

    Mock Write-SetupLog { }
    Mock Write-Warning { }
    Mock Write-Verbose { }
}

Describe "BundleDrift" -Tag "BundleDrift", "Secrets" {

    # Sanity check: manifest loads and has expected structure
    It "manifest loads with all bundle types" {
        $m = Get-BundleManifest
        $m | Should -Not -BeNullOrEmpty
        $m.Agent.ORCH | Should -Not -BeNullOrEmpty
        $m.Agent.BASE | Should -Not -BeNullOrEmpty
        $m.Sentry | Should -Not -BeNullOrEmpty
        $m.Coding | Should -Not -BeNullOrEmpty
        $m.Proxy | Should -Not -BeNullOrEmpty
        $m.WebMcp | Should -Not -BeNullOrEmpty
        $m.Docusign | Should -Not -BeNullOrEmpty
        $m.Tailscale | Should -Not -BeNullOrEmpty
    }

    # Every agent role bundle must have the 3 required keys
    It "all agent roles require aws_id, aws_secret, gateway_token" {
        $m = Get-BundleManifest
        $core = @('aws_id', 'aws_secret', 'gateway_token')
        foreach ($role in @($m.Agent.BASE)) {
            foreach ($req in $core) {
                $req -in $role.Required | Should -BeTrue
            }
        }
    }

    # Sentry bundle has sentry_aws_id and sentry_aws_secret as optional
    It "Sentry bundle has sentry_aws_id and sentry_aws_secret as optional" {
        $m = Get-BundleManifest
        'sentry_aws_id' -in $m.Sentry.Optional | Should -BeTrue
        'sentry_aws_secret' -in $m.Sentry.Optional | Should -BeTrue
    }

    # Coding bundle requires OPENCODE_GO1_KEY
    It "Coding bundle requires OPENCODE_GO1_KEY" {
        $m = Get-BundleManifest
        'OPENCODE_GO1_KEY' -in $m.Coding.Required | Should -BeTrue
    }

    # Proxy bundle requires ATTIO write and archive keys
    It "Proxy bundle requires attio_write_key and attio_archive_key" {
        $m = Get-BundleManifest
        'attio_write_key' -in $m.Proxy.Required | Should -BeTrue
        'attio_archive_key' -in $m.Proxy.Required | Should -BeTrue
    }

    # Docusign bundle requires all 5 SMTP keys
    It "Docusign bundle requires all 5 SMTP keys" {
        $m = Get-BundleManifest
        'DOCUSIGN_SMTP_HOST' -in $m.Docusign.Required | Should -BeTrue
        'DOCUSIGN_SMTP_PORT' -in $m.Docusign.Required | Should -BeTrue
        'DOCUSIGN_SMTP_USER' -in $m.Docusign.Required | Should -BeTrue
        'DOCUSIGN_SMTP_PASS' -in $m.Docusign.Required | Should -BeTrue
        'DOCUSIGN_SMTP_FROM' -in $m.Docusign.Required | Should -BeTrue
    }

    # Tailscale bundle requires TAILSCALE_KEY
    It "Tailscale bundle requires TAILSCALE_KEY" {
        $m = Get-BundleManifest
        'TAILSCALE_KEY' -in $m.Tailscale.Required | Should -BeTrue
    }

    # Docusign SourceKeys match Required + Optional
    It "Docusign SourceKeys match required + optional keys" {
        $m = Get-BundleManifest
        $expected = ($m.Docusign.Required + $m.Docusign.Optional) | Sort-Object
        $m.Docusign.SourceKeys | Sort-Object | Should -Be $expected
    }

    # Tailscale SourceKeys match Required
    It "Tailscale SourceKeys match required keys" {
        $m = Get-BundleManifest
        $m.Tailscale.SourceKeys | Sort-Object | Should -Be ($m.Tailscale.Required | Sort-Object)
    }

    # Web MCP bundle has tavily_api_key and firecrawl_api_key as optional
    # (promoted to required via install.json feature secrets when web-mcp is installed)
    It "Web MCP bundle has tavily_api_key and firecrawl_api_key as optional" {
        $m = Get-BundleManifest
        'tavily_api_key' -in $m.WebMcp.Optional | Should -BeTrue
        'firecrawl_api_key' -in $m.WebMcp.Optional | Should -BeTrue
    }
    It "Get-ManifestSchemaForBundle returns a schema for WebMcp bundle" {
        $schema = Get-ManifestSchemaForBundle -BundleName "web_mcp_secrets_bundle"
        $schema | Should -Not -BeNullOrEmpty
        $schema.Keys -contains 'Required' | Should -BeTrue
        $schema.Keys -contains 'Optional' | Should -BeTrue
    }

    # Agent bundle schemas must be role-scoped, not a union of all roles
    It "ORCH schema includes telegram keys as optional" {
        $schema = Get-ManifestSchemaForBundle -BundleName "FRAD_ORCH_secrets_bundle"
        'telegram_bot_token_orch' -in $schema.Optional | Should -BeTrue
        'telegram_owner_username' -in $schema.Optional | Should -BeTrue
        'telegram_owner_userid' -in $schema.Optional | Should -BeTrue
    }

    It "BASE schema excludes ORCH-specific keys" {
        $schema = Get-ManifestSchemaForBundle -BundleName "FRAD_BASE_secrets_bundle"
        $orchOnly = @('telegram_bot_token_orch', 'telegram_owner_username', 'telegram_owner_userid',
                      'gcp_maestro_id', 'gcp_maestro_clientid', 'gcp_maestro_secret')
        foreach ($key in $orchOnly) {
            $key -in $schema.Required | Should -BeFalse -Because "$key should not be Required for BASE"
            $key -in $schema.Optional | Should -BeFalse -Because "$key should not be Optional for BASE"
        }
    }

    It "instance-suffixed bundle name resolves to same role schema" {
        $schema = Get-ManifestSchemaForBundle -BundleName "FRAD_BASE-1_secrets_bundle"
        $schema | Should -Not -BeNullOrEmpty
        'aws_id' -in $schema.Required | Should -BeTrue
        'openrouter_base_key' -in $schema.Required | Should -BeTrue
        $schema.Optional.Count | Should -Be 0
    }

    It "unknown role falls back to union schema" {
        $schema = Get-ManifestSchemaForBundle -BundleName "FRAD_UNKNOWN_secrets_bundle"
        $schema | Should -Not -BeNullOrEmpty
        'aws_id' -in $schema.Required | Should -BeTrue
        'gateway_token' -in $schema.Required | Should -BeTrue
    }

    # No duplicate keys across required+optional within a bundle
    It "no bundle has duplicate keys in required and optional" {
        $m = Get-BundleManifest
        $bundles = @($m.Agent.BASE, $m.Sentry, $m.Coding, $m.Proxy, $m.WebMcp, $m.Docusign, $m.Tailscale)
        foreach ($b in $bundles) {
            $dupes = $b.Required | Where-Object { $_ -in $b.Optional }
            $dupes.Count | Should -Be 0 -Because "bundle has key in both Required and Optional: $($dupes -join ', ')"
        }
    }

    # Test-SecretBundleSchema passes for entries that match manifest
    It "Test-SecretBundleSchema accepts entries matching all required+optional" {
        $m = Get-BundleManifest
        $entries = @{}
        foreach ($r in $m.Coding.Required) { $entries[$r] = "val" }
        foreach ($o in $m.Coding.Optional) { $entries[$o] = "val" }
        $result = Test-SecretBundleSchema -BundleName "coding_secrets_bundle" -Entries $entries
        $result.Valid | Should -BeTrue
    }

    # Test-SecretBundleSchema fails for entries missing required keys
    It "Test-SecretBundleSchema rejects entries missing required keys" {
        $result = Test-SecretBundleSchema -BundleName "coding_secrets_bundle" -Entries @{}
        $result.Valid | Should -BeFalse
        $result.Missing.Count | Should -BeGreaterThan 0
    }

    # EnvMap keys must be a subset of required+optional (no orphan env entries)
    It "all EnvMap keys exist in required or optional for each bundle" {
        $m = Get-BundleManifest
        $bundles = @($m.Agent.BASE, $m.Sentry)
        foreach ($b in $bundles) {
            $validKeys = $b.Required + $b.Optional
            foreach ($k in $b.EnvMap.Keys) {
                $k -in $validKeys | Should -BeTrue -Because "EnvMap key '$k' not in Required or Optional"
            }
        }
    }

    # SourceKeys exist and are non-empty for bundles that hydrate from AWS SM
    It "source keys are populated for SM-sourced bundles" {
        $m = Get-BundleManifest
        $m.Coding.SourceKeys.Count | Should -BeGreaterThan 0
        $m.Proxy.SourceKeys.Count | Should -BeGreaterThan 0
        $m.WebMcp.SourceKeys.Count | Should -BeGreaterThan 0
        $m.Docusign.SourceKeys.Count | Should -BeGreaterThan 0
        $m.Tailscale.SourceKeys.Count | Should -BeGreaterThan 0
    }
}
