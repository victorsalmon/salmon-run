# ModelRouter.ps1
# Per-plan model router for the salmon-orchestrator dispatch pipeline.
# Maps Tasks/Code/ plans to the cheapest capable OCG/DSO model, honors
# confirmed plan overrides, and consumes the router catalog.

$script:ModelRouterCatalogPath = Join-Path $PSScriptRoot "..\Config\model-router-catalog.json"
$script:ModelRouterCatalog = $null

function Get-ModelRouterCatalog {
    <#
    .SYNOPSIS
        Loads the model router catalog. Caches it for the process lifetime.
    .DESCRIPTION
        Returns the local catalog. A future revision will fetch the public
        Clock Lobster benchmark feed (model-router-catalog.json -> benchmarkUrl)
        and merge it over the local file when the TTL expires.
    #>
    [CmdletBinding()]
    param()
    if ($script:ModelRouterCatalog) { return $script:ModelRouterCatalog }
    if (-not (Test-Path -LiteralPath $script:ModelRouterCatalogPath)) {
        throw "Model router catalog not found at '$script:ModelRouterCatalogPath'"
    }
    $script:ModelRouterCatalog = Get-Content -LiteralPath $script:ModelRouterCatalogPath -Raw | ConvertFrom-Json
    return $script:ModelRouterCatalog
}

function Get-ModelRouterCatalogPath {
    return $script:ModelRouterCatalogPath
}

function TierRank {
    param([string]$Tier)
    switch ($Tier) {
        'Flash'    { return 0 }
        'Daily'    { return 1 }
        'Complex'  { return 2 }
        'Frontier' { return 3 }
        default    { return 0 }
    }
}

function Get-PlanChallengeTier {
    <#
    .SYNOPSIS
        Determines the challenge tier for a single plan body.
    .DESCRIPTION
        Returns a tier (Flash|Daily|Complex|Frontier) and a source label.
        First checks an explicit **Challenge**: header, then a Challenge= value
        inside **Overrides**:, and finally derives a tier from plan metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$Catalog
    )

    # 1. Explicit **Challenge**: header
    $challengeMatch = [regex]::Match($Content, '(?im)^\*\*Challenge\*\*:\s*(?<value>[^\r\n]+)\s*$')
    if ($challengeMatch.Success) {
        $tier = $challengeMatch.Groups['value'].Value.Trim()
        if ($null -ne $Catalog.tierThresholds.$tier) {
            return @{ Tier = $tier; Source = 'challenge-header' }
        }
        Write-OrchestratorLogSafe "MODEL_ROUTER_IGNORED_CHALLENGE tier='$tier' reason='not in router catalog'" -Level WARN
    }

    # 2. Parse optional plan headers for derivation
    $tokenK = 0
    $tokenMatch = [regex]::Match($Content, '(?im)^\*\*Token budget\*\*:\s*estimated\s*(?<value>\d+(?:\.\d+)?)\s*(?<unit>K|M)?')
    if ($tokenMatch.Success) {
        $tokenK = [double]$tokenMatch.Groups['value'].Value
        $unit = $tokenMatch.Groups['unit'].Value
        if ($unit -eq 'M') { $tokenK *= 1000 }
    }

    $fileCount = 0
    $fileMatch = [regex]::Match($Content, '(?im)^\*\*Files\*\*:\s*(?<value>[^\r\n]+)')
    if ($fileMatch.Success) {
        $fileCount = @($fileMatch.Groups['value'].Value -split ',').Count
    }

    $connascenceMatch = [regex]::Match($Content, '(?im)^\*\*Connascence\*\*:\s*(?<value>[^\r\n]+)')
    $hasConnascence = $connascenceMatch.Success -and $connascenceMatch.Groups['value'].Value.Trim() -ne 'None'
    $highSeverity = ([regex]::Matches($Content, '\[[^\]]*(?:critical|high)[^\]]*\]')).Count
    $mediumSeverity = ([regex]::Matches($Content, '\[[^\]]*medium[^\]]*\]')).Count

    # 3. Derive tier
    $tier = 'Flash'
    if ($tokenK -ge 200) { $tier = 'Frontier' }
    elseif ($tokenK -ge 80) { $tier = 'Complex' }
    elseif ($tokenK -ge 20) { $tier = 'Daily' }

    if ($fileCount -ge 10 -and (TierRank $tier) -lt (TierRank 'Complex')) {
        $tier = 'Complex'
    }
    if ($highSeverity -ge 2 -and (TierRank $tier) -lt (TierRank 'Complex')) {
        $tier = 'Complex'
    }
    if ($highSeverity -ge 1 -and (TierRank $tier) -lt (TierRank 'Daily')) {
        $tier = 'Daily'
    }
    if ($mediumSeverity -ge 3 -and (TierRank $tier) -lt (TierRank 'Daily')) {
        $tier = 'Daily'
    }
    if ($hasConnascence -and (TierRank $tier) -lt (TierRank 'Daily')) {
        $tier = 'Daily'
    }

    return @{ Tier = $tier; Source = 'derived' }
}

