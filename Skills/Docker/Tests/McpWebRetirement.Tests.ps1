#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "mcp_web container retirement" -Tag "Regression", "Retirement" {
    BeforeAll {
        $Script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    }

    Context "install.json — web-mcp feature disabled and deprecated" {
        It "web-mcp install is false" {
            $installJson = Get-Content (Join-Path $RepoRoot "install.json") -Raw | ConvertFrom-Json
            $installJson.features.'web-mcp'.install | Should -Be $false
        }

        It "web-mcp is in deprecated_services" {
            $installJson = Get-Content (Join-Path $RepoRoot "install.json") -Raw | ConvertFrom-Json
            $deprecated = $installJson.deprecated_services | Where-Object { $_.name -eq 'web-mcp' }
            $deprecated | Should -Not -BeNullOrEmpty
            $deprecated.reason | Should -Match "web-research"
        }
    }

    Context "opencode.json — no mcp_web SSE entries" {
        It "config/opencode.json has no mcp_web entry" {
            $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/config/opencode.json") -Raw
            $content | Should -Not -Match '"mcp_web"'
        }

        It "coding-opencode.json has no mcp_web entry" {
            $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/coding-opencode.json") -Raw
            $content | Should -Not -Match '"mcp_web"'
        }

        It "controlling-opencode.json has no mcp_web entry" {
            $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/controlling-opencode.json") -Raw
            $content | Should -Not -Match '"mcp_web"'
        }

        It "agenticqe-opencode.json has no mcp_web entry" {
            $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/agenticqe-opencode.json") -Raw
            $content | Should -Not -Match '"mcp_web"'
        }
    }

    Context "bundle-manifest.ps1 — no active mcp_web fleet tokens" {
        It "FleetApiTokens ServiceTokens does not contain mcp_web" {
            . (Join-Path $RepoRoot "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1")
            $manifest = Get-BundleManifest
            $manifest.FleetApiTokens.ServiceTokens.Keys | Should -Not -Contain 'mcp_web'
        }

        It "FleetApiTokens MonitorTokens does not contain mcp_web" {
            . (Join-Path $RepoRoot "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1")
            $manifest = Get-BundleManifest
            $manifest.FleetApiTokens.MonitorTokens.Keys | Should -Not -Contain 'mcp_web'
        }
    }

    Context "port-registry.json — port 21005 retired" {
        It "port 21005 is in retired section" {
            $portRegistry = Get-Content (Join-Path $RepoRoot "Infrastructure/port-registry.json") -Raw | ConvertFrom-Json
            $portRegistry.retired.'21005' | Should -Not -BeNullOrEmpty
            $portRegistry.retired.'21005'.reason | Should -Match "mcp_web"
        }

        It "port 21005 is not in internal section" {
            $portRegistry = Get-Content (Join-Path $RepoRoot "Infrastructure/port-registry.json") -Raw | ConvertFrom-Json
            $portRegistry.internal.PSObject.Properties.Name | Should -Not -Contain 'mcp_web'
        }
    }

    Context "Infrastructure files — source files deleted" {
        It "mcp_web.Dockerfile does not exist" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/mcp_web.Dockerfile") | Should -Be $false
        }

        It "web-mcp-server.js does not exist" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/web-mcp-server.js") | Should -Be $false
        }

        It "entrypoint-web-mcp.sh does not exist" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/entrypoint-web-mcp.sh") | Should -Be $false
        }
    }
}
