#Requires -Version 7.0
<#
.SYNOPSIS
    Produces a health and churn report for a Salmon Run pond engine.

.DESCRIPTION
    Reads the task queue state, Working lanes, heartbeat, and orchestrator log
    and returns a structured report.  It is meant to be called by the unattended
    runner or by an operator to distinguish process-liveness from useful work.

.PARAMETER TaskRoot
    Salmon Run task root.  Defaults to $env:SALMON_RUN_HOME or ~/.salmon.

.PARAMETER LogDir
    Directory containing orchestrator logs.  Defaults to $TaskRoot/Logs.

.PARAMETER HistoryHours
    How far back to look for completions and log errors.  Default 24.

.PARAMETER LiveStaleThresholdSeconds
    How long a live (process-still-running) working lane may be idle before it is
    considered stale.  Default 1800 (30 minutes); should be at least the engine's
    subprocess timeout.
#>
[CmdletBinding()]
param(
    [string]$TaskRoot = '',
    [string]$LogDir = '',
    [int]$HistoryHours = 24,
    [int]$LiveStaleThresholdSeconds = 1800
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($TaskRoot)) {
    $TaskRoot = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Join-Path $HOME '.salmon' }
}
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $TaskRoot 'Logs'
}
$null = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue

$now = Get-Date
$cutoff = $now.AddHours(-$HistoryHours)
$report = [ordered]@{
    ts = $now.ToString('o')
    taskRoot = $TaskRoot
    queueCounts = [ordered]@{}
    queueDeltas = [ordered]@{}
    working = @()
    staleWorking = 0
    failed = @()
    completedLastPeriod = 0
    completedByNamespace = [ordered]@{}
    heartbeat = @{}
    recentLogErrors = @()
    crashCount = 0
    healthy = $true
    summary = ''
}

$ponds = @('Code','Review','Audit','QA','Project','ProjectReview','Complete','Failed','Working','Manual','Intake','Archive','Paused')
foreach ($p in $ponds) {
    $dir = Join-Path $TaskRoot "Tasks/$p"
    $count = if (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue).Count } else { 0 }
    $report.queueCounts[$p] = $count
}

$historyPath = Join-Path $LogDir 'health-churn.json'
if (Test-Path -LiteralPath $historyPath) {
    try {
        $history = Get-Content -LiteralPath $historyPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($history -and $history.queueCounts) {
            foreach ($p in $ponds) {
                $old = if ($history.queueCounts.$null -ne $p) { $history.queueCounts.$p } else { 0 }
                $report.queueDeltas[$p] = $report.queueCounts[$p] - $old
            }
        }
    } catch { Write-Verbose "Suppressed health-report aggregation error: $_" }
}

# Heartbeat freshness
$heartbeatPath = Join-Path $LogDir 'orchestrator.heartbeat.json'
if (Test-Path -LiteralPath $heartbeatPath) {
    try {
        $hb = Get-Content -LiteralPath $heartbeatPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $hbAge = ($now - [datetime]$hb.ts).TotalSeconds
        $hbPid = $hb.pid
        $processAlive = $false
        if ($hbPid) {
            $process = Get-Process -Id $hbPid -ErrorAction SilentlyContinue
            $processAlive = $null -ne $process
        }
        $report.heartbeat = [ordered]@{
            path      = $heartbeatPath
            ts        = $hb.ts
            ageSeconds = [math]::Round($hbAge, 0)
            state     = $hb.state
            detail    = $hb.detail
            fresh     = ($hbAge -lt 90 -or $processAlive)
            processAlive = $processAlive
            pid       = $hbPid
        }
        if ($hbAge -ge 90 -and -not $processAlive) { $report.healthy = $false }
    } catch {
        $report.heartbeat = @{ present = $true; error = $_.Exception.Message }
        $report.healthy = $false
    }
} else {
    $report.heartbeat = @{ present = $false }
    $report.healthy = $false
}

