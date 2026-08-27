#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Source: mcp_opencode AQE (Infrastructure/mcp_opencode)
# ==============================================================================

BeforeAll {
    $ImageName = "code-worker:local"
    $RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
}

Describe "AQE MCP Server in CODE container" -Tag "CODE", "Regression-Only" {
    It "should have mcp_aqe binary installed" -Skip:(-not $env:INTERCLAW_RUN_INTEGRATION_TESTS) {
        $result = docker run --rm --entrypoint /bin/sh $ImageName -c "which mcp_aqe" 2>&1
        $LASTEXITCODE | Should -Be 0
        $result | Should -Not -BeNullOrEmpty
    }

    It "should have aqe CLI installed" -Skip:(-not $env:INTERCLAW_RUN_INTEGRATION_TESTS) {
        $result = docker run --rm --entrypoint /bin/sh $ImageName -c "aqe --version" 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    It "should load agenticqe-opencode.json" -Skip:(-not $env:INTERCLAW_RUN_INTEGRATION_TESTS) {
        $result = docker run --rm -e CODE_ROLE=agenticqe --entrypoint /bin/sh $ImageName -c "cat /opencode-config/agenticqe-opencode.json" 2>&1
        $LASTEXITCODE | Should -Be 0
        $output = ($result | Out-String)
        $output | Should -Match '"mcp"'
    }

    It "coding-opencode.json no longer includes AQE SSE MCP config" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/coding-opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

    It "controlling-opencode.json no longer includes AQE SSE MCP config" {
        $content = Get-Content (Join-Path $RepoRoot "Infrastructure/opencode/controlling-opencode.json") -Raw
        $content | Should -Not -Match '"agentic-qe"'
    }

    It "AQE configs have no MCP SSE URL pointing to mcp_aqe" {
        $files = @(
            Join-Path $RepoRoot "Infrastructure/opencode/coding-opencode.json"
            Join-Path $RepoRoot "Infrastructure/opencode/controlling-opencode.json"
            Join-Path $RepoRoot "Infrastructure/opencode/agenticqe-opencode.json"
        )
        foreach ($f in $files) {
            if (Test-Path $f) {
                $content = Get-Content $f -Raw
                $content | Should -Not -Match '"agentic-qe"'
            }
        }
    }

    It "All CODE_ROLE config files exist" {
        'coding-opencode.json', 'controlling-opencode.json', 'agenticqe-opencode.json' | ForEach-Object {
            Join-Path $RepoRoot "Infrastructure/opencode/$_" | Should -Exist
        }
    }

    It "CODE_ROLE maps to existing config file" {
        $configDir = Join-Path $RepoRoot "Infrastructure/opencode"
        $roleMap = @{
            "coding"              = "coding-opencode.json"
            "controlling"         = "controlling-opencode.json"
            "agenticqe"           = "agenticqe-opencode.json"
        }
        foreach ($entry in $roleMap.GetEnumerator()) {
            $configPath = Join-Path $configDir $entry.Value
            Test-Path $configPath | Should -Be $true -Because "'$($entry.Key)' role should have config '$($entry.Value)'"
        }
    }
}
