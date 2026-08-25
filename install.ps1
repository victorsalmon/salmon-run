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
    'cache',
    'secrets'
)

foreach ($rel in $taskDirs) {
    $d = Join-Path $RuntimeHome $rel
    if (-not (Test-Path $d)) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }
}

# Persist SALMON_RUN_HOME for the current user
[Environment]::SetEnvironmentVariable('SALMON_RUN_HOME', $RuntimeHome, 'User')
$env:SALMON_RUN_HOME = $RuntimeHome

if (-not (Test-Path $InstallPath)) {
    $null = New-Item -ItemType Directory -Path $InstallPath -Force
}

Write-Host "Installing salmon-run to $InstallPath" -ForegroundColor Green
Write-Host "Runtime home (task queues, logs, cache, secrets) set to $RuntimeHome" -ForegroundColor Green

# Module copy and path wiring will be added once the public mirror projection is complete.
Write-Host "Installer stub complete." -ForegroundColor Green