# Working lanes: which are alive, which are stale, last output age
$workingDir = Join-Path $TaskRoot 'Tasks/Working'
if (Test-Path -LiteralPath $workingDir) {
    $laneDirs = Get-ChildItem -LiteralPath $workingDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'lane-*' }
    foreach ($lane in $laneDirs) {
        $pidFile = Join-Path $lane.FullName '.pid'
        $lanePid = $null
        $processAlive = $false
        $lastWrite = $lane.LastWriteTime
        if (Test-Path -LiteralPath $pidFile) {
            $pidText = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
            $null = [int]::TryParse($pidText, [ref]$lanePid)
            $process = if ($lanePid) { Get-Process -Id $lanePid -ErrorAction SilentlyContinue }
            $processAlive = $null -ne $process
        }
        # Find the most recently written file in the lane (logs, sentinels, etc.)
        $newestFile = Get-ChildItem -LiteralPath $lane.FullName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newestFile) { $lastWrite = $newestFile.LastWriteTime }
        $ageSeconds = [math]::Round(($now - $lastWrite).TotalSeconds, 0)

        $laneInfo = [ordered]@{
            name      = $lane.Name
            pid       = $lanePid
            processAlive = $processAlive
            lastWrite = $lastWrite.ToString('o')
            ageSeconds = $ageSeconds
            stale     = if ($processAlive) { $ageSeconds -gt $LiveStaleThresholdSeconds } else { $ageSeconds -gt 600 }
        }
        $report.working += $laneInfo
        if ($laneInfo.stale) { $report.staleWorking++ }
    }
}

# Failed queue and crash evidence
$failedDir = Join-Path $TaskRoot 'Tasks/Failed'
if (Test-Path -LiteralPath $failedDir) {
    $report.failed = @(Get-ChildItem -LiteralPath $failedDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

# Completions in the lookback period
$completeDir = Join-Path $TaskRoot 'Tasks/Complete'
$archiveDir  = Join-Path $TaskRoot 'Tasks/Archive'
$completedFiles = @()
foreach ($d in @($completeDir, $archiveDir)) {
    if (Test-Path -LiteralPath $d) {
        $completedFiles += Get-ChildItem -LiteralPath $d -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoff }
    }
}
$report.completedLastPeriod = $completedFiles.Count
foreach ($f in $completedFiles) {
    $ns = if ($f.Name -match '^\d{4}[-.]?\d{2}[-.]?\d{2}[-.]([^-]+)') { $Matches[1] } else { 'unknown' }
    if (-not $report.completedByNamespace.Contains($ns)) { $report.completedByNamespace[$ns] = 0 }
    $report.completedByNamespace[$ns]++
}

# Orchestrator log errors in the last 10 minutes (recent crashes, not history)
$logPath = Join-Path $LogDir 'orchestrator.log'
if (Test-Path -LiteralPath $logPath) {
    $errorLines = @(Select-String -Path $logPath -Pattern '\[(ERROR|FATAL)\]' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
    $crashCutoff = $now.AddMinutes(-10)
    $errors = @($errorLines | Where-Object {
        $tsMatch = [regex]::Match($_, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')
        if ($tsMatch.Success) {
            try { ([datetime]$tsMatch.Value) -ge $crashCutoff } catch { $false }
        } else {
            $false
        }
    } | Select-Object -Last 20)
    $report.recentLogErrors = $errors
    $report.crashCount = $errors.Count
    if ($errors.Count -gt 0) { $report.healthy = $false }
}

# Churn signal: any queue movement or completion is good; no movement with stale
# working is bad.
$deltaSum = ($report.queueDeltas.Values | Measure-Object -Sum).Sum
$usefulWork = ($deltaSum -ne 0) -or ($report.completedLastPeriod -gt 0) -or ($report.queueDeltas['Complete'] -gt 0)
if (-not $usefulWork -and $report.working.Count -gt 0 -and ($report.staleWorking -gt 0 -or $report.heartbeat.fresh -eq $false)) {
    $report.healthy = $false
}

$report.summary = "queues=$($report.queueCounts.Complete)/$($report.queueCounts.Code)/$($report.queueCounts.Review)/$($report.queueCounts.Audit)/$($report.queueCounts.QA)/$($report.queueCounts.Failed) working=$($report.working.Count) stale=$($report.staleWorking) completed+${HistoryHours}h=$($report.completedLastPeriod) healthy=$($report.healthy)"

$reportPath = Join-Path $LogDir 'health-churn-report.json'
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8 -NoNewline

# Persist the raw counts for the next delta calculation.
$countsOnly = [ordered]@{ queueCounts = $report.queueCounts }
$countsOnly | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $historyPath -Encoding utf8 -NoNewline

$report

