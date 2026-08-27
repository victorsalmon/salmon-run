#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Orchestrator' 'Modules'

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    Remove-Module 'SalmonRun.PondEngine', 'SalmonRun.Paths', 'SalmonRun.Constants', 'SalmonRun.Core', 'SalmonRun.AgentLifecycle' -Force -ErrorAction SilentlyContinue

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop

    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = Join-Path $TestDrive 'salmon-home'
    $null = New-Item -ItemType Directory -Path $env:SALMON_RUN_HOME -Force
}

AfterAll {
    $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome
}

Describe 'Model router cost fields' -Tag 'PondEngine', 'Regression-Only' {
    It 'exposes costRule, apiCost and effectiveCost on the execution profile' {
        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }

        $profile.CostRule | Should -Not -BeNullOrEmpty
        $profile.ApiCostPer1KTokens | Should -Not -Be $null
        $profile.EffectiveCostPer1KTokens | Should -Not -Be $null
        $profile.EffectiveCostPer1KTokens | Should -BeLessOrEqual $profile.ApiCostPer1KTokens
    }

    It 'carries free cost for Local and Flash tiers' {
        $local = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Local' }
        $flash = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Flash' }

        $local.CostRule | Should -Be 'free'
        $local.ApiCostPer1KTokens | Should -Be 0.0
        $local.EffectiveCostPer1KTokens | Should -Be 0.0

        $flash.CostRule | Should -Be 'free'
        $flash.ApiCostPer1KTokens | Should -Be 0.0
        $flash.EffectiveCostPer1KTokens | Should -Be 0.0
    }

    It 'carries discounted cost for OpenCode Go Daily models' {
        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }

        $profile.Provider | Should -Be 'opencode-go'
        $profile.CostRule | Should -Be 'one-sixth'
        $profile.ApiCostPer1KTokens | Should -BeGreaterThan 0
        $profile.EffectiveCostPer1KTokens | Should -BeGreaterThan 0
        $profile.EffectiveCostPer1KTokens * 6 | Should -BeLessOrEqual ($profile.ApiCostPer1KTokens + 0.01)
    }

    It 'carries normal cost for DSH Frontier models' {
        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }

        $profile.Provider | Should -Be 'dsh'
        $profile.CostRule | Should -Be 'normal'
        $profile.ApiCostPer1KTokens | Should -BeGreaterThan 0
        $profile.EffectiveCostPer1KTokens | Should -Be ($profile.ApiCostPer1KTokens)
    }
}

