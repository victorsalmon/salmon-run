#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:ProxyDir = Join-Path -Path $script:RepoRoot -ChildPath 'Infrastructure' -AdditionalChildPath 'mcp-proxy'

    # Check Node.js availability (test may be skipped if not available)
    $script:HasNode = $false
    try {
        $nodeVersion = node --version 2>$null
        $script:HasNode = $nodeVersion -match '^v'
    } catch {}
}

Describe "MCP Proxy — package.json" -Tag "MCP", "Unit" {
    It "package.json exists" {
        $pkgPath = Join-Path $script:ProxyDir "package.json"
        Test-Path $pkgPath | Should -Be $true
    }

    It "has required dependencies" {
        $pkg = Get-Content (Join-Path $script:ProxyDir "package.json") -Raw | ConvertFrom-Json
        $pkg.dependencies.express | Should -Not -BeNullOrEmpty
        $pkg.dependencies.'@modelcontextprotocol/sdk' | Should -Not -BeNullOrEmpty
    }
}

Describe "MCP Proxy — server.js" -Tag "MCP", "Unit" {
    It "server.js exists" {
        $serverPath = Join-Path $script:ProxyDir "server.js"
        Test-Path $serverPath | Should -Be $true
    }

    It "imports required modules" {
        $content = Get-Content (Join-Path $script:ProxyDir "server.js") -Raw
        $content | Should -Match "require\('express'\)"
        $content | Should -Match "@modelcontextprotocol/sdk"
        $content | Should -Match "SSEServerTransport"
    }

    It "exports standard API endpoints" {
        $content = Get-Content (Join-Path $script:ProxyDir "server.js") -Raw
        $content | Should -Match "/api/health"
        $content | Should -Match "/api/routes"
        $content | Should -Match "/api/version"
    }

    It "exports MCP SSE endpoints" {
        $content = Get-Content (Join-Path $script:ProxyDir "server.js") -Raw
        $content | Should -Match "/mcp/sse"
        $content | Should -Match "/mcp/message"
    }

    It "reads fleet token from secrets" {
        $content = Get-Content (Join-Path $script:ProxyDir "server.js") -Raw
        $content | Should -Match "fleet_api_token"
    }

    It "discovers tools via /tools/list" {
        $content = Get-Content (Join-Path $script:ProxyDir "server.js") -Raw
        $content | Should -Match "tools/list"
    }
}

Describe "opencode.json — MCP server registration" -Tag "MCP", "Config", "Unit" {
    It "registers is_fleet" {
        $cfg = Get-Content (Join-Path $script:RepoRoot "Infrastructure" "opencode" "config" "opencode.json") -Raw | ConvertFrom-Json
        $cfg.mcp.is_fleet.enabled | Should -Be "true"
    }

    It "has correct SSE URLs" {
        $cfg = Get-Content (Join-Path $script:RepoRoot "Infrastructure" "opencode" "config" "opencode.json") -Raw | ConvertFrom-Json
        $cfg.mcp.is_fleet.url | Should -Be "http://is-fleet:21014/mcp/sse"
    }
}

Describe "entrypoint.sh — auth token injection" -Tag "MCP", "Config", "Unit" {
    It "injects tokens for new MCP servers" {
        $content = Get-Content (Join-Path $script:RepoRoot "Infrastructure" "opencode" "entrypoint.sh") -Raw
        $content | Should -Match "FLEET_API_TOKEN_MONITORING"
        $content | Should -Match "FLEET_API_TOKEN_MONITOR"
    }
}
