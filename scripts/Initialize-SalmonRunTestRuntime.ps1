#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a temporary salmon-run runtime home for repeatable testing.

.DESCRIPTION
    Initializes a clean runtime home outside the source tree, creates the
    expected task queues, seeds a `.env` file and sample benchmark data if
    they are absent, copies the salmon-run modules into the runtime home,
    and sets the process-level `SALMON_RUN_HOME` and `PSModulePath`. This
    script is safe to re-run and does not modify persistent user environment
    variables.

.PARAMETER RuntimeHome
    Path to the runtime home to create. Defaults to a temp directory under
    $env:TEMP.

.PARAMETER RepoDir
    Path to the salmon-run source repository. Defaults to the parent of the
    directory containing this script.

.PARAMETER SkipModuleCopy
    If set, do not copy module trees. Use this when modules are already on
    PSModulePath.

.EXAMPLE
    .\scripts\Initialize-SalmonRunTestRuntime.ps1 -RuntimeHome C:\tmp\salmon-test
#>
[CmdletBinding()]
param(
    [string]$RuntimeHome = (Join-Path $env:TEMP ("salmon-test-" + [Guid]::NewGuid().ToString('n').Substring(0, 8))),

    [string]$RepoDir = (Split-Path -Parent $PSScriptRoot),

    [switch]$SkipModuleCopy
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}

# Create the runtime tree.
$taskDirs = @(
    'Tasks/Intake','Tasks/Code','Tasks/Review','Tasks/QA','Tasks/Audit',
    'Tasks/Working','Tasks/Complete','Tasks/Archive','Tasks/Failed',
    'Tasks/Manual','Tasks/Handoffs','Tasks/Temp','Tasks/Logs',
    'Tasks/Project','Tasks/ProjectReview','Tasks/Schedules','Tasks/Locks',
    'providers','benchmarks','benchmarks/models','cache','secrets'
)

if (-not (Test-Path $RuntimeHome)) {
    $null = New-Item -ItemType Directory -Path $RuntimeHome -Force
}

foreach ($rel in $taskDirs) {
    $d = Join-Path $RuntimeHome $rel
    if (-not (Test-Path $d)) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }
}

# Seed .env and benchmark files if missing.
$envExample = Join-Path $RepoDir 'dot-salmon.example' '.env.example'
$envDest = Join-Path $RuntimeHome '.env'
if ((Test-Path $envExample) -and -not (Test-Path $envDest)) {
    Copy-Item -Path $envExample -Destination $envDest -Force
    Write-Host "Seeded $envDest from .env.example." -ForegroundColor Yellow
}

$benchmarksExampleDir = Join-Path $RepoDir 'dot-salmon.example' 'benchmarks'
$benchmarksDestDir = Join-Path $RuntimeHome 'benchmarks'
if ((Test-Path $benchmarksExampleDir) -and (Test-Path $benchmarksDestDir)) {
    foreach ($f in @('models.schema.json','models.json')) {
        $src = Join-Path $benchmarksExampleDir $f
        $dst = Join-Path $benchmarksDestDir $f
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            Copy-Item -Path $src -Destination $dst -Force
            Write-Host "Seeded $dst from dot-salmon.example/benchmarks." -ForegroundColor Yellow
        }
    }
}

# Copy modules so the runtime home can be used as the only PSModulePath source.
if (-not $SkipModuleCopy) {
    $moduleDestination = Join-Path $RuntimeHome 'Modules'
    $null = New-Item -ItemType Directory -Path $moduleDestination -Force

    $moduleSources = @(
        (Join-Path $RepoDir 'Modules')
    )

    foreach ($src in $moduleSources) {
        if (-not (Test-Path $src)) { continue }
        foreach ($mod in Get-ChildItem -Path $src -Directory) {
            $dst = Join-Path $moduleDestination $mod.Name
            if (Test-Path $dst) {
                Remove-Item -Path $dst -Recurse -Force
            }
            Copy-Item -Path $mod.FullName -Destination $dst -Recurse -Force
        }
    }

    $pathSeparator = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }
    $current = $env:PSModulePath
    $parts = ($current -split [regex]::Escape($pathSeparator)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parts -notcontains $moduleDestination) {
        $env:PSModulePath = ($moduleDestination, ($parts -join $pathSeparator)) -join $pathSeparator
    }
}

$env:SALMON_RUN_HOME = $RuntimeHome

# Smoke test the core module.
Import-Module SalmonRun.PondEngine -Force

[PSCustomObject]@{
    RuntimeHome = $RuntimeHome
    RepoDir     = $RepoDir
    ModulesPath = Join-Path $RuntimeHome 'Modules'
}