Describe 'Provider overlay from ~/.salmon/providers' -Tag 'PondEngine', 'Regression-Only' {
    BeforeEach {
        $providersDir = Join-Path $env:SALMON_RUN_HOME 'providers'
        if (Test-Path -LiteralPath $providersDir) {
            Remove-Item -LiteralPath $providersDir -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $providersDir -Force
    }

    It 'routes Complex to an overlay OpenRouter model' {
        $overlay = @{
            harnesses = @{
                openrouter = @{
                    description = 'OpenRouter overlay'
                    defaultProvider = 'openrouter'
                }
            }
            providers = @{
                openrouter = @{
                    cli = 'openrouter'
                    defaultModel = 'openrouter/stealth/ox-alpha'
                    defaultEffort = 'max'
                    acceptedEfforts = @('max', 'default')
                    executorFile = 'OpenRouter'
                    credentials = @('OPENROUTER_API_KEY')
                    models = @{
                        'openrouter/stealth/ox-alpha' = @{ defaultEffort = 'max' }
                    }
                }
            }
            models = @(
                @{
                    canonicalName = 'OpenRouter/Stealth-Ox-Alpha'
                    harness = 'openrouter'
                    provider = 'openrouter'
                    model = 'openrouter/stealth/ox-alpha'
                    effort = 'max'
                    tier = 'Complex'
                    costRule = 'normal'
                    apiCostPer1KTokens = 0.45
                    effectiveCostPer1KTokens = 0.45
                    capabilityScore = 86
                    benchmarks = @{
                        sweBench = 81.0
                        aime2024 = 86.0
                        terminalBench21 = 83.0
                        mmlu = 89.0
                    }
                    cacheContract = 'none'
                    notes = 'OpenRouter overlay test model'
                }
            )
        }
        $overlay | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'openrouter.json') -Encoding utf8

        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Complex' }

        $profile.Harness | Should -Be 'openrouter'
        $profile.Provider | Should -Be 'openrouter'
        $profile.Model | Should -Be 'openrouter/stealth/ox-alpha'
        $profile.Cli | Should -Be 'openrouter'
        $profile.ExecutorFile | Should -Be 'OpenRouter'
        $profile.Credentials | Should -Contain 'OPENROUTER_API_KEY'
        $profile.CostRule | Should -Be 'normal'
        $profile.ApiCostPer1KTokens | Should -Be 0.45
        $profile.EffectiveCostPer1KTokens | Should -Be 0.45
    }

    It 'routes Frontier to an overlay DeepInfra/Codex model' {
        $overlay = @{
            models = @(
                @{
                    canonicalName = 'DeepInfra/DeepSeek-V4-Flash'
                    harness = 'codex'
                    provider = 'deepinfra'
                    model = 'deepseek-ai/DeepSeek-V4-Flash-0731'
                    effort = 'medium'
                    tier = 'Frontier'
                    costRule = 'normal'
                    apiCostPer1KTokens = 0.80
                    effectiveCostPer1KTokens = 0.80
                    capabilityScore = 96
                    benchmarks = @{
                        sweBench = 89.0
                        aime2024 = 96.0
                        terminalBench21 = 88.0
                        mmlu = 93.0
                    }
                    cacheContract = 'none'
                    notes = 'DeepInfra overlay test model'
                }
            )
        }
        $overlay | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'deepinfra.json') -Encoding utf8

        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }

        $profile.Harness | Should -Be 'codex'
        $profile.Provider | Should -Be 'deepinfra'
        $profile.Model | Should -Be 'deepseek-ai/DeepSeek-V4-Flash-0731'
        $profile.Cli | Should -Be 'codex'
        $profile.ExecutorFile | Should -Be 'DeepInfra'
        $profile.Credentials | Should -Contain 'OPENAI_API_KEY'
        $profile.CostRule | Should -Be 'normal'
        $profile.ApiCostPer1KTokens | Should -Be 0.80
        $profile.EffectiveCostPer1KTokens | Should -Be 0.80
    }

    It 'merges multiple provider overlay files cleanly' {
        @{ models = @(@{
            canonicalName = 'OpenRouter/Stealth-Ox-Alpha'
            harness = 'openrouter'
            provider = 'openrouter'
            model = 'openrouter/stealth/ox-alpha'
            effort = 'max'
            tier = 'Complex'
            costRule = 'normal'
            apiCostPer1KTokens = 0.45
            effectiveCostPer1KTokens = 0.45
            capabilityScore = 86
            benchmarks = @{ sweBench = 81.0; aime2024 = 86.0; terminalBench21 = 83.0; mmlu = 89.0 }
            cacheContract = 'none'
        }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'openrouter.json') -Encoding utf8

        @{ models = @(@{
            canonicalName = 'DeepInfra/DeepSeek-V4-Flash'
            harness = 'codex'
            provider = 'deepinfra'
            model = 'deepseek-ai/DeepSeek-V4-Flash-0731'
            effort = 'medium'
            tier = 'Frontier'
            costRule = 'normal'
            apiCostPer1KTokens = 0.80
            effectiveCostPer1KTokens = 0.80
            capabilityScore = 96
            benchmarks = @{ sweBench = 89.0; aime2024 = 96.0; terminalBench21 = 88.0; mmlu = 93.0 }
            cacheContract = 'none'
        }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'deepinfra.json') -Encoding utf8

        $complex = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Complex' }
        $frontier = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }

        $complex.Provider | Should -Be 'openrouter'
        $frontier.Provider | Should -Be 'deepinfra'
    }
}