function Convert-ModelNameToTier {
    <#
    .SYNOPSIS
        Heuristic tier guess from a raw model name when the model is not in the catalog.
    #>
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
    if ($Model -match 'pro|frontier') { return 'Frontier' }
    if ($Model -match 'deepseek-v4-flash|flash') { return 'Complex' }
    if ($Model -match 'mimo|hy3') { return 'Daily' }
    if ($Model -match 'alpha|ox-alpha') { return 'Flash' }
    return $null
}

function Select-ModelForPlan {
    <#
    .SYNOPSIS
        Selects the cheapest capable model for a given challenge tier.
    .DESCRIPTION
        If a specific model is supplied and exists in the catalog, it is returned.
        Otherwise, all catalog models with capabilityScore >= the tier threshold
        are sorted by effectiveCostPer1KTokens (ascending) then capabilityScore
        (descending) and the first is selected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tier,
        [Parameter(Mandatory)]$Catalog,
        [string]$SpecificModel = ''
    )

    if ($SpecificModel) {
        $catalogModel = $Catalog.models | Where-Object {
            $_.model -eq $SpecificModel -or $_.canonicalName -eq $SpecificModel
        } | Select-Object -First 1

        if ($catalogModel) {
            return $catalogModel
        }

        $derivedTier = Convert-ModelNameToTier -Model $SpecificModel
        if ($derivedTier -and $null -ne $Catalog.tierThresholds.$derivedTier) {
            Write-OrchestratorLogSafe "MODEL_ROUTER_UNKNOWN_MODEL specific='$SpecificModel' derivedTier='$derivedTier'" -Level WARN
            $Tier = $derivedTier
        } else {
            Write-OrchestratorLogSafe "MODEL_ROUTER_UNKNOWN_MODEL specific='$SpecificModel' fallingBackToTier='$Tier'" -Level WARN
        }
    }

    $threshold = $Catalog.tierThresholds.$Tier
    $candidates = $Catalog.models | Where-Object { $_.capabilityScore -ge $threshold }
    if (-not $candidates) {
        Write-OrchestratorLogSafe "MODEL_ROUTER_NO_CAPABLE_MODEL tier='$Tier' threshold='$threshold'" -Level WARN
        $candidates = $Catalog.models
    }

    $selected = $candidates |
        Sort-Object -Property effectiveCostPer1KTokens, @{Expression = 'capabilityScore'; Descending = $true} |
        Select-Object -First 1

    return $selected
}

