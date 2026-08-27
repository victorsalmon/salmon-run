#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Fleet CORS allowlist convention" -Tag "Security", "Regression" {
    BeforeAll {
        $script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    }

    It "aqe-mcp-server.js does not set Access-Control-Allow-Origin wildcard" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $content | Should -Not -Match "Access-Control-Allow-Origin', '\*'"
    }

    It "aqe-mcp-server.js reads CORS_ORIGIN as an allowlist" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $content | Should -Match "CORS_ORIGIN"
        $content | Should -Match "CORS_ORIGINS\.includes"
    }

    It "aqe-mcp-server.js echoes the origin only for allowlisted requests" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $content | Should -Match "reqOrigin && CORS_ORIGINS\.includes\(reqOrigin\)"
        $content | Should -Match "Access-Control-Allow-Origin', reqOrigin"
    }

    It "aqe-mcp-server.js keeps OPTIONS preflight handling" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $content | Should -Match "req\.method === 'OPTIONS'"
    }

    It "marketer/server.js does not set Access-Control-Allow-Origin wildcard" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/marketer/server.js") -Raw
        $content | Should -Not -Match "Access-Control-Allow-Origin', '\*'"
    }

    It "marketer/server.js reads MARKETER_CORS_ORIGINS as an allowlist" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/marketer/server.js") -Raw
        $content | Should -Match "MARKETER_CORS_ORIGINS"
        $content | Should -Match "allowedOrigins\.includes\(reqOrigin\)"
    }

    It "marketer/server.js echoes the origin only for allowlisted requests" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/marketer/server.js") -Raw
        $content | Should -Match "Access-Control-Allow-Origin', reqOrigin"
    }

    It "marketer/server.js preserves nosniff and frame headers" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/marketer/server.js") -Raw
        $content | Should -Match "X-Content-Type-Options', 'nosniff'"
        $content | Should -Match "X-Frame-Options', 'DENY'"
    }

    It "fleet-auth-flow.md documents the CORS allowlist convention" {
        $content = Get-Content (Join-Path $RepoRoot "Skills/Auth/fleet-auth-flow.md") -Raw
        $content | Should -Match "Access-Control-Allow-Origin.*is prohibited"
        $content | Should -Match "CORS_ORIGIN"
        $content | Should -Match "MARKETER_CORS_ORIGINS"
    }
}
