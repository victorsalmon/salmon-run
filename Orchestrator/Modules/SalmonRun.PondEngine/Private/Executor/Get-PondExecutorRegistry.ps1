function Get-PondExecutorRegistry {
    <#
    .SYNOPSIS
        Loads the harness defaults and model-router catalog used by the
        executor registry.

    .DESCRIPTION
        Reads the built-in harness-defaults.json and model-router-catalog.json
        from the module's Config directory, then merges benchmark data from
        ~/.salmon/benchmarks and any provider overlay files found in
        ~/.salmon/providers. This lets users add or override harnesses,
        providers, models, and cost data without editing the repo.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $orchModule = Get-Module SalmonRun.PondEngine -ErrorAction SilentlyContinue
    if (-not $orchModule) {
        $orchModule = Get-Module SalmonRun.PondEngine -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $orchModule) {
        throw "Get-PondExecutorRegistry: SalmonRun.PondEngine module is required."
    }

    $configDir = Join-Path $orchModule.ModuleBase 'Config'
    $harnessPath = Join-Path $configDir 'harness-defaults.json'
    $catalogPath = Join-Path $configDir 'model-router-catalog.json'

    if (-not (Test-Path -LiteralPath $harnessPath)) {
        throw "Get-PondExecutorRegistry: harness defaults not found at '$harnessPath'."
    }
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        throw "Get-PondExecutorRegistry: model router catalog not found at '$catalogPath'."
    }

    $harness = Get-Content -LiteralPath $harnessPath -Raw | ConvertFrom-Json -AsHashtable
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -AsHashtable

    $salmonHome = if (Get-Command Get-SalmonHome -ErrorAction SilentlyContinue) { Get-SalmonHome } else { Join-Path $HOME '.salmon' }

    # Apply provider overlays from the runtime home.
    $providersDir = Join-Path $salmonHome 'providers'
    if (Test-Path -LiteralPath $providersDir -PathType Container) {
        $harnessOverlayKeys = @('harnesses','providers','legacyExecutorMap','skillSearch')
        $catalogOverlayKeys = @('routerVersion','lastUpdated','benchmarkUrl','ttlHours','tierThresholds','costRules','models')

        foreach ($file in Get-ChildItem -Path $providersDir -Filter '*.json' -File | Sort-Object Name) {
            try {
                $overlay = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                if ($null -eq $overlay) { continue }

                # Explicit split: top-level 'harness' and/or 'catalog' keys.
                if ($overlay.ContainsKey('harness')) {
                    $harness = Merge-ProviderOverlay -Base $harness -Overlay $overlay['harness']
                }
                if ($overlay.ContainsKey('catalog')) {
                    $catalog = Merge-ProviderOverlay -Base $catalog -Overlay $overlay['catalog']
                }

                # Flat overlay: route known keys to the right base.
                foreach ($key in $overlay.Keys) {
                    if ($key -in $harnessOverlayKeys) {
                        $harness = Merge-ProviderOverlay -Base $harness -Overlay @{ $key = $overlay[$key] } -Key $key
                    } elseif ($key -in $catalogOverlayKeys) {
                        $catalog = Merge-ProviderOverlay -Base $catalog -Overlay @{ $key = $overlay[$key] } -Key $key
                    }
                }
            } catch {
                Write-Warning "Get-PondExecutorRegistry: failed to load provider overlay '$($file.FullName)': $_"
            }
        }
    }

    # Apply benchmark data from the runtime home. This runs after provider
    # overlays so that overlay-added models can also be enriched.
    $benchmarksDir = Join-Path $salmonHome 'benchmarks'
    if (Test-Path -LiteralPath $benchmarksDir -PathType Container) {
        try {
            $benchmarkData = Get-SalmonRunBenchmarkData -BenchmarksDir $benchmarksDir
            if ($benchmarkData -and $benchmarkData['models'].Count -gt 0) {
                $catalog = Merge-BenchmarkOverlay -Catalog $catalog -Benchmarks $benchmarkData
            }
        } catch {
            Write-Warning "Get-PondExecutorRegistry: failed to load benchmark data from '$benchmarksDir': $_"
        }
    }

    return [PSCustomObject]@{
        Harness = $harness
        Catalog = $catalog
    }
}
