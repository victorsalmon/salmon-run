function Get-PondExecutorRegistry {
    <#
    .SYNOPSIS
        Loads the harness defaults and model-router catalog used by the
        executor registry.
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

    return [PSCustomObject]@{
        Harness = $harness
        Catalog = $catalog
    }
}
