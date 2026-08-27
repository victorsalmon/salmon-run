#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end live provider test for salmon-run.

.DESCRIPTION
    Creates a clean temporary runtime home, drops a test plan into the Code
    queue, runs the PondEngine with a real provider executor, and waits for the
    plan to reach a terminal state. The script reports the final queue, the
    provider log, and the plan's PondLog.

.PARAMETER Provider
    Provider name to test. Defaults to `opencode`.

.PARAMETER Model
    Specific provider model. Defaults to `opencode/hy3-free`.

.PARAMETER Challenge
    Plan challenge tier. Defaults to `Daily`.

.PARAMETER RolePrompt
    Optional role override. The executor selects a default prompt if not set.

.PARAMETER RepoDir
    Directory to pass as the repository root to the provider CLI. Defaults to
    the salmon-run repo directory.

.PARAMETER RuntimeHome
    Optional explicit runtime home. If omitted, a temp directory is created.

.PARAMETER MaxIterations
    Maximum PondEngine iterations. Defaults to 30.

.PARAMETER PollIntervalSeconds
    Engine poll interval. Defaults to 0 for fast test runs.

.PARAMETER PlanTimeoutSeconds
    How long to wait for the plan to finish. Defaults to 600.

.PARAMETER KeepRuntimeHome
    If set, do not delete the temporary runtime home on exit.

.EXAMPLE
    .\scripts\Invoke-SalmonRunLiveProviderTest.ps1 -Provider opencode -Model opencode/hy3-free

.EXAMPLE
    .\scripts\Invoke-SalmonRunLiveProviderTest.ps1 -Provider opencode-go -Model opencode-go/mimo-v2.5
#>
[CmdletBinding()]
param(
    [string]$Provider = 'opencode',

    [string]$Model = 'opencode/hy3-free',

    [ValidateSet('Flash','Daily','Complex','Frontier','Local')]
    [string]$Challenge = 'Daily',

    [string]$RolePrompt = '',

    [string]$RepoDir = (Split-Path -Parent $PSScriptRoot),

    [string]$RuntimeHome = '',

    [int]$MaxIterations = 30,

    [int]$PollIntervalSeconds = 0,

    [int]$PlanTimeoutSeconds = 600,

    [switch]$KeepRuntimeHome
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}

$createdRuntimeHome = $false
if ([string]::IsNullOrWhiteSpace($RuntimeHome)) {
    $RuntimeHome = Join-Path $env:TEMP ("salmon-live-" + [Guid]::NewGuid().ToString('n').Substring(0, 8))
    $createdRuntimeHome = $true
}

$initScript = Join-Path $PSScriptRoot 'Initialize-SalmonRunTestRuntime.ps1'
$planScript = Join-Path $PSScriptRoot 'New-SalmonRunTestPlan.ps1'
$waitScript = Join-Path $PSScriptRoot 'Wait-SalmonRunPlan.ps1'

foreach ($required in @($initScript, $planScript, $waitScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required script not found: $required"
    }
}

try {
    Write-Host "Initializing runtime home at $RuntimeHome" -ForegroundColor Cyan
    & $initScript -RuntimeHome $RuntimeHome -RepoDir $RepoDir | Out-Null

    # Place a provider overlay so the engine routes the test plan to the
    # requested model without editing the repo catalog. We bump OCG/Hy3 to the
    # top of the Daily tier because opencode/hy3-free does not require a key.
    $overlay = Join-Path $RuntimeHome 'providers' 'opencode-live-test.json'
    if (-not (Test-Path $overlay)) {
        $overlayData = @{
            catalog = @{
                models = @(
                    @{
                        canonicalName = 'OCG/Hy3'
                        provider      = $Provider
                        model         = $Model
                        effort        = 'max'
                        capabilityScore = 100
                        costRule      = 'free'
                    }
                )
            }
        }
        $overlayData | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $overlay -Encoding utf8 -NoNewline
    }

    $planName = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-live-$Provider.md"
    $title = "Live $Provider test"
    $body = @"
**Model**: $Model
**Provider**: $Provider
**Expectation**: This plan should be executed by the live provider and land in Tasks/Complete.
"@
    if (-not [string]::IsNullOrWhiteSpace($RolePrompt)) {
        $body += "`n**Prompt**: $RolePrompt"
    }

    Write-Host "Creating plan $planName with challenge $Challenge" -ForegroundColor Cyan
    $plan = & $planScript -RuntimeHome $RuntimeHome -Pond 'Code' -Name $planName -Challenge $Challenge -Title $title -Body $body -Provider $Provider

    Write-Host "Starting PondEngine (max $MaxIterations iterations)" -ForegroundColor Cyan
    $taskRoot = Join-Path $RuntimeHome 'Tasks'
    $startAt = Get-Date

    $env:SALMON_RUN_HOME = $RuntimeHome
    Import-Module SalmonRun.PondEngine -Force

    Start-PondEngine -RepoDir $RepoDir -TaskRoot $taskRoot -MaxIterations $MaxIterations -PollIntervalSeconds $PollIntervalSeconds

    $elapsed = [math]::Round(((Get-Date) - $startAt).TotalSeconds, 1)
    Write-Host "PondEngine finished after $elapsed seconds" -ForegroundColor Cyan

    Write-Host "Waiting up to $PlanTimeoutSeconds seconds for $planName to complete" -ForegroundColor Cyan
    $result = & $waitScript -RuntimeHome $RuntimeHome -Name $planName -TimeoutSeconds $PlanTimeoutSeconds -PollIntervalSeconds 5 -IncludePondLog

    if ($result.TimedOut) {
        Write-Warning "Plan $planName did not reach a terminal state within $PlanTimeoutSeconds seconds."
    } else {
        Write-Host "Plan $planName finished with status: $($result.Status)" -ForegroundColor Green
    }

    # Locate the provider log for any role.
    $providerLog = Get-ChildItem -Path $taskRoot -Recurse -Filter 'opencode.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($providerLog) {
        $logText = Get-Content -LiteralPath $providerLog.FullName -Raw -ErrorAction SilentlyContinue
        if ($logText) {
            Write-Host "`nProvider log preview ($($providerLog.FullName)):`n" -ForegroundColor Cyan
            $lines = $logText -split "`n"
            $preview = $lines | Select-Object -First 30
            $preview | ForEach-Object { Write-Host $_ }
        }
    }

    # Show queue counts for the runtime home.
    $queueCounts = @('Intake','Code','Review','Audit','QA','Working','Complete','Archive','Failed') | ForEach-Object {
        $d = Join-Path $taskRoot $_
        $count = if (Test-Path $d) { (Get-ChildItem -Path $d -Filter '*.md' -File -ErrorAction SilentlyContinue).Count } else { 0 }
        [PSCustomObject]@{ Pond = $_; Count = $count }
    }

    [PSCustomObject]@{
        RuntimeHome  = $RuntimeHome
        Plan         = $plan.PlanPath
        FinalPath    = $result.PlanPath
        Status       = $result.Status
        TimedOut     = $result.TimedOut
        ElapsedSeconds = $elapsed
        QueueCounts  = $queueCounts
        PondLog      = $result.PondLog
    }
} finally {
    if ($createdRuntimeHome -and -not $KeepRuntimeHome) {
        Write-Host "Cleaning up runtime home $RuntimeHome" -ForegroundColor Gray
        if (Test-Path $RuntimeHome) {
            Remove-Item $RuntimeHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Runtime home preserved at $RuntimeHome" -ForegroundColor Gray
    }
}
