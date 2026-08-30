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

# Plan-family helpers so the report can distinguish the active/main plan from
# accessory/feedback plans without loading the full module.
function Get-SalmonRunPlanFamily {
    param([Parameter(Mandatory)][string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -creplace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}[-.]\d{2}[-.]\d{2}-?', ''
    if ([string]::IsNullOrWhiteSpace($base)) { return 'ungrouped' }
    return $base
}

function Get-SalmonRunPlanSequence {
    param([Parameter(Mandatory)][string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($base -match '-feedback(\d+)$') { return [int]$Matches[1].Value }
    return 0
}

function Get-SalmonRunQueueCounts {
    <#
    .SYNOPSIS
        Counts main (active) and accessory (blocked/feedback) plans per pond.
    .DESCRIPTION
        A plan family is an original plan plus all of its -feedback<N>.md
        descendants. The family member with the highest feedback sequence is the
        main plan; all other family members are accessory. The returned object has
        Active and Accessory hashtables keyed by pond name.
    #>
    param([string]$TaskRoot)

    $ponds = @('Code','Review','Audit','QA','Project','ProjectReview','Complete','Failed','Working','Manual','Intake','Archive','Paused','Investigate')
    $allItems = [System.Collections.Generic.List[psobject]]::new()

    foreach ($p in $ponds) {
        $dir = Join-Path $TaskRoot "Tasks/$p"
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($f in $files) { $allItems.Add([pscustomobject]@{ File = $f; Pond = $p }) }
    }

    $families = @{} 
    foreach ($item in $allItems) {
        $family = Get-SalmonRunPlanFamily -FileName $item.File.Name
        if (-not $families.ContainsKey($family)) { $families[$family] = [System.Collections.Generic.List[psobject]]::new() }
        $families[$family].Add($item)
    }

    $active = @{} ; $accessory = @{}
    foreach ($p in $ponds) { $active[$p] = 0; $accessory[$p] = 0 }

    foreach ($familyItems in $families.Values) {
        # Active = highest feedback sequence (the family head).  If the highest
        # sequence is shared, prefer a file whose Status is not blocked.
        $seqMap = @{}
        foreach ($item in $familyItems) {
            $seq = Get-SalmonRunPlanSequence -FileName $item.File.Name
            if (-not $seqMap.ContainsKey($seq)) { $seqMap[$seq] = [System.Collections.Generic.List[psobject]]::new() }
            $seqMap[$seq].Add($item)
        }
        $maxSeq = [int]($seqMap.Keys | Measure-Object -Maximum).Maximum
        $candidates = $seqMap[$maxSeq]
        $main = $null
        foreach ($c in $candidates) {
            $cContent = Get-Content -LiteralPath $c.File.FullName -Raw -ErrorAction SilentlyContinue
            if ($cContent -notmatch '(?im)^\*\*Status\*\*:\s*blocked\b') { $main = $c; break }
        }
        if (-not $main) { $main = $candidates | Select-Object -First 1 }

        $active[$main.Pond]++
        foreach ($item in $familyItems) {
            if ($item.File.FullName -eq $main.File.FullName) { continue }
            $accessory[$item.Pond]++
        }
    }

    return [pscustomobject]@{ Active = $active; Accessory = $accessory }
}

if ([string]::IsNullOrWhiteSpace($TaskRoot)) {
    $TaskRoot = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Join-Path $HOME '.salmon' }
}
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $TaskRoot 'Logs'
}
$null = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue

$now = Get-Date
$cutoff = $now.AddHours(-$HistoryHours)
$counts = Get-SalmonRunQueueCounts -TaskRoot $TaskRoot
$report = [ordered]@{
    ts = $now.ToString('o')
    taskRoot = $TaskRoot
    queueCounts = $counts.Active
    queueAccessoryCounts = $counts.Accessory
    queueDeltas = [ordered]@{}
    working = @()
    staleWorking = 0
    failed = @()
    completedLastPeriod = 0
    completedByNamespace = [ordered]@{}
    uniqueCompletions = 0
    forwardTransitions = 0
    backwardTransitions = 0
    cycleCount = 0
    transitionErrors = 0
    syncBacklog = 0
    syncFailures = 0
    duplicateFamilies = 0
    largestPromptBytes = 0
    usefulAgentRunRatio = 0.0
    heartbeat = @{}
    recentLogErrors = @()
    crashCount = 0
    healthy = $true
    actionRequired = @()
    summary = ''
}

$ponds = @('Code','Review','Audit','QA','Project','ProjectReview','Complete','Failed','Working','Manual','Intake','Archive','Paused')
foreach ($p in $ponds) {
    if (-not $report.queueCounts.Contains($p)) { $report.queueCounts[$p] = 0 }
    if (-not $report.queueAccessoryCounts.Contains($p)) { $report.queueAccessoryCounts[$p] = 0 }
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
    $laneDirs = Get-ChildItem -LiteralPath $workingDir -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'lane-*' -and (
            (Test-Path -LiteralPath (Join-Path $_.FullName '.lease.json') -PathType Leaf) -or
            @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.md' -File -ErrorAction SilentlyContinue).Count -gt 0
        )
    }
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

# Actionable plans that need a human or an Investigator
$actionPonds = @('Intake', 'Failed')
foreach ($p in $actionPonds) {
    $dir = Join-Path $TaskRoot "Tasks/$p"
    if (Test-Path -LiteralPath $dir) {
        $planNames = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | Select-Object -ExpandProperty Name)
        if ($planNames.Count -gt 0) {
            $report.actionRequired += [pscustomobject]@{ Pond = $p; Count = $planNames.Count; Plans = $planNames }
        }
    }
}

