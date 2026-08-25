#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $script:OCTwoAgentPath = Join-Path $script:RepoRoot "Skills\\Workflows\Shared\opencode-two-agent.md"
    $script:CodingConfigPath = Join-Path $script:RepoRoot "Infrastructure\opencode\coding-opencode.json"
    $script:ControllingConfigPath = Join-Path $script:RepoRoot "Infrastructure\opencode\controlling-opencode.json"

}

Describe "Two-Agent Protocol Document" -Tag "TwoAgent", "Regression-Only" {
    It "opencode-two-agent.md exists" {
        $script:OCTwoAgentPath | Should -Exist
    }

    It "contains Architecture section" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Architecture'
    }

    It "contains Role Definitions" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Coder'
        $content | Should -Match 'Reviewer'
        $content | Should -Match 'Agentic QE'
    }

    It "contains all 5 phases" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Phase 1.*Planning'
        $content | Should -Match 'Phase 2.*Implementation'
        $content | Should -Match 'Quality Validation.*(Coder-Side|BASE-owned)'
        $content | Should -Match 'Phase 3.*Code Review'
        $content | Should -Match 'Phase 4.*Final Review'
    }

    It "contains 3-strike failure mechanism" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match '3.(consecutive|strike)'
    }

    It "contains Complete CC (Coding Agent)" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Complete CC \(Coding Agent\)'
        $content | Should -Match 'workflow-primitives\.md#complete-cc-shared-snippets'
    }

    It "contains quality validation step" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Quality Validation'
        $content | Should -Match 'PACT scorecard'
    }

    It "contains Task Folder Structure" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Tasks/Review/'
        $content | Should -Match 'Tasks/Complete/'
        $content | Should -Match 'Tasks/Manual/'
    }

    It "contains dispatch signal cross-reference" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Manual Dispatch'
        $content | Should -Match 'workflow-primitives\.md#manual-dispatch-signals-legacy-flow'
    }

    It "contains Lock Header cross-reference" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Lock Header'
        $content | Should -Match 'workflow-primitives\.md#lock-header-chain-of-possession'
    }

    It "contains server-mode and legacy dispatch rules" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'handle file movement themselves'
        $content | Should -Match 'HTTP API directly'
    }

    It "contains BASE git conflict prevention" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Git Conflict Prevention'
        $content | Should -Match 'branch-per-task'
    }

    It "contains 3-strike failure mechanism (progress tracking)" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match '3.(consecutive|strike)'
    }

    It "contains session plan format template" {
        $content = Get-Content $script:OCTwoAgentPath -Raw
        $content | Should -Match 'Session Plan Format'
        $content | Should -Match 'Acceptance'
    }
}

