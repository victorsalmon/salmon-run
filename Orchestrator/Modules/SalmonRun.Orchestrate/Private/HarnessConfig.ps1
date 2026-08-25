# HarnessConfig.ps1
# Resolves harness, provider, model, and effort from parameters, environment,
# and Config/harness-defaults.json. Also provides skill-directory fallback.

$script:HarnessDefaultsPath = Join-Path $PSScriptRoot "..\Config\harness-defaults.json"
$script:HarnessDefaults = $null

function Get-HarnessDefaults {
    if ($script:HarnessDefaults) { return $script:HarnessDefaults }
    if (-not (Test-Path $script:HarnessDefaultsPath)) {
        throw "Harness defaults not found at '$script:HarnessDefaultsPath'"
    }
    $script:HarnessDefaults = Get-Content $script:HarnessDefaultsPath -Raw | ConvertFrom-Json -AsHashtable
    return $script:HarnessDefaults
}

function Resolve-HarnessConfig {
    [CmdletBinding()]
    param(
        [string]$Harness,
        [string]$Provider,
        [string]$Model,
        [string]$Effort,
        [string]$LegacyExecutor,
        [string]$ServerMode = 'local'
    )
    $defaults = Get-HarnessDefaults

    # If a legacy Executor value was passed, map it to a harness/provider first.
    if ([string]::IsNullOrWhiteSpace($Harness) -and -not [string]::IsNullOrWhiteSpace($LegacyExecutor)) {
        $legacy = $defaults['legacyExecutorMap'][$LegacyExecutor]
        if ($legacy) {
            $Harness = $legacy['harness']
            if ([string]::IsNullOrWhiteSpace($Provider)) { $Provider = $legacy['provider'] }
            if ($LegacyExecutor -in @('local-platform', 'platform')) { $ServerMode = $LegacyExecutor }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Harness)) { $Harness = 'opencode' }
    if (-not $defaults['harnesses'].ContainsKey($Harness)) {
        throw "Unknown harness '$Harness'. Valid harnesses: $($defaults['harnesses'].Keys -join ', ')"
    }
    $harnessCfg = $defaults['harnesses'][$Harness]

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        $Provider = if ($env:OC_PROVIDER) { $env:OC_PROVIDER } else { $harnessCfg['defaultProvider'] }
    }
    if (-not $defaults['providers'].ContainsKey($Provider)) {
        throw "Unknown provider '$Provider' for harness '$Harness'. Valid providers: $($defaults['providers'].Keys -join ', ')"
    }
    $providerCfg = $defaults['providers'][$Provider]

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = if ($env:OC_MODEL) { $env:OC_MODEL } elseif ($providerCfg['models'] -and $providerCfg['models'].ContainsKey($providerCfg['defaultModel'])) { $providerCfg['defaultModel'] } else { $providerCfg['defaultModel'] }
    }
    if ($providerCfg['models'] -and -not $providerCfg['models'].ContainsKey($Model)) {
        throw "Unknown model '$Model' for provider '$Provider'. Valid models: $($providerCfg['models'].Keys -join ', ')"
    }
    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = if ($env:OC_EFFORT) { $env:OC_EFFORT } else { $providerCfg['defaultEffort'] }
    }
    if ($providerCfg['acceptedEfforts'] -and $Effort -notin $providerCfg['acceptedEfforts']) {
        Write-Warning "Effort '$Effort' is not in accepted values for provider '$Provider' ($($providerCfg['acceptedEfforts'] -join ', ')); using default '$($providerCfg['defaultEffort'])'"
        $Effort = $providerCfg['defaultEffort']
    }

    $executorFile = $providerCfg['executorFile']
    $cli = $providerCfg['cli']

    return [PSCustomObject]@{
        Harness      = $Harness
        Provider     = $Provider
        Model        = $Model
        Effort       = $Effort
        ExecutorFile = $executorFile
        Cli          = $cli
        ServerMode   = $ServerMode
    }
}

function Get-PlanExecutionProfile {
    <#
    .SYNOPSIS
        Resolves a plan's optional Overrides header over a run default.
    .DESCRIPTION
        A plan Override is deliberately a plan-level contract. It is
        only dispatchable after an interactive user has confirmed it in the plan.
        All plans grouped into one stream must resolve to the same profile; otherwise
        the caller receives a deterministic error instead of silently using one plan's
        model for another plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PlanPath,
        [Parameter(Mandatory)]$DefaultConfig
    )

    $profiles = foreach ($path in $PlanPath) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Plan not found: '$path'" }
        $content = Get-Content -LiteralPath $path -Raw
        $values = @{}
        $overrideHeader = [regex]::Match($content, '(?im)^\*\*Overrides\*\*:\s*(?<value>[^\r\n]+)\s*$')
        if ($overrideHeader.Success) {
            $rawOverrides = $overrideHeader.Groups['value'].Value.Trim()
            if ($rawOverrides -and $rawOverrides -notmatch '^(default|inherit|none)$') {
                foreach ($pair in ($rawOverrides -split '\s*[,;]\s*')) {
                    if ($pair -notmatch '^(?<field>Harness|Provider|Model|Effort)\s*=\s*(?<value>.+)$') {
                        throw "Plan '$([IO.Path]::GetFileName($path))' has an invalid Overrides entry '$pair'. Use 'Harness=<value>, Provider=<value>, Model=<value>, Effort=<value>'."
                    }
                    $field = $Matches['field']
                    $value = $Matches['value'].Trim()
                    if ($value -and $value -notmatch '^(default|inherit)$') { $values[$field] = $value }
                }
            }
        }
        $hasOverride = $values.Count -gt 0
        if ($hasOverride) {
            $confirmation = [regex]::Match($content, '(?im)^\*\*Overrides confirmation\*\*:\s*confirmed(?:\s+by\s+user)?\s*$')
            if (-not $confirmation.Success) {
                throw "Plan '$([IO.Path]::GetFileName($path))' has Overrides but lacks '**Overrides confirmation**: confirmed by user'."
            }
        }
        $resolved = Resolve-HarnessConfig `
            -Harness $(if ($values.Harness) { $values.Harness } else { $DefaultConfig.Harness }) `
            -Provider $(if ($values.Provider) { $values.Provider } else { $DefaultConfig.Provider }) `
            -Model $(if ($values.Model) { $values.Model } else { $DefaultConfig.Model }) `
            -Effort $(if ($values.Effort) { $values.Effort } else { $DefaultConfig.Effort })
        [PSCustomObject]@{ Path = $path; HasOverride = $hasOverride; Config = $resolved }
    }

    $keys = @($profiles | ForEach-Object { "$($_.Config.Harness)|$($_.Config.Provider)|$($_.Config.Model)|$($_.Config.Effort)" } | Select-Object -Unique)
    if ($keys.Count -ne 1) {
        throw "Plans grouped into one stream declare incompatible Overrides: $($keys -join '; '). Split them into separate namespaces."
    }
    return $profiles[0]
}

function Get-SkillsRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-InterclawRepoRoot }
    $candidates = @(
        (Join-Path $RepoRoot 'Skills'),
        (Join-Path (Split-Path $RepoRoot -Parent) 'Skills')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c -PathType Container) { return $c }
    }
    return $candidates[0]
}

function Resolve-SkillPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-InterclawRepoRoot }
    $roots = @($RepoRoot, (Split-Path $RepoRoot -Parent))
    foreach ($root in $roots) {
        $full = Join-Path $root $RelativePath
        if (Test-Path $full) { return $full }
    }
    return $null
}
