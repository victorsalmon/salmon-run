#Requires -Version 7.0

Set-StrictMode -Off

. $PSScriptRoot\SalmonRun.Core.State.ps1

# Ensure prerequisite modules are loaded before Ports.ps1 (which calls Write-SetupLog and Get-SalmonRunRepoRoot at module scope)
$__coreRepoRoot = if (-not [string]::IsNullOrWhiteSpace($env:REPO_ROOT)) { $env:REPO_ROOT } else { $PSScriptRoot }
if (-not (Test-Path (Join-Path $__coreRepoRoot 'AGENTS.md')) -and -not (Test-Path (Join-Path $__coreRepoRoot '.git'))) {
    $walk = $PSScriptRoot
    while ($walk -and (Split-Path $walk -Leaf) -ne 'salmon-orchestrator' -and -not (Test-Path (Join-Path $walk 'AGENTS.md'))) {
        $parent = Split-Path $walk -Parent
        if ($parent -eq $walk) { break }
        $walk = $parent
    }
    if ($walk -and ((Split-Path $walk -Leaf) -eq 'salmon-orchestrator' -or (Test-Path (Join-Path $walk 'AGENTS.md')))) {
        $__coreRepoRoot = $walk
    } else {
        $__coreRepoRoot = $PSScriptRoot
    }
}
$__coreModuleDirs = @(
    (Join-Path $__coreRepoRoot 'Modules')
)
function Find-SalmonRunModuleData {
    param([string]$Name, [string]$Extension = '.psd1')
    # First, search the module directories derived from the repo root.
    foreach ($__dir in $__coreModuleDirs) {
        $__p = Join-Path $__dir $Name "$Name$Extension"
        if (Test-Path $__p) { return $__p }
    }
    # Fallback: search the live PSModulePath so container layouts work even
    # when the repo root is not named 'salmon-orchestrator'.
    $sep = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }
    foreach ($__dir in ($env:PSModulePath -split [regex]::Escape($sep) | Where-Object { $_ })) {
        $__p = Join-Path $__dir $Name "$Name$Extension"
        if (Test-Path $__p) { return $__p }
    }
    throw "SalmonRun module data not found: $Name$Extension"
}
if (-not (Get-Module SalmonRun.Paths)) {
    Import-Module -Name (Find-SalmonRunModuleData -Name 'SalmonRun.Paths') -Force -DisableNameChecking -Scope Global
}
if (-not (Get-Module SalmonRun.Diagnostics)) {
    Import-Module -Name (Find-SalmonRunModuleData -Name 'SalmonRun.Diagnostics') -Force -DisableNameChecking -Scope Global
}

# Source Private/*.ps1 files (internal helpers)
$__corePrivatePath = Join-Path $PSScriptRoot 'Private'
if (Test-Path $__corePrivatePath) {
    foreach ($f in Get-ChildItem -Path $__corePrivatePath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

# Load SalmonRun.Locking so its functions are available through Core's facade
if (-not (Get-Module SalmonRun.Locking)) {
    Import-Module -Name (Find-SalmonRunModuleData -Name 'SalmonRun.Locking') -Force -DisableNameChecking -Scope Global
}

# Source Public/*.ps1 files so declared FunctionsToExport are actually loaded when
# this file is dot-sourced (e.g. by tests). The .psm1 loader handles this for the
# Import-Module path; the .ps1 loader handles it for the dot-source path.
$__corePublicPath = Join-Path $PSScriptRoot 'Public'
if (Test-Path $__corePublicPath) {
    foreach ($f in Get-ChildItem -Path $__corePublicPath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

Export-ModuleMember -Function @(
    'Assert-DockerfileCopyPaths',
    'Convert-PidSafe',
    'Get-BackoffDelay',
    'Invoke-AgentPollingLoop',
    'Invoke-DockerWithLogging',
    'New-CryptographicToken',
    'Write-AtomicFile',
    'Write-AtomicJson',
    'Find-SalmonRunModuleData'
)

# Load Ports after Private/Public so any deferred-load issues are isolated
. (Find-SalmonRunModuleData -Name 'SalmonRun.Ports' -Extension '.ps1')

<#
.SYNOPSIS
    SalmonRun.Core -- shared functions for setup logging, secret retrieval, and Docker operations.
.DESCRIPTION
    Dot-sourced by all wrapper scripts and 0setup.ps1. Provides Write-SetupLog for
    timestamped logging, pull-per-need secret retrieval from AWS Secrets Manager, .env file
    loading, and Docker Swarm secret rotation. The log path is configured via the
    SALMONRUN_SETUP_LOG environment variable.
#>
# Error accumulator and checkpoints are in SalmonRun.DeployState (forwarded via aliases)

# Backward-compat aliases — defined in SalmonRun.Locking now; these ensure
# the aliases are still available when importing Core without explicit Locking import.
# (Locking is loaded via RequiredModules above, so its aliases are in scope.)

Set-Alias -Name 'Find-InterclawModuleData' -Value 'Find-SalmonRunModuleData'
Export-ModuleMember -Alias 'Find-InterclawModuleData'