Describe "Role Config Templates" -Tag "TwoAgent", "Regression-Only" {
    It "coding-opencode.json exists" {
        $script:CodingConfigPath | Should -Exist
    }

    It "coding-opencode.json is valid JSON" {
        { Get-Content $script:CodingConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "coding-opencode.json uses V4 Flash with max effort" {
        $config = Get-Content $script:CodingConfigPath -Raw | ConvertFrom-Json
        $config.model | Should -Match 'deepseek-v4-flash'
        $config.reasoning.effort | Should -Be 'max'
    }

    It "coding-opencode.json has all permissions allow" {
        $config = Get-Content $script:CodingConfigPath -Raw | ConvertFrom-Json
        $config.permissions.bash | Should -Be 'allow'
        $config.permissions.write | Should -Be 'allow'
        $config.permissions.edit | Should -Be 'allow'
    }

    It "controlling-opencode.json exists" {
        $script:ControllingConfigPath | Should -Exist
    }

    It "controlling-opencode.json is valid JSON" {
        { Get-Content $script:ControllingConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "controlling-opencode.json uses V4 Pro with high effort" {
        $config = Get-Content $script:ControllingConfigPath -Raw | ConvertFrom-Json
        $config.model | Should -Match 'deepseek-v4-pro'
        $config.reasoning.effort | Should -Be 'high'
    }

    It "both configs use OpenRouter provider" {
        $coding = Get-Content $script:CodingConfigPath -Raw | ConvertFrom-Json
        $controlling = Get-Content $script:ControllingConfigPath -Raw | ConvertFrom-Json
        $coding.provider | Should -Be 'openrouter'
        $controlling.provider | Should -Be 'openrouter'
    }

    It "both configs have snapshot enabled" {
        $coding = Get-Content $script:CodingConfigPath -Raw | ConvertFrom-Json
        $controlling = Get-Content $script:ControllingConfigPath -Raw | ConvertFrom-Json
        $coding.snapshot | Should -BeTrue
        $controlling.snapshot | Should -BeTrue
    }
}

Describe "BASE Agent File Consistency" -Tag "TwoAgent", "Regression-Only" {
# ==============================================================================
# Source: Two-Agent workflow (Skills/Workflows/Shared/opencode-two-agent.md)
# ==============================================================================

BeforeAll {
        $script:BaseDir = Join-Path $script:RepoRoot "Skills\ORCHESTRATOR\Personas\BASE"
    }

    It "soul.md no longer references Three Passes" {
        $content = Get-Content (Join-Path $script:BaseDir "soul.md") -Raw
        $content | Should -Not -Match 'Three Passes'
    }

    It "soul.md no longer references No Greenfield Execution" {
        $content = Get-Content (Join-Path $script:BaseDir "soul.md") -Raw
        $content | Should -Not -Match 'No Greenfield Execution'
    }

    It "soul.md no longer references Sub-Orchestrator" {
        $content = Get-Content (Join-Path $script:BaseDir "soul.md") -Raw
        $content | Should -Not -Match 'Sub-Orchestrator'
    }

    It "soul.md no longer references Two-Agent workflow" {
        $content = Get-Content (Join-Path $script:BaseDir "soul.md") -Raw
        $content | Should -Not -Match 'Two-Agent'
    }

    It "tools.md no longer references Two-Agent dispatching" {
        $content = Get-Content (Join-Path $script:BaseDir "tools.md") -Raw
        $content | Should -Not -Match 'Two-Agent Dispatching'
    }

    It "tools.md no longer references git conflict prevention" {
        $content = Get-Content (Join-Path $script:BaseDir "tools.md") -Raw
        $content | Should -Not -Match 'Git Conflict Prevention'
    }

    It "agents.md Fleet Topology includes Controlling Agent (mcp_opencode)" {
        $content = Get-Content (Join-Path $script:BaseDir "agents.md") -Raw
        $content | Should -Match 'mcp_opencode'
    }

    It "agents.md Fleet Topology includes Coding Agent (mcp_opencode)" {
        $content = Get-Content (Join-Path $script:BaseDir "agents.md") -Raw
        $content | Should -Match 'mcp_opencode'
    }

    It "agents.md no longer references Planned Pass Protocol" {
        $content = Get-Content (Join-Path $script:BaseDir "agents.md") -Raw
        $content | Should -Not -Match 'Planned Pass Protocol'
    }

    It "system-prompt.md no longer references Sub-Orchestrator" {
        $content = Get-Content (Join-Path $script:BaseDir "system-prompt.md") -Raw
        $content | Should -Not -Match 'Sub-Orchestrator'
    }

    It "system-prompt.md no longer references Two-Agent workflow" {
        $content = Get-Content (Join-Path $script:BaseDir "system-prompt.md") -Raw
        $content | Should -Not -Match 'Two-Agent'
    }

    It "system-prompt.md no longer references Three Passes" {
        $content = Get-Content (Join-Path $script:BaseDir "system-prompt.md") -Raw
        $content | Should -Not -Match 'Three Passes'
    }
}

Describe "AgenticQE MCP Tools" -Tag "TwoAgent", "Regression-Only" {
    It "BASE tools.md no longer references AQE MCP tools" {
        $content = Get-Content (Join-Path $script:RepoRoot "Skills\ORCHESTRATOR\Personas\BASE\tools.md") -Raw
        $content | Should -Not -Match 'mcp__agentic-qe__'
    }

    It "AGENTS.md references AgenticQE in fleet" {
        $content = Get-Content (Join-Path $script:RepoRoot "AGENTS.md") -Raw
        $content | Should -Match 'AgenticQE'
    }
}

Describe "Shared File Consistency" -Tag "TwoAgent", "Regression-Only" {
    It "code-acp.md does not exist at BASE path (retired concept)" {
        $path = Join-Path $script:RepoRoot "Skills\ORCHESTRATOR\Personas\BASE\opencode-acp.md"
        Test-Path $path | Should -Be $false
    }

    It "AGENTS.md contains Post hoc / Verify plan section" {
        $content = Get-Content (Join-Path $script:RepoRoot "AGENTS.md") -Raw
        $content | Should -Match 'Post hoc.*Verify plan'
        $content | Should -Match 'Ad-hoc.*no plan'
    }

    It "AGENTS.md specifies V4 Flash session sizing" {
        $content = Get-Content (Join-Path $script:RepoRoot "AGENTS.md") -Raw
        $content | Should -Match '2-5 tasks'
    }

    It "AGENTS.md has terminology note" {
        $content = Get-Content (Join-Path $script:RepoRoot "AGENTS.md") -Raw
        $content | Should -Match 'Lock Header'
    }

    It "AGENTS.md references workflow-primitives.md for Coder and Reviewer" {
        $content = Get-Content (Join-Path $script:RepoRoot "AGENTS.md") -Raw
        $content | Should -Match 'Skills/Workflows/Shared/workflow-primitives.md'
        $content | Should -Match 'Skills/Workflows/Review/workflow.md'
    }
}
