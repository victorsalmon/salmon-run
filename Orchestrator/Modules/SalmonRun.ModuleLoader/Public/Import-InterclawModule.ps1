<#
.SYNOPSIS
    Imports an Interclaw module by name, discovering it from the Modules directory.
.DESCRIPTION
    Resolves the module path under Skills/Docker/Modules/Interclaw.<Name> and
    imports via the .psd1 manifest if found, or dot-sources the .ps1 file as
    a fallback. Appends the Modules directory to PSModulePath if not already
    present. Throws if neither file exists.
.PARAMETER Name
    The module name segment after Interclaw. (e.g. "Core", "Config", "Deploy").
.OUTPUTS
    None. The module functions are imported into the Global scope.
#>
function Import-InterclawModule {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$ModulesDir
    )
    $moduleName = "Interclaw.$Name"

    # Resolve module roots: an explicit -ModulesDir wins; otherwise search the
    # orchestrator-core root first, then the Docker-infrastructure root, so
    # moved modules and their Docker-resident dependencies both resolve.
    $moduleRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($ModulesDir)) {
        $moduleRoots = @($ModulesDir)
    } else {
        $repoRoot = Get-InterclawRepoRoot
        $moduleRoots = @(
            (Join-Path $repoRoot "Skills" "Orchestrator" "Salmon" "Modules"),
            (Join-Path $repoRoot "Skills" "Docker" "Modules")
        )
    }

    foreach ($__root in $moduleRoots) {
        if ($env:PSModulePath -notlike "*$__root*") {
            $env:PSModulePath = "$__root$([System.IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    $moduleDir = $null
    foreach ($__root in $moduleRoots) {
        $__candidate = Join-Path $__root $moduleName
        if (Test-Path $__candidate) { $moduleDir = $__candidate; break }
    }
    if (-not $moduleDir) {
        throw "Module $moduleName not found under: $($moduleRoots -join ', ')"
    }

    $psd1 = Join-Path $moduleDir "$moduleName.psd1"
    if (Test-Path $psd1) {
        Import-Module -Name $psd1 -Force -DisableNameChecking -Scope Global
    } else {
        $ps1 = Join-Path $moduleDir "$moduleName.ps1"
        if (Test-Path $ps1) {
            . $ps1
        } else {
            throw "Module $moduleName not found at $moduleDir"
        }
    }
}
