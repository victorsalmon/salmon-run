#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a test plan file in a salmon-run task queue.

.DESCRIPTION
    Generates a markdown plan with the required salmon-run routing headers
    and an empty **PondLog** section. The plan is placed in the requested
    pond queue under `SALMON_RUN_HOME/Tasks`.

.PARAMETER RuntimeHome
    Path to the salmon-run runtime home. Defaults to `SALMON_RUN_HOME` or
    `~/.salmon`.

.PARAMETER Pond
    Queue to place the plan in. Defaults to `Code`.

.PARAMETER Name
    Filename for the plan. Defaults to a timestamped name.

.PARAMETER Challenge
    Routing challenge tier (`Flash`, `Daily`, `Complex`, `Frontier`, `Local`).
    Defaults to `Local`.

.PARAMETER Title
    Title for the plan. Defaults to `Test plan for {Provider}`.

.PARAMETER Body
    Optional additional body text for the plan.

.PARAMETER DependsOn
    Optional dependency plan name(s).

.PARAMETER Provider
    Optional provider name for the default title.

.EXAMPLE
    .\scripts\New-SalmonRunTestPlan.ps1 -Challenge Daily -Provider opencode
#>
[CmdletBinding()]
param(
    [string]$RuntimeHome = $env:SALMON_RUN_HOME,

    [ValidateSet('Intake','Code','Review','QA','Audit','Working','Complete','Archive','Failed','Project','ProjectReview')]
    [string]$Pond = 'Code',

    [string]$Name = ("test-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".md"),

    [ValidateSet('Flash','Daily','Complex','Frontier','Local')]
    [string]$Challenge = 'Local',

    [string]$Title = '',

    [string]$Body = '',

    [string[]]$DependsOn = @(),

    [string]$Provider = 'salmon-run'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RuntimeHome)) {
    $RuntimeHome = Join-Path $HOME '.salmon'
}

$queueDir = Join-Path $RuntimeHome 'Tasks' $Pond
if (-not (Test-Path $queueDir)) {
    $null = New-Item -ItemType Directory -Path $queueDir -Force
}

$planPath = Join-Path $queueDir $Name

if ([string]::IsNullOrWhiteSpace($Title)) {
    $Title = "Test plan for $Provider"
}

$lines = @(
    "# $Title",
    '',
    '**Status**: ready',
    '**Scope**: test',
    "**Challenge**: $Challenge"
)

if ($DependsOn.Count -gt 0) {
    $lines += ("**DependsOn**: " + ($DependsOn -join ', '))
}

if (-not [string]::IsNullOrWhiteSpace($Body)) {
    $lines += ''
    $lines += $Body
}

$lines += @(
    '',
    '**PondLog**',
    '',
    '```json',
    '[]',
    '```'
)

($lines -join "`n") | Set-Content -LiteralPath $planPath -Encoding utf8 -NoNewline

Write-Host "Created plan: $planPath" -ForegroundColor Green

[PSCustomObject]@{
    PlanPath = $planPath
    RuntimeHome = $RuntimeHome
    Pond = $Pond
    Challenge = $Challenge
}
