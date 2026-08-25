<#
.SYNOPSIS
    Bootstrap the Interclaw module environment: resolves repo root, configures PSModulePath, imports Core.
.DESCRIPTION
    Adds Skills/Docker/Modules to PSModulePath, imports SalmonRun.Core (which provides
    Import-InterclawModule and other core functions via transitive module loading),
    and returns the resolved repo root path. Safe to call multiple times — idempotent.
.PARAMETER RepoRoot
    Optional explicit repo root. If not provided, auto-detected by walking up from
    the module directory looking for AGENTS.md or .git sentinels.
.OUTPUTS
    System.String. The resolved repo root path.
.EXAMPLE
    Initialize-InterclawEnvironment
    Auto-detect repo root and bootstrap modules.
.EXAMPLE
    Initialize-InterclawEnvironment -RepoRoot "C:\Users\me\salmon-run"
    Bootstrap modules using an explicit repo root path.
.NOTES
    File: Initialize-InterclawEnvironment.ps1
    Requires: PowerShell 7.0+
    See-also: Import-InterclawModule
#>
function Initialize-InterclawEnvironment {
    [OutputType([string])]
    param(
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $current = $PSScriptRoot
        while ($current -and -not (
            (Test-Path (Join-Path $current "AGENTS.md") -PathType Leaf) -or
            (Test-Path (Join-Path $current ".git") -PathType Container)
        )) {
            $parent = Split-Path $current -Parent
            if ($parent -eq $current) { break }
            $current = $parent
        }
        $RepoRoot = $current
    }

    # Orchestrator-core modules live under Orchestrator/Modules;
    # Docker-infrastructure modules remain under Skills/Docker/Modules. Both roots
    # are registered so cross-root dependencies (e.g. Core -> Paths) still resolve.
    $__moduleRoots = @(
        (Join-Path $RepoRoot "Orchestrator" "Modules"),
        (Join-Path $RepoRoot "Skills" "Bookkeeping" "handlers"),
        (Join-Path $RepoRoot "Skills" "Docker" "Modules")
    )
    foreach ($__root in $__moduleRoots) {
        if ($env:PSModulePath -notlike "*$__root*") {
            $env:PSModulePath = "$__root$([System.IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    if (-not (Get-Module SalmonRun.Core)) {
        $__ocCorePsd1 = Join-Path $__moduleRoots[0] "SalmonRun.Core" "SalmonRun.Core.psd1"
        if (-not (Test-Path $__ocCorePsd1)) {
            $__ocCorePsd1 = Join-Path $__moduleRoots[1] "SalmonRun.Core" "SalmonRun.Core.psd1"
        }
        Import-Module -Name $__ocCorePsd1 -Force -DisableNameChecking
    }

    return $RepoRoot
}
