function Merge-BenchmarkOverlay {
    <#
    .SYNOPSIS
        Enrich a model-router catalog with benchmark data from
        ~/.salmon/benchmarks.

    .DESCRIPTION
        For each catalog model, look up the matching model in the benchmark
        database by exact 'model' or 'canonicalName' key, or by provider
        model_id. If a match is found, attach the benchmark block as the
        'benchmarkData' key on the catalog model so Resolve-PondExecutionProfile
        can copy the enriched fields onto the execution profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Catalog,

        [Parameter(Mandatory)]
        [hashtable]$Benchmarks
    )

    if (-not $Benchmarks.ContainsKey('models') -or $Benchmarks['models'].Count -eq 0) {
        return $Catalog
    }

    $benchmarkModels = $Benchmarks['models']

    foreach ($catalogModel in $Catalog['models']) {
        $slug = if ($catalogModel.ContainsKey('model')) { $catalogModel['model'] } else { $null }
        $canonicalName = if ($catalogModel.ContainsKey('canonicalName')) { $catalogModel['canonicalName'] } else { $null }
        $provider = if ($catalogModel.ContainsKey('provider')) { $catalogModel['provider'] } else { $null }

        $match = $null

        # 1. Exact match by the salmon-run 'model' value.
        if (-not [string]::IsNullOrWhiteSpace($slug) -and $benchmarkModels.ContainsKey($slug)) {
            $match = $benchmarkModels[$slug]
        }

        # 2. Exact match by canonicalName.
        if ($null -eq $match -and -not [string]::IsNullOrWhiteSpace($canonicalName) -and $benchmarkModels.ContainsKey($canonicalName)) {
            $match = $benchmarkModels[$canonicalName]
        }

        # 3. Match by provider model_id (e.g. deepinfra's 'deepseek-ai/DeepSeek-V4-Flash-0731').
        if ($null -eq $match -and -not [string]::IsNullOrWhiteSpace($provider) -and -not [string]::IsNullOrWhiteSpace($slug)) {
            foreach ($benchModel in $benchmarkModels.Values) {
                if (-not $benchModel.ContainsKey('providers')) { continue }
                $prov = $benchModel['providers']
                if ($prov -isnot [hashtable]) { continue }
                if ($prov.ContainsKey($provider) -and $prov[$provider] -is [hashtable]) {
                    $provCfg = $prov[$provider]
                    if ($provCfg.ContainsKey('model_id') -and ($provCfg['model_id'] -eq $slug -or $provCfg['model_id'] -eq $canonicalName)) {
                        $match = $benchModel
                        break
                    }
                }
            }
        }

        if ($match) {
            $catalogModel['benchmarkData'] = $match
        }
    }

    return $Catalog
}
