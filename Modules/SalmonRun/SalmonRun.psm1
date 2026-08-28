#Requires -Version 7.0
<#
.SYNOPSIS
    Root module for the salmon-run meta-module.
.DESCRIPTION
    Imports every SalmonRun.* submodule so that a single
    `Import-Module SalmonRun` brings the whole control plane online.
    Using RequiredModules in the manifest guarantees the dependency
    order is resolved by PowerShell; this file only re-asserts the
    runtime environment bootstrap.
#>

$ErrorActionPreference = 'Stop'

$subModules = @(
    'SalmonRun.Constants',
    'SalmonRun.Paths',
    'SalmonRun.ModuleLoader',
    'SalmonRun.Core',
    'SalmonRun.Config',
    'SalmonRun.Credentials',
    'SalmonRun.Locking',
    'SalmonRun.Ports',
    'SalmonRun.Process',
    'SalmonRun.AgentLifecycle',
    'SalmonRun.PondEngine',
    'SalmonRun.Display',
    'SalmonRun.Diagnostics',
    'SalmonRun.Audit',
    'SalmonRun.AQE',
    'SalmonRun.Mermaid',
    'SalmonRun.DeployState',
    'SalmonRun.GitCloud',
    'SalmonRun.WorkflowEvents'
)

foreach ($mod in $subModules) {
    try {
        Import-Module -Name $mod -Global -Force -ErrorAction Stop
    } catch {
        Write-Warning "SalmonRun meta-module: failed to import $mod : $_"
    }
}

# Re-export the most common entry points so consumers can call them
# directly after `Import-Module SalmonRun`.
$exportCommands = @(
    'Get-SalmonRunPonds',
    'Start-PondEngine',
    'Initialize-InterclawEnvironment',
    'Get-SalmonTaskRoot'
)
foreach ($cmd in $exportCommands) {
    if (Get-Command -Name $cmd -ErrorAction SilentlyContinue) {
        Export-ModuleMember -Function $cmd
    }
}
