function Get-SalmonRunBenchmarkData {
    <#
    .SYNOPSIS
        Loads the user runtime benchmark database from ~/.salmon/benchmarks.

    .DESCRIPTION
        Looks for benchmark JSON files in the runtime benchmarks directory.
        The canonical file is ~/.salmon/benchmarks/models.json; a
        per-model models/ directory is also supported for fine-grained
        overrides.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$BenchmarksDir = (Join-Path (Get-SalmonHome) 'benchmarks')
    )

    $merged = @{
        last_updated = $null
        schema_version = '1.0.0'
        sources = @{}
        models = @{}
    }

    if (-not (Test-Path -LiteralPath $BenchmarksDir -PathType Container)) {
        return $merged
    }

    $modelsFile = Join-Path $BenchmarksDir 'models.json'
    if (Test-Path -LiteralPath $modelsFile -PathType Leaf) {
        try {
            $db = Get-Content -LiteralPath $modelsFile -Raw | ConvertFrom-Json -AsHashtable
            if ($db) {
                if ($db.ContainsKey('last_updated')) { $merged['last_updated'] = $db['last_updated'] }
                if ($db.ContainsKey('schema_version')) { $merged['schema_version'] = $db['schema_version'] }
                if ($db.ContainsKey('sources')) { $merged['sources'] = Merge-ProviderOverlay -Base $merged['sources'] -Overlay $db['sources'] }
                if ($db.ContainsKey('models')) { $merged['models'] = Merge-ProviderOverlay -Base $merged['models'] -Overlay $db['models'] }
            }
        } catch {
            Write-Warning "Get-SalmonRunBenchmarkData: failed to load '$modelsFile': $_"
        }
    }

    $perModelDir = Join-Path $BenchmarksDir 'models'
    if (Test-Path -LiteralPath $perModelDir -PathType Container) {
        foreach ($file in Get-ChildItem -Path $perModelDir -Filter '*.json' -File | Sort-Object Name) {
            try {
                $modelData = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                if (-not $modelData) { continue }

                if ($modelData.ContainsKey('models')) {
                    $merged['models'] = Merge-ProviderOverlay -Base $merged['models'] -Overlay $modelData['models']
                } elseif ($modelData.ContainsKey('slug')) {
                    $merged['models'] = Merge-ProviderOverlay -Base $merged['models'] -Overlay @{ $modelData['slug'] = $modelData }
                } else {
                    $slug = $file.BaseName
                    $merged['models'] = Merge-ProviderOverlay -Base $merged['models'] -Overlay @{ $slug = $modelData }
                }
            } catch {
                Write-Warning "Get-SalmonRunBenchmarkData: failed to load per-model file '$($file.FullName)': $_"
            }
        }
    }

    return $merged
}
