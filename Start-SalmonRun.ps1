#Requires -Version 7.0

<#
.SYNOPSIS
    Top-level runner for the salmon-run control plane.
.DESCRIPTION
    Bootstraps the Interclaw module environment, confirms the runtime task root,
    and either lists the pending work (-DryRun) or runs the pond engine (-Run).
    Runtime state is kept under ~/.salmon (or %SALMON_RUN_HOME%).
.PARAMETER Run
    Start the pond engine and process plans.
.PARAMETER DryRun
    List the pond configuration, stream count, and current queue counts without
    spawning agents. This is the default when -Run is not specified.
.PARAMETER MaxIterations
    Maximum main-loop iterations. Default 20. Use 0 to run until manually stopped.
.PARAMETER PollIntervalSeconds
    Seconds to sleep when no work is available. Default 300.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes a single agent subprocess may run. Default 30.
.PARAMETER NamespaceRepoMap
    Optional hashtable mapping plan namespace to target repo path. Overrides
    ~/.salmon/orchestrator.config.json for these namespaces.
.PARAMETER ConfigPath
    Path to an orchestrator config JSON. Defaults to ~/.salmon/orchestrator.config.json.
.EXAMPLE
    .\Start-SalmonRun.ps1 -DryRun
    Preview the queues and ponds.
.EXAMPLE
    .\Start-SalmonRun.ps1 -Run -MaxIterations 1 -PollIntervalSeconds 0
    Run a single pond-engine iteration without sleeping.
.EXAMPLE
    .\Start-SalmonRun.ps1 -Run -MaxIterations 0
    Run the pond engine continuously.
#>
[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$DryRun,
    [int]$MaxIterations = 20,
    [int]$PollIntervalSeconds = 300,
    [int]$SubprocessTimeoutMinutes = 30,
    [hashtable]$NamespaceRepoMap = @{},
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

if ($Run -and $DryRun) {
    throw "Cannot use -Run and -DryRun together."
}

# Bootstrap the module environment from the repo this script lives in.
$moduleLoader = Join-Path $PSScriptRoot 'Modules' 'SalmonRun.ModuleLoader' 'Public' 'Initialize-InterclawEnvironment.ps1'
if (-not (Test-Path $moduleLoader -PathType Leaf)) {
    throw "Start-SalmonRun: module loader not found at $moduleLoader"
}
. $moduleLoader

$repoRoot = Initialize-InterclawEnvironment -RepoRoot $PSScriptRoot
$taskRoot = Get-SalmonTaskRoot

# Build the namespace-to-repo map from an optional config file and/or the
# -NamespaceRepoMap parameter. The parameter wins over the file.
$salmonConfig = if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    $ConfigPath
} else {
    Join-Path (Get-SalmonHome) 'orchestrator.config.json'
}

$mergedMap = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $salmonConfig) {
    $cfg = Get-Content -LiteralPath $salmonConfig -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
    if ($cfg -and $cfg['namespaceRepoMap']) {
        foreach ($k in $cfg['namespaceRepoMap'].Keys) {
            $mergedMap[$k] = $cfg['namespaceRepoMap'][$k]
        }
    }
}
foreach ($k in $NamespaceRepoMap.Keys) {
    $mergedMap[$k] = $NamespaceRepoMap[$k]
}

if (-not (Test-Path $taskRoot -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $taskRoot -Force
    Write-Host "Created task root: $taskRoot" -ForegroundColor Yellow
}

# Ensure the pond engine module is available for the class types it exposes.
$ponds = Get-SalmonRunPonds

function Get-SalmonRunQueuePath {
    param([string]$Folder)
    $folder = $Folder
    if ($folder -match '^Tasks[/\\](.+)$') {
        $folder = $Matches[1]
    }
    return Join-Path $taskRoot $folder
}

if ($DryRun -or -not $Run) {
    Write-Host "Salmon Run dry run" -ForegroundColor Cyan
    Write-Host "Repo root  : $repoRoot"
    Write-Host "Task root  : $taskRoot"
    Write-Host "Pond list  :"

    $total = 0
    foreach ($pond in $ponds) {
        $pondPath = Get-SalmonRunQueuePath -Folder $pond.Folder
        $count = 0
        if (Test-Path $pondPath -PathType Container) {
            $count = (Get-ChildItem -Path $pondPath -Filter '*.md' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne '.gitkeep' } |
                Measure-Object).Count
        }
        $total += $count
        Write-Host ("  {0,-15} {1,-20} queue: {2}" -f $pond.Name, "($($pond.Folder))", $count)
    }

    Write-Host "Stream count: 1"
    Write-Host "Total queued plans: $total"
    return
}

# Record the start of a session before entering the engine.
# Write-WorkflowEvent resolves its log path from Get-SalmonRunRepoRoot; point it
# at the runtime task root so the event log stays under ~/.salmon, not the repo.
$originalRepoRoot = $env:REPO_ROOT
$env:REPO_ROOT = $taskRoot
try {
    Write-WorkflowEvent -Type 'SESSION_START' -Files @($taskRoot) -Phase 'orchestrator'
} finally {
    if ($originalRepoRoot) {
        $env:REPO_ROOT = $originalRepoRoot
    } else {
        Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue
    }
}

Write-Host "Starting Salmon Run pond engine" -ForegroundColor Cyan
Write-Host "  MaxIterations          : $MaxIterations"
Write-Host "  PollIntervalSeconds    : $PollIntervalSeconds"
Write-Host "  SubprocessTimeoutMinutes: $SubprocessTimeoutMinutes"

Start-PondEngine `
    -Ponds $ponds `
    -RepoDir $repoRoot `
    -TaskRoot $taskRoot `
    -MaxIterations $MaxIterations `
    -PollIntervalSeconds $PollIntervalSeconds `
    -SubprocessTimeoutMinutes $SubprocessTimeoutMinutes `
    -NamespaceRepoMap $mergedMap
