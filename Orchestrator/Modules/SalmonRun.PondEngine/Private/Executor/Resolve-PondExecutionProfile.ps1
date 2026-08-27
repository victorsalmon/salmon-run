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

        [string[]]$PlanFiles
    )

    $registry = Get-PondExecutorRegistry
    $catalog = $registry.Catalog
    $harness = $registry.Harness

    # Prefer a model whose declared tier exactly matches the plan tier.
    $candidates = @($catalog.models | Where-Object { $_.tier -eq $Tier })
    if ($candidates.Count -eq 0) {
        # Fall back to Daily if no exact match is configured.
        $candidates = @($catalog.models | Where-Object { $_.tier -eq 'Daily' })
    }

    # Choose the highest-scoring model for the tier.
    $selected = $candidates |
        Sort-Object -Property { [int]$_.capabilityScore } |
        Select-Object -Last 1

    if (-not $selected) {
        throw "Resolve-PondExecutionProfile: no model found for tier '$Tier'."
    }

    # Validate and normalize against harness-defaults.json.
    $harnessName = $selected.harness
    if (-not $harness['harnesses'].ContainsKey($harnessName)) {
        throw "Resolve-PondExecutionProfile: unknown harness '$harnessName'."
    }
    $harnessCfg = $harness['harnesses'][$harnessName]

    $provider = $selected.provider
    if (-not $harness['providers'].ContainsKey($provider)) {
        throw "Resolve-PondExecutionProfile: unknown provider '$provider' for harness '$harnessName'."
    }
    $providerCfg = $harness['providers'][$provider]

    $model = $selected.model
    if ($providerCfg['models'] -and -not $providerCfg['models'].ContainsKey($model)) {
        throw "Resolve-PondExecutionProfile: unknown model '$model' for provider '$provider'."
    }

    $effort = $selected.effort
    if ($providerCfg['acceptedEfforts'] -and $effort -notin $providerCfg['acceptedEfforts']) {
        Write-Verbose "Resolve-PondExecutionProfile: effort '$effort' not accepted for provider '$provider'; using '$($providerCfg['defaultEffort'])'"
        $effort = $providerCfg['defaultEffort']
    }

    $costRule = if ($selected.ContainsKey('costRule')) { $selected['costRule'] } else { 'normal' }
    $apiCost = if ($selected.ContainsKey('apiCostPer1KTokens')) { [double]$selected['apiCostPer1KTokens'] } else { 0.0 }
    $effectiveCost = if ($selected.ContainsKey('effectiveCostPer1KTokens')) { [double]$selected['effectiveCostPer1KTokens'] } else { 0.0 }

    $profile = [PondExecutionProfile]::new()
    $profile.Tier         = $Tier
    $profile.Harness      = $harnessName
    $profile.Provider     = $provider
    $profile.Model        = $model
    $profile.Effort       = $effort
    $profile.Cli          = $providerCfg['cli']
    $profile.ExecutorFile = $providerCfg['executorFile']
    $profile.TimeoutMinutes = if ($providerCfg['defaultTimeoutMinutes']) { $providerCfg['defaultTimeoutMinutes'] } else { 30 }
    $profile.Credentials  = [string[]](@($providerCfg['credentials'] | Where-Object { $_ -ne $null }))
    $profile.CostRule     = $costRule
    $profile.ApiCostPer1KTokens = $apiCost
    $profile.EffectiveCostPer1KTokens = $effectiveCost

    return $profile
}
