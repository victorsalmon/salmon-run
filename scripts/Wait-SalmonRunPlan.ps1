#Requires -Version 7.0
<#
.SYNOPSIS
    Waits for a salmon-run plan to reach a terminal state.

.DESCRIPTION
    Polls the runtime home task queues and returns when the named plan file
    appears in `Complete`, `Archive`, or `Failed`.

.PARAMETER RuntimeHome
    Path to the salmon-run runtime home. Defaults to `SALMON_RUN_HOME` or
    `~/.salmon`.

.PARAMETER Name
    The plan filename (e.g. `test-20260826-123456.md`).

.PARAMETER TimeoutSeconds
    Maximum time to wait. Defaults to 300.

.PARAMETER PollIntervalSeconds
    Seconds between checks. Defaults to 5.

.PARAMETER IncludePondLog
    If set, return the plan's PondLog entries as well.

.EXAMPLE
    .\scripts\Wait-SalmonRunPlan.ps1 -Name test-20260826-123456.md -TimeoutSeconds 120
#>
[CmdletBinding()]
param(
    [string]$RuntimeHome = $env:SALMON_RUN_HOME,

    [Parameter(Mandatory)]
    [string]$Name,

    [int]$TimeoutSeconds = 300,

    [int]$PollIntervalSeconds = 5,

    [switch]$IncludePondLog
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RuntimeHome)) {
    $RuntimeHome = Join-Path $HOME '.salmon'
}

$terminalPonds = @('Complete','Archive','Failed')
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$foundPath = $null
$status = 'unknown'

while ((Get-Date) -lt $deadline) {
    foreach ($pond in $terminalPonds) {
        $candidate = Join-Path $RuntimeHome 'Tasks' $pond $Name
        if (Test-Path -LiteralPath $candidate) {
            $foundPath = $candidate
            $status = $pond.ToLowerInvariant()
            break
        }
    }
    if ($foundPath) { break }
    Start-Sleep -Seconds $PollIntervalSeconds
}

if (-not $foundPath) {
    $status = 'timeout'
    $foundPath = Join-Path $RuntimeHome 'Tasks' 'Code' $Name
    if (-not (Test-Path $foundPath)) {
        $foundPath = Join-Path $RuntimeHome 'Tasks' 'Working' $Name
    }
}

$result = [PSCustomObject]@{
    PlanPath = $foundPath
    Status   = $status
    TimedOut = ($status -eq 'timeout')
}

if ($IncludePondLog -and $foundPath -and (Test-Path $foundPath)) {
    $module = Get-Module SalmonRun.PondEngine -ErrorAction SilentlyContinue
    if (-not $module) {
        $modPath = Join-Path $RuntimeHome 'Modules' 'SalmonRun.PondEngine'
        if (Test-Path $modPath) {
            $env:PSModulePath = $env:PSModulePath + ';' + (Join-Path $RuntimeHome 'Modules')
            Import-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
        }
    }
    try {
        $result | Add-Member -NotePropertyName PondLog -NotePropertyValue (Get-PlanPondLog -PlanPath $foundPath) -Force
    } catch {
        $result | Add-Member -NotePropertyName PondLogError -NotePropertyValue $_.Exception.Message -Force
    }
}

return $result