# Failed queue and crash evidence
$failedDir = Join-Path $TaskRoot 'Tasks/Failed'
if (Test-Path -LiteralPath $failedDir) {
    $report.failed = @(Get-ChildItem -LiteralPath $failedDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | Select-Object -ExpandProperty Name)
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

# Meaningful progress comes only from validated attempt transitions.
$eventPath = Join-Path $LogDir 'workflow-events.jsonl'; $recentEvents = @()
if (Test-Path $eventPath) { foreach ($line in Get-Content $eventPath -ErrorAction SilentlyContinue) { try { $event=$line|ConvertFrom-Json -ErrorAction Stop; $eventTs=[datetimeoffset]::MinValue; if([datetimeoffset]::TryParse([string]$event.ts,[ref]$eventTs) -and $eventTs -ge [datetimeoffset]::Now.AddMinutes(-30)){$recentEvents += $event} } catch {} } }
$transitions=@($recentEvents|Where-Object action -eq 'transition');$forward=@($transitions|Where-Object failureKind -eq 'success');$backward=@($transitions|Where-Object { $_.failureKind -ne 'success' })
$report.forwardTransitions=$forward.Count;$report.backwardTransitions=$backward.Count;$report.uniqueCompletions=@($forward|Where-Object pond -in @('QA','ProjectReview','Complete')|Select-Object -ExpandProperty planId -Unique).Count;$report.transitionErrors=@($transitions|Where-Object failureKind -eq 'engine-error').Count
$cycleGroups=@($transitions|Group-Object planId|Where-Object { $_.Count -ge 6 -and @($_.Group|Where-Object failureKind -eq 'success').Count -eq 0 });$report.cycleCount=$cycleGroups.Count;$report.usefulAgentRunRatio=if($transitions.Count -gt 0){[math]::Round($forward.Count/$transitions.Count,3)}else{0.0}
$syncDir=Join-Path $TaskRoot 'SyncOutbox';if(Test-Path $syncDir){$syncFiles=@(Get-ChildItem $syncDir -Filter '*.json' -File -ErrorAction SilentlyContinue);$report.syncBacklog=$syncFiles.Count;foreach($f in $syncFiles){try{$s=Get-Content $f.FullName -Raw|ConvertFrom-Json;$report.syncFailures += [int]$s.attempts}catch{$report.syncFailures++}}}
$packetFiles=@();foreach($pondName in @('Code','Review','Audit','QA','Project','ProjectReview','Working','Investigate')){$d=Join-Path $TaskRoot "Tasks/$pondName";if(Test-Path $d){$packetFiles+=Get-ChildItem $d -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue}}
if($packetFiles.Count -gt 0){$report.largestPromptBytes=[int64](($packetFiles|Measure-Object Length -Maximum).Maximum);$report.duplicateFamilies=@($packetFiles|Group-Object { Get-SalmonRunPlanFamily $_.Name }|Where-Object Count -gt 1).Count}
if($report.transitionErrors -gt 0 -or $report.cycleCount -gt 0 -or $report.syncFailures -ge 3 -or $report.largestPromptBytes -gt 65536 -or $report.duplicateFamilies -gt 0){$report.healthy=$false}
$executableBacklog=[int]$report.queueCounts.Code+[int]$report.queueCounts.Review+[int]$report.queueCounts.Audit+[int]$report.queueCounts.QA;if($executableBacklog -gt 0 -and $transitions.Count -ge 2 -and $report.forwardTransitions -eq 0){$report.healthy=$false}

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

# Process liveness is necessary but never sufficient for useful work.
$usefulWork = $report.forwardTransitions -gt 0
if (-not $usefulWork -and $report.working.Count -gt 0 -and ($report.staleWorking -gt 0 -or $report.heartbeat.fresh -eq $false)) { $report.healthy = $false }

function Format-QueueCount {
    param([int]$Active, [int]$Accessory)
    if ($Accessory -gt 0) { return "$Active($Accessory)" }
    return [string]$Active
}

$q = $report.queueCounts
$qa = $report.queueAccessoryCounts
$actionCount = 0
foreach ($a in $report.actionRequired) { $actionCount += $a.Count }

$report.summary = "queues=$(Format-QueueCount -Active $q.Complete -Accessory $qa.Complete)/$(Format-QueueCount -Active $q.Code -Accessory $qa.Code)/$(Format-QueueCount -Active $q.Review -Accessory $qa.Review)/$(Format-QueueCount -Active $q.Audit -Accessory $qa.Audit)/$(Format-QueueCount -Active $q.QA -Accessory $qa.QA)/$(Format-QueueCount -Active $q.Failed -Accessory $qa.Failed) forward=$($report.forwardTransitions) backward=$($report.backwardTransitions) cycles=$($report.cycleCount) sync=$($report.syncBacklog)/$($report.syncFailures) useful=$($report.usefulAgentRunRatio) healthy=$($report.healthy)"

$reportPath = Join-Path $LogDir 'health-churn-report.json'
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8 -NoNewline

# Persist the raw counts for the next delta calculation.
$countsOnly = [ordered]@{ queueCounts = $report.queueCounts; queueAccessoryCounts = $report.queueAccessoryCounts }
$countsOnly | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $historyPath -Encoding utf8 -NoNewline

# Emit the report as a single object so callers can pipe it (e.g. | Select-Object summary).
[pscustomobject]$report

