function Resolve-PondExecutionProfile {
    <#
    .SYNOPSIS
        Resolves a provider/harness/model/effort profile for a pond group from
        the model-router catalog and harness defaults.
    #>
    [CmdletBinding()]
    [OutputType([PondExecutionProfile])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Flash','Daily','Complex','Frontier','Local')]
        [string]$Tier,

        [string]$Harness,

        [string]$Provider,

        [string]$Model,

        [string]$Effort,

        [int]$TimeoutMinutes = 0,

        [double]$CostCeiling = 0.0,

        [string[]]$PlanFiles
    )

    $registry = Get-PondExecutorRegistry
    $catalog = $registry.Catalog
    $harnessDefaults = $registry.Harness

    # Prefer a model whose declared tier exactly matches the plan tier.
    $candidates = @($catalog.models | Where-Object { $_.tier -eq $Tier })
    if ($candidates.Count -eq 0) {
        # Fall back to Daily if no exact match is configured.
        $candidates = @($catalog.models | Where-Object { $_.tier -eq 'Daily' })
    }

    # If a harness is requested, restrict candidates to that family before
    # scoring. This lets callers ask for a specific harness (e.g. opencode or
    # codex) without the default capability-score tie going elsewhere.
    if (-not [string]::IsNullOrWhiteSpace($Harness)) {
        $candidates = @($candidates | Where-Object { $_.harness -eq $Harness })
        if ($candidates.Count -eq 0) {
            throw "Resolve-PondExecutionProfile: no model found for tier '$Tier' and harness '$Harness'."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Provider)) {
        $candidates = @($candidates | Where-Object { $_.provider -eq $Provider })
        if ($candidates.Count -eq 0 -and [string]::IsNullOrWhiteSpace($Model)) {
            throw "Resolve-PondExecutionProfile: no model found for tier '$Tier' and provider '$Provider'."
        }
    }

    # If a specific model is requested, pin to it (case-insensitive) instead of
    # tier/capability scoring. This keeps the default resolution (highest
    # capability score) intact while allowing tests and callers to target a
    # particular catalog entry.
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $pinned = @($catalog.models | Where-Object { $_.model -eq $Model })
        if ($pinned.Count -eq 0) {
            throw "Resolve-PondExecutionProfile: no model found with name '$Model'."
        }
        $selected = $pinned[0]
    } else {
        # Choose the highest-scoring model for the tier.
        $selected = $candidates |
            Sort-Object -Property { [int]$_.capabilityScore } |
            Select-Object -Last 1
    }

    if (-not $selected) {
        throw "Resolve-PondExecutionProfile: no model found for tier '$Tier'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Harness) -and $selected.harness -ne $Harness) {
        throw "Resolve-PondExecutionProfile: model '$Model' does not use harness '$Harness'."
    }
    if (-not [string]::IsNullOrWhiteSpace($Provider) -and $selected.provider -ne $Provider) {
        throw "Resolve-PondExecutionProfile: model '$Model' does not use provider '$Provider'."
    }

    # Validate and normalize against harness-defaults.json.
    $harnessName = $selected.harness
    if (-not $harnessDefaults['harnesses'].ContainsKey($harnessName)) {
        throw "Resolve-PondExecutionProfile: unknown harness '$harnessName'."
    }

    $provider = $selected.provider
    if (-not $harnessDefaults['providers'].ContainsKey($provider)) {
        throw "Resolve-PondExecutionProfile: unknown provider '$provider' for harness '$harnessName'."
    }
    $providerCfg = $harnessDefaults['providers'][$provider]

    $model = $selected.model
    if ($providerCfg['models'] -and -not $providerCfg['models'].ContainsKey($model)) {
        throw "Resolve-PondExecutionProfile: unknown model '$model' for provider '$provider'."
    }

    $resolvedEffort = if ([string]::IsNullOrWhiteSpace($Effort)) { $selected.effort } else { $Effort }
    if ($providerCfg['acceptedEfforts'] -and $resolvedEffort -notin $providerCfg['acceptedEfforts']) {
        if (-not [string]::IsNullOrWhiteSpace($Effort)) {
            throw "Resolve-PondExecutionProfile: effort '$Effort' is not accepted for provider '$provider'."
        }
        Write-Verbose "Resolve-PondExecutionProfile: effort '$resolvedEffort' not accepted for provider '$provider'; using '$($providerCfg['defaultEffort'])'"
        $resolvedEffort = $providerCfg['defaultEffort']
    }

    $costRule = if ($selected.ContainsKey('costRule')) { $selected['costRule'] } else { 'normal' }
    $apiCost = if ($selected.ContainsKey('apiCostPer1KTokens')) { [double]$selected['apiCostPer1KTokens'] } else { 0.0 }
    $effectiveCost = if ($selected.ContainsKey('effectiveCostPer1KTokens')) { [double]$selected['effectiveCostPer1KTokens'] } else { 0.0 }

    # Apply benchmark data, if present. Benchmark data can override or extend
    # catalog cost and adds tokenizer/speed/thinking/official-source metadata.
    $benchmarkData = if ($selected.ContainsKey('benchmarkData')) { $selected['benchmarkData'] } else { $null }

    [double]$multiplier = 1.0
    if ($catalog.ContainsKey('costRules') -and $catalog['costRules'].ContainsKey($costRule)) {
        $multiplier = [double]$catalog['costRules'][$costRule]['multiplier']
    }

    if ($benchmarkData) {
        # Prefer provider-specific cost, then top-level model cost, then catalog cost.
        $costData = $null
        if ($benchmarkData.ContainsKey('providers') -and
            $benchmarkData['providers'] -is [hashtable] -and
            $benchmarkData['providers'].ContainsKey($provider) -and
            $benchmarkData['providers'][$provider] -is [hashtable] -and
            $benchmarkData['providers'][$provider].ContainsKey('cost')) {
            $costData = $benchmarkData['providers'][$provider]['cost']
        }
        if ($null -eq $costData -and $benchmarkData.ContainsKey('cost')) {
            $costData = $benchmarkData['cost']
        }

        if ($costData) {
            if ($costData.ContainsKey('cost_rule')) { $costRule = $costData['cost_rule'] }
            if ($costData.ContainsKey('api_cost_per_million')) { $apiCost = [double]$costData['api_cost_per_million'] }
            if ($costData.ContainsKey('effective_cost_per_million')) {
                $effectiveCost = [double]$costData['effective_cost_per_million']
            } else {
                $effectiveCost = $apiCost * $multiplier
            }
        }

        if ($catalog.ContainsKey('costRules') -and $catalog['costRules'].ContainsKey($costRule)) {
            $multiplier = [double]$catalog['costRules'][$costRule]['multiplier']
        }
        if (-not ($costData -and $costData.ContainsKey('effective_cost_per_million'))) {
            $effectiveCost = $apiCost * $multiplier
        }
    }

    [double]$thinkingTokenRatio = 0.0
    if ($benchmarkData -and $benchmarkData.ContainsKey('thinking_token_ratio')) {
        $thinkingTokenRatio = [double]$benchmarkData['thinking_token_ratio']
    }

    [double]$costWithThinking = if ($benchmarkData -and $benchmarkData.ContainsKey('cost') -and $benchmarkData['cost'].ContainsKey('cost_with_thinking_per_million')) {
        [double]$benchmarkData['cost']['cost_with_thinking_per_million']
    } elseif ($benchmarkData -and $benchmarkData.ContainsKey('providers') -and
              $benchmarkData['providers'].ContainsKey($provider) -and
              $benchmarkData['providers'][$provider].ContainsKey('cost') -and
              $benchmarkData['providers'][$provider]['cost'].ContainsKey('cost_with_thinking_per_million')) {
        [double]$benchmarkData['providers'][$provider]['cost']['cost_with_thinking_per_million']
    } else {
        $effectiveCost * (1.0 + $thinkingTokenRatio)
    }

    $srExecProfile = [PondExecutionProfile]::new()
    $srExecProfile.Tier         = $Tier
    $srExecProfile.Harness      = $harnessName
    $srExecProfile.Provider     = $provider
    $srExecProfile.Model        = $model
    $srExecProfile.Effort       = $resolvedEffort
    $srExecProfile.Cli          = $providerCfg['cli']
    $srExecProfile.ExecutorFile = $providerCfg['executorFile']
    $srExecProfile.TimeoutMinutes = if ($TimeoutMinutes -gt 0) { $TimeoutMinutes } elseif ($providerCfg['defaultTimeoutMinutes']) { $providerCfg['defaultTimeoutMinutes'] } else { 30 }
    $srExecProfile.Credentials  = [string[]](@($providerCfg['credentials'] | Where-Object { $null -ne $_ }))
    $srExecProfile.CostRule     = $costRule
    $srExecProfile.ApiCostPer1KTokens = $apiCost
    $srExecProfile.EffectiveCostPer1KTokens = $effectiveCost
    $srExecProfile.CostCeiling = $CostCeiling
    $srExecProfile.CostWithThinking = $costWithThinking

    if ($benchmarkData) {
        if ($benchmarkData.ContainsKey('benchmarks')) { $srExecProfile.Benchmarks = $benchmarkData['benchmarks'] }
        if ($benchmarkData.ContainsKey('tokenizer_efficiency')) { $srExecProfile.TokenizerEfficiency = [double]$benchmarkData['tokenizer_efficiency'] }
        if ($benchmarkData.ContainsKey('speed_tok_per_s')) { $srExecProfile.SpeedTokPerS = [double]$benchmarkData['speed_tok_per_s'] }
        if ($benchmarkData.ContainsKey('reasoning_effort')) { $srExecProfile.ReasoningEffort = $benchmarkData['reasoning_effort'] }
        $srExecProfile.ThinkingTokenRatio = $thinkingTokenRatio
        $srExecProfile.ThinkingTokensPer1KOutput = $thinkingTokenRatio * 1000.0
        if ($benchmarkData.ContainsKey('providers')) { $srExecProfile.ProviderPricing = $benchmarkData['providers'] }
        if ($benchmarkData.ContainsKey('references')) { $srExecProfile.References = [string[]]$benchmarkData['references'] }
    } else {
        $srExecProfile.ThinkingTokenRatio = 0.0
        $srExecProfile.ThinkingTokensPer1KOutput = 0.0
        $srExecProfile.CostWithThinking = $effectiveCost
        if ($selected.ContainsKey('benchmarks')) { $srExecProfile.Benchmarks = $selected['benchmarks'] }
    }

    return $srExecProfile
}


