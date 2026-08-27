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

Describe 'Benchmark data from ~/.salmon/benchmarks' -Tag 'PondEngine', 'Regression-Only' {
    BeforeEach {
        $benchmarksDir = Join-Path $env:SALMON_RUN_HOME 'benchmarks'
        if (Test-Path -LiteralPath $benchmarksDir) {
            Remove-Item -LiteralPath $benchmarksDir -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $benchmarksDir -Force

        # No provider overlays for these tests unless a case adds them.
        $providersDir = Join-Path $env:SALMON_RUN_HOME 'providers'
        if (Test-Path -LiteralPath $providersDir) {
            Remove-Item -LiteralPath $providersDir -Recurse -Force
        }
    }

    It 'loads benchmark data from models.json' {
        $bench = @{
            last_updated = '2026-08-26'
            sources = @{
                swebench = @{
                    name = 'SWE-bench Pro'
                    url = 'https://www.swebench.com/'
                    type = 'leaderboard'
                }
            }
            models = @{
                'deepseek-v4-pro' = @{
                    name = 'DeepSeek V4 Pro'
                    family = 'deepseek'
                    providers = @{
                        dsh = @{
                            model_id = 'deepseek-v4-pro'
                            input_per_million = 0.435
                            output_per_million = 0.87
                            cost = @{
                                currency = 'USD'
                                cost_rule = 'normal'
                                api_cost_per_million = 0.87
                                effective_cost_per_million = 0.87
                                cost_with_thinking_per_million = 1.37
                            }
                        }
                    }
                    benchmarks = @{
                        swe_bench_pro = @{
                            score = 55.4
                            source = 'swebench'
                            source_url = 'https://www.swebench.com/'
                            date = '2026-08'
                            confidence = 0.9
                            measurement_context = 'max'
                        }
                    }
                    tokenizer_efficiency = 2.12
                    speed_tok_per_s = 95.6
                    reasoning_effort = 'max'
                    thinking_token_ratio = 0.57
                    thinking_tokens = @{
                        avg_per_output_1k = 570
                        max_per_output_1k = 1200
                        notes = 'Measured with max effort.'
                    }
                }
            }
        }
        $bench | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $benchmarksDir 'models.json') -Encoding utf8

        $db = & (Get-Module SalmonRun.PondEngine) { Get-SalmonRunBenchmarkData }

        $db.models.ContainsKey('deepseek-v4-pro') | Should -Be $true
        $db.models['deepseek-v4-pro']['benchmarks']['swe_bench_pro']['score'] | Should -Be 55.4
        $db.sources['swebench']['url'] | Should -Be 'https://www.swebench.com/'
    }

    It 'enriches the execution profile with benchmark fields' {
        $bench = @{
            last_updated = '2026-08-26'
            sources = @{}
            models = @{
                'deepseek-v4-pro' = @{
                    name = 'DeepSeek V4 Pro'
                    family = 'deepseek'
                    providers = @{
                        dsh = @{
                            model_id = 'deepseek-v4-pro'
                            input_per_million = 0.435
                            output_per_million = 0.87
                            cost = @{
                                cost_rule = 'normal'
                                api_cost_per_million = 0.87
                                effective_cost_per_million = 0.87
                                cost_with_thinking_per_million = 1.37
                            }
                        }
                    }
                    benchmarks = @{
                        swe_bench_pro = @{
                            score = 55.4
                            source = 'swebench'
                            source_url = 'https://www.swebench.com/'
                            date = '2026-08'
                        }
                    }
                    tokenizer_efficiency = 2.12
                    speed_tok_per_s = 95.6
                    reasoning_effort = 'max'
                    thinking_token_ratio = 0.57
                    references = @('https://www.swebench.com/', 'https://tbench.ai/')
                }
            }
        }
        $bench | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $benchmarksDir 'models.json') -Encoding utf8

        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }

        $profile.Provider | Should -Be 'dsh'
        $profile.Model | Should -Be 'deepseek-v4-pro'
        $profile.CostRule | Should -Be 'normal'
        $profile.ApiCostPer1KTokens | Should -Be 0.87
        $profile.EffectiveCostPer1KTokens | Should -Be 0.87
        $profile.CostWithThinking | Should -Be 1.37
        $profile.ThinkingTokenRatio | Should -Be 0.57
        $profile.ThinkingTokensPer1KOutput | Should -Be 570
        $profile.TokenizerEfficiency | Should -Be 2.12
        $profile.SpeedTokPerS | Should -Be 95.6
        $profile.Benchmarks['swe_bench_pro']['score'] | Should -Be 55.4
        $profile.References | Should -Contain 'https://www.swebench.com/'
    }

    It 'matches provider overlay models by provider model_id' {
        $providersDir = Join-Path $env:SALMON_RUN_HOME 'providers'
        $null = New-Item -ItemType Directory -Path $providersDir -Force

        $providerOverlay = @{
            harnesses = @{ codex = @{ description = 'DeepInfra/Codex harness' } }
            providers = @{
                deepinfra = @{
                    cli = 'codex'
                    defaultModel = 'deepseek-ai/DeepSeek-V4-Flash-0731'
                    defaultEffort = 'medium'
                    acceptedEfforts = @('medium')
                    executorFile = 'DeepInfra'
                    credentials = @('OPENAI_API_KEY')
                    models = @{
                        'deepseek-ai/DeepSeek-V4-Flash-0731' = @{ defaultEffort = 'medium' }
                    }
                }
            }
            models = @(@{
                canonicalName = 'DeepInfra/DeepSeek-V4-Flash'
                harness = 'codex'
                provider = 'deepinfra'
                model = 'deepseek-ai/DeepSeek-V4-Flash-0731'
                effort = 'medium'
                tier = 'Frontier'
                costRule = 'normal'
                apiCostPer1KTokens = 0.18
                effectiveCostPer1KTokens = 0.18
                capabilityScore = 96
                benchmarks = @{ sweBench = 89.0; aime2024 = 96.0; terminalBench21 = 88.0; mmlu = 93.0 }
                cacheContract = 'none'
            })
        }
        $providerOverlay | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'deepinfra.json') -Encoding utf8

        $bench = @{
            sources = @{}
            models = @{
                'deepseek-v4-flash-max' = @{
                    name = 'DeepSeek V4 Flash 0731'
                    family = 'deepseek'
                    providers = @{
                        deepinfra = @{
                            model_id = 'deepseek-ai/DeepSeek-V4-Flash-0731'
                            input_per_million = 0.08
                            output_per_million = 0.18
                            cost = @{
                                cost_rule = 'normal'
                                api_cost_per_million = 0.18
                                effective_cost_per_million = 0.18
                                cost_with_thinking_per_million = 0.241
                            }
                        }
                    }
                    tokenizer_efficiency = 1.84
                    speed_tok_per_s = 41.2
                    reasoning_effort = 'max'
                    thinking_token_ratio = 0.34
                }
            }
        }
        $bench | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $benchmarksDir 'models.json') -Encoding utf8

        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }

        $profile.Provider | Should -Be 'deepinfra'
        $profile.ThinkingTokenRatio | Should -Be 0.34
        $profile.TokenizerEfficiency | Should -Be 1.84
        $profile.CostWithThinking | Should -Be 0.241
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
        @{
            harnesses = @{
                openrouter = @{
                    description = 'OpenRouter multi-file overlay'
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
            models = @(@{
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
            })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $providersDir 'openrouter.json') -Encoding utf8

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
