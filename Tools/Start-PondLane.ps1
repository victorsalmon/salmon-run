#Requires -Version 7.0

<#
.SYNOPSIS
    Standalone child runner for a single Salmon Run pond lane.
.DESCRIPTION
    This script is spawned by Start-PondEngine for each agentic lane. It
    bootstraps the Salmon Run module environment, reconstructs a minimal
    PondContext for the lane, and runs the pond's task pipeline while
    skipping the Claim task (the parent already moved the plans into the
    lane and committed the .salmon state).
.PARAMETER TaskRoot
    Root of the Salmon task queue (e.g. ~/.salmon/Tasks).
.PARAMETER RepoDir
    Path to the Salmon-Run repository that contains the modules.
.PARAMETER PondName
    Name of the pond whose task pipeline should run.
.PARAMETER LaneId
    Id of the lane the parent reserved (e.g. lane-coder-salmon-currents-1).
.PARAMETER StreamId
    Id of the worktree stream (usually the plan namespace).
.PARAMETER StreamPath
    Path of the target git worktree the agent should work in.
.PARAMETER Namespace
    Plan namespace for the group.
.PARAMETER RepoPath
    Resolved target code repository path (usually the same as StreamPath).
.PARAMETER TimeoutMinutes
    Maximum minutes the child pipeline may run.
.PARAMETER ConfigPath
    Optional path to an orchestrator config JSON with a namespaceRepoMap.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TaskRoot,

    [Parameter(Mandatory)]
    [string]$RepoDir,

    [Parameter(Mandatory)]
    [string]$PondName,

    [Parameter(Mandatory)]
    [string]$LaneId,

    [Parameter(Mandatory)]
    [string]$StreamId,

    [Parameter(Mandatory)]
    [string]$StreamPath,

    [Parameter(Mandatory)]
    [string]$Namespace,

    [Parameter(Mandatory)]
    [string]$RepoPath,

    [Parameter(Mandatory)]
    [int]$TimeoutMinutes,

    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

function ConvertTo-GitSafeBranchName {
    param([string]$Name)
    $safe = $Name -replace '\.+', '.'
    $safe = $safe -replace '[\~^:\s\[\]\*\?\<\>\|"''`@]', '-'
    $safe = $safe -replace '_{2,}', '_'
    $safe = $safe -replace '-{2,}', '-'
    $safe = $safe.Trim('-.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'lane' }
    return $safe
}

try {
    $moduleLoader = Join-Path $RepoDir 'Modules' 'SalmonRun.ModuleLoader' 'Public' 'Initialize-InterclawEnvironment.ps1'
    if (-not (Test-Path -LiteralPath $moduleLoader)) {
        throw "Start-PondLane: module loader not found at $moduleLoader"
    }
    . $moduleLoader

    $null = Initialize-InterclawEnvironment -RepoRoot $RepoDir

    $pondEnginePsm1 = Join-Path $RepoDir 'Modules' 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psm1'
    if (-not (Test-Path -LiteralPath $pondEnginePsm1)) {
        throw "Start-PondLane: module script not found at $pondEnginePsm1"
    }
    . $pondEnginePsm1

    $ponds = Get-SalmonRunPonds
    $pond = $ponds | Where-Object { $_.Name -eq $PondName } | Select-Object -First 1
    if (-not $pond) {
        throw "Start-PondLane: pond '$PondName' not found"
    }

    $lanePath = Join-Path $TaskRoot 'Working' $LaneId
    $null = New-Item -ItemType Directory -Path $lanePath -Force -ErrorAction SilentlyContinue

    $planFiles = @(Get-ChildItem -LiteralPath $lanePath -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($planFiles.Count -eq 0) {
        throw "Start-PondLane: no plan files in lane $LaneId"
    }

    $branchName = if ($StreamId -match '^salmon-') { ConvertTo-GitSafeBranchName -Name $StreamId } else { "salmon-$(ConvertTo-GitSafeBranchName -Name $StreamId)" }

    $stream = [PondStream]::new()
    $stream.Id = $StreamId
    $stream.Branch = $branchName
    $stream.Path = $StreamPath
    $stream.Lanes = @{}
    $stream.Idle = $true

    $namespaceRepoMap = @{}
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
            if ($cfg -and $cfg['namespaceRepoMap']) {
                $namespaceRepoMap = $cfg['namespaceRepoMap']
            }
        } catch {
            Write-Verbose "Start-PondLane: could not parse config $ConfigPath : $_"
        }
    }

    $context = [PondContext]::new()
    $context.RepoDir = $RepoDir
    $context.TaskRoot = $TaskRoot
    $context.Streams = [System.Collections.ArrayList]::new()
    $null = $context.Streams.Add($stream)
    $context.ActiveStreams = @{$StreamId = $stream}
    $context.UsedNamespaces = @{$Namespace = $true}
    $context.BusyNamespaces = @{}
    $context.CrashHistory = [System.Collections.Generic.List[datetime]]::new()
    $context.Iteration = 0
    $context.Counts = $null
    $context.CurrentPond = $pond
    $context.Config = [PSCustomObject]@{
        TimeoutMinutes   = $TimeoutMinutes
        NamespaceRepoMap = $namespaceRepoMap
    }
    $context.Continue = $true
    $context.Success  = $false

    $group = [PondGroup]::new()
    $group.Namespace = $Namespace
    $group.Role = $pond.Role
    $group.Module = 'main'
    $group.Files = $planFiles
    $group.LaneId = $LaneId
    $group.StreamPath = $lanePath
    $group.Stream = $stream
    $group.RepoPath = $RepoPath

    $context.CurrentGroup = $group

    $context = Invoke-PondLanePipeline -Pond $pond -Context $context -SkipClaim

    if ($context.Success) {
        exit 0
    }

    # The pipeline finished without an exception but did not report success.
    # Ensure a failure sentinel is written so the parent can clean up.
    $failedFile = Join-Path $lanePath '.failed'
    '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
    exit 1
} catch {
    $err = $_
    try {
        $lanePath = Join-Path $TaskRoot 'Working' $LaneId
        $null = New-Item -ItemType Directory -Path $lanePath -Force -ErrorAction SilentlyContinue
        $failedFile = Join-Path $lanePath '.failed'
        '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue

        $logPath = Join-Path $lanePath 'lane-error.log'
        $log = @(
            "Start-PondLane failed for pond '$PondName' lane '$LaneId' namespace '$Namespace'",
            $err.ToString()
        ) -join "`n"
        Set-Content -LiteralPath $logPath -Value $log -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
    } catch {
        # Last-ditch effort to leave a sentinel somewhere discoverable.
        $fallback = Join-Path $TaskRoot 'Working' "$LaneId.failed"
        Set-Content -LiteralPath $fallback -Value '1' -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
    }

    exit 1
}
