#Requires -Version 7.0
<#
.SYNOPSIS
    Single-command installer for the salmon-run public package.
.DESCRIPTION
    Verifies PowerShell 7+, creates the user runtime home at ~/.salmon,
    installs the core modules into the current user's PSModulePath, and
    wires SALMON_RUN_HOME. Safe to re-run.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $HOME 'salmon-run'),
    [string]$RuntimeHome = (Join-Path $HOME '.salmon')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}

# Ensure runtime home exists outside the source repo
if (-not (Test-Path $RuntimeHome)) {
    $null = New-Item -ItemType Directory -Path $RuntimeHome -Force
}

$taskDirs = @(
    'Tasks/Intake',
    'Tasks/Code',
    'Tasks/Review',
    'Tasks/QA',
    'Tasks/Audit',
    'Tasks/Working',
    'Tasks/Complete',
    'Tasks/Archive',
    'Tasks/Failed',
    'Tasks/Manual',
    'Tasks/Handoffs',
    'Tasks/Temp',
    'Tasks/Logs',
    'Tasks/Project',
    'Tasks/ProjectReview',
    'Tasks/Schedules',
    'Tasks/Locks',
    'cache',
    'secrets'
)

foreach ($rel in $taskDirs) {
    $d = Join-Path $RuntimeHome $rel
    if (-not (Test-Path $d)) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }
}

# Seed an .env file for credential redirects if one does not already exist
$envExample = Join-Path $PSScriptRoot 'dot-salmon.example' '.env.example'
$envDest = Join-Path $RuntimeHome '.env'
if ((Test-Path $envExample) -and -not (Test-Path $envDest)) {
    Copy-Item -Path $envExample -Destination $envDest -Force
    Write-Host "Seeded $envDest from .env.example; edit it with your credential redirects." -ForegroundColor Yellow
}

# Persist SALMON_RUN_HOME for the current user
[Environment]::SetEnvironmentVariable('SALMON_RUN_HOME', $RuntimeHome, 'User')
$env:SALMON_RUN_HOME = $RuntimeHome

if (-not (Test-Path $InstallPath)) {
    $null = New-Item -ItemType Directory -Path $InstallPath -Force
}

Write-Host "Installing salmon-run to $InstallPath" -ForegroundColor Green
Write-Host "Runtime home (task queues, logs, cache, secrets) set to $RuntimeHome" -ForegroundColor Green

# Copy module trees into the runtime home so they are on the user PSModulePath.
$moduleDestination = Join-Path $RuntimeHome 'Modules'
$null = New-Item -ItemType Directory -Path $moduleDestination -Force

$moduleSources = @(
    (Join-Path $PSScriptRoot 'Orchestrator' 'Modules'),
    (Join-Path $PSScriptRoot 'Skills' 'Docker' 'Modules')
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

# Ensure the runtime modules directory is on the current and persistent user PSModulePath.
$pathSeparator = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }

$userPath = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
$userParts = ($userPath -split [regex]::Escape($pathSeparator)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($userParts -notcontains $moduleDestination) {
    $userPath = ($moduleDestination, ($userParts -join $pathSeparator)) -join $pathSeparator
    [Environment]::SetEnvironmentVariable('PSModulePath', $userPath, 'User')
}

$processParts = ($env:PSModulePath -split [regex]::Escape($pathSeparator)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($processParts -notcontains $moduleDestination) {
    $env:PSModulePath = ($moduleDestination, ($processParts -join $pathSeparator)) -join $pathSeparator
}

# Quick smoke test that the pond engine is importable from the installed tree.
try {
    Import-Module SalmonRun.PondEngine -Force -ErrorAction Stop
    $pondEngineCommand = Get-Command Start-PondEngine -ErrorAction Stop
    Write-Host "Pond engine import OK: $($pondEngineCommand.Source)" -ForegroundColor Green
} catch {
    throw "salmon-run modules could not be imported after installation: $_"
}

Write-Host "Installation complete. Run 'Start-PondEngine -?' for available options." -ForegroundColor Green
