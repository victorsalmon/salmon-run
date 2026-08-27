#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $Script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $Script:BaseUrl = "http://localhost:21004"
    $Script:RunIntegration = $env:INTERCLAW_RUN_INTEGRATION_TESTS -eq "true"
}

Describe "AQE config files — no SSE MCP entry" -Tag "McpAqe" {
    It "config/opencode.json has no agentic-qe SSE entry" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/config/opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

    It "coding-opencode.json has no agentic-qe SSE entry" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/coding-opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

    It "controlling-opencode.json has no agentic-qe SSE entry" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/controlling-opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

    It "agenticqe-opencode.json has no agentic-qe SSE entry" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/agenticqe-opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

}

Describe "AQE server route ordering" -Tag "McpAqe" {
    It "/tools/reset_index handler is declared before /tools/:tool handler" {
        $source = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $resetIndexLine = [regex]::Match($source, "app\.post\('/tools/reset_index'").Index
        $genericToolLine = [regex]::Match($source, "app\.post\('/tools/:tool'").Index
        $resetIndexLine | Should -BeLessThan $genericToolLine -Because "reset_index must be registered before the generic :tool route"
    }

    It "/tools/register_domains handler is declared before /tools/:tool" {
        $source = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $registerLine = [regex]::Match($source, "app\.post\('/tools/register_domains'").Index
        $genericLine = [regex]::Match($source, "app\.post\('/tools/:tool'").Index
        $registerLine | Should -BeLessThan $genericLine
    }

    It "/tools/task_submit handler is declared before /tools/:tool" {
        $source = Get-Content (Join-Path $RepoRoot "Infrastructure/aqe-mcp-server.js") -Raw
        $submitLine = [regex]::Match($source, "app\.post\('/tools/task_submit'").Index
        $genericLine = [regex]::Match($source, "app\.post\('/tools/:tool'").Index
        $submitLine | Should -BeLessThan $genericLine
    }
}

Describe "AQE REST API contracts" -Tag "McpAqe", "Integration" {
    It "docs/Reference/API-Contracts.md AQE section has no active SSE endpoint" {
        $content = Get-Content (Join-Path $RepoRoot "docs/Reference/API-Contracts.md") -Raw
        $aqeSection = $content -replace '(?s).*## 13\. AQE Bridge', ''
        $aqeSection = $aqeSection -replace '(?s)---.*', ''
        $aqeSection | Should -Not -Match '### `(GET|POST) /mcp/'
    }

    It "docs/Reference/API-Contracts.md AQE section documents REST endpoints" {
        $content = Get-Content (Join-Path $RepoRoot "docs/Reference/API-Contracts.md") -Raw
        $content | Should -Match '/api/health'
        $content | Should -Match '/api/ready'
        $content | Should -Match '/api/routes'
        $content | Should -Match '/tools/reset_index'
        $content | Should -Match '/tools/:tool'
    }
}