function Resolve-ModelRoutedProfile {
    <#
    .SYNOPSIS
        Resolves a plan stream to a model-routed execution profile.
    .DESCRIPTION
        Reads each plan in the stream, determines the highest challenge tier,
        respects a confirmed model override, and returns the selected
        HarnessConfig. This function replaces the legacy Get-PlanExecutionProfile
        call in the dispatch loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PlanPath,
        [Parameter(Mandatory)]$DefaultConfig
    )

    $catalog = Get-ModelRouterCatalog
    $planProfiles = foreach ($path in $PlanPath) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Plan not found: '$path'" }
        $content = Get-Content -LiteralPath $path -Raw
        $values = @{}

        $overrideHeader = [regex]::Match($content, '(?im)^\*\*Overrides\*\*:\s*(?<value>[^\r\n]+)\s*$')
        if ($overrideHeader.Success) {
            $rawOverrides = $overrideHeader.Groups['value'].Value.Trim()
            if ($rawOverrides -and $rawOverrides -notmatch '^(default|inherit|none)$') {
                foreach ($pair in ($rawOverrides -split '\s*[,;]\s*')) {
                    if ($pair -notmatch '^(?<field>Harness|Provider|Model|Effort|Challenge)\s*=\s*(?<value>.+)$') {
                        throw "Plan '$([IO.Path]::GetFileName($path))' has an invalid Overrides entry '$pair'. Use 'Harness=<value>, Provider=<value>, Model=<value>, Effort=<value>, Challenge=<value>'."
                    }
                    $field = $Matches['field']
                    $value = $Matches['value'].Trim()
                    if ($value -and $value -notmatch '^(default|inherit)$') { $values[$field] = $value }
                }
            }
        }

        $challenge = $null
        $challengeHeader = [regex]::Match($content, '(?im)^\*\*Challenge\*\*:\s*(?<value>[^\r\n]+)\s*$')
        if ($challengeHeader.Success) { $challenge = $challengeHeader.Groups['value'].Value.Trim() }
        if ($values.Challenge) { $challenge = $values.Challenge }

        $hasOverride = $values.Count -gt 0
        if ($hasOverride) {
            $confirmation = [regex]::Match($content, '(?im)^\*\*Overrides confirmation\*\*:\s*confirmed(?:\s+by\s+user)?\s*$')
            if (-not $confirmation.Success) {
                throw "Plan '$([IO.Path]::GetFileName($path))' has Overrides but lacks '**Overrides confirmation**: confirmed by user'."
            }
        }

        [PSCustomObject]@{
            Path       = $path
            Content    = $content
            HasOverride= $hasOverride
            Challenge  = $challenge
            Model      = $values.Model
            Harness    = $values.Harness
            Provider   = $values.Provider
            Effort     = $values.Effort
        }
    }

    # Find the highest challenge tier and a consistent specific model override.
    $highestTier = 'Flash'
    $highestSource = 'default'
    $specificModel = $null
    foreach ($p in $planProfiles) {
        $tierInfo = if ($p.Challenge) {
            if ($null -ne $catalog.tierThresholds.($p.Challenge)) {
                @{ Tier = $p.Challenge; Source = 'challenge-override' }
            } else {
                Write-OrchestratorLogSafe "MODEL_ROUTER_IGNORED_CHALLENGE_OVERRIDE tier='$($p.Challenge)'" -Level WARN
                Get-PlanChallengeTier -Content $p.Content -Catalog $catalog
            }
        } else {
            Get-PlanChallengeTier -Content $p.Content -Catalog $catalog
        }

        if ((TierRank $tierInfo.Tier) -gt (TierRank $highestTier)) {
            $highestTier = $tierInfo.Tier
            $highestSource = $tierInfo.Source
        }

        if ($p.HasOverride -and $p.Model) {
            if ($specificModel -and $specificModel -ne $p.Model) {
                throw "Plans grouped into one stream declare incompatible model overrides: $specificModel vs $($p.Model). Split them into separate namespaces."
            }
            $specificModel = $p.Model
        }
    }

    # Determine the final model.
    if ($specificModel) {
        $catalogModel = $catalog.models | Where-Object {
            $_.model -eq $specificModel -or $_.canonicalName -eq $specificModel
        } | Select-Object -First 1

        if ($catalogModel) {
            $selectedModel = $catalogModel
            $reason = "confirmed model override: $specificModel"
            $planProfileOverride = $true
        } else {
            $selectedModel = Select-ModelForPlan -Tier $highestTier -Catalog $catalog
            $reason = "confirmed model override '$specificModel' not in router catalog; routed to $($selectedModel.canonicalName) for $highestTier tier"
            Write-OrchestratorLogSafe "MODEL_ROUTER_FALLBACK $reason" -Level WARN
            $planProfileOverride = $false
        }
    } else {
        $selectedModel = Select-ModelForPlan -Tier $highestTier -Catalog $catalog
        $reason = "routed to $($selectedModel.canonicalName) for $highestTier tier (source=$highestSource)"
        $planProfileOverride = $false
    }

    $resolved = Resolve-HarnessConfig `
        -Harness $selectedModel.harness `
        -Provider $selectedModel.provider `
        -Model $selectedModel.model `
        -Effort $selectedModel.effort

    Write-OrchestratorLogSafe "MODEL_ROUTER_RESOLVED tier=$highestTier source=$highestSource model=$($selectedModel.canonicalName) reason='$reason'"

    return [PSCustomObject]@{
        Path                = $planProfiles[0].Path
        HasOverride         = $planProfileOverride
        Config              = $resolved
        Tier                = $highestTier
        RoutedModel         = $selectedModel.canonicalName
        Routed              = -not $planProfileOverride
        Reason              = $reason
    }
}
