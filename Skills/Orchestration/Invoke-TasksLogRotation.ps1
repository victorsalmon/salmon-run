<#
.SYNOPSIS
    Rotates stale entries out of Tasks/Logs/ into a month-bucketed Archive/.
.DESCRIPTION
    `Tasks/Logs/` is the orchestrator's runtime-output home (resolved by
    Get-ReportsDir in Skills/Docker/Modules/SalmonRun.Diagnostics). It is
    blanket-gitignored (.gitignore line 39), so entries never reach the repo —
    but they accumulate on disk indefinitely: dated test reports, build-*
    directories, *-scan-*.json dumps, audit-regression output. Over weeks this
    makes the directory unscannable and wastes local disk.

    This script moves top-level entries older than -RetentionDays into
    Tasks/Logs/Archive/<YYYY-MM>/ (month-bucketed, so the archive itself stays
    browsable rather than one giant directory). It is idempotent: re-running is
    a no-op once everything stale has been archived. It never touches the
    Archive/ tree itself, never deletes (move-only), and skips any file
    currently locked by a running orchestrator job (best-effort share-deny
    probe) so concurrent agents are not disturbed.

    Note: this is local-disk hygiene only. Because Tasks/Logs/ is gitignored,
    none of this affects the repository — rotation does not produce git changes.

.PARAMETER RepoRoot
    Root of the orchestrator repository. Defaults to the parent of the
    script's own directory (i.e. the salmon-orchestrator root).
.PARAMETER RetentionDays
    Age threshold in days (by LastWriteTime). Entries older than this are
    archived. Default: 7.
.PARAMETER ArchiveDir
    Archive root, relative to RepoRoot. Default: Tasks/Logs/Archive.
.PARAMETER WhatIf
    List the entries that would be moved, without moving them. Use this to
    preview a run before committing to it.
.PARAMETER PassThru
    Return a [PSCustomObject] summary {Moved, Skipped, ArchivedTo, RunId}
    instead of (in addition to) writing to host.
.EXAMPLE
    .\Skills\\Orchestration\Invoke-TasksLogRotation.ps1 -WhatIf
    Preview what a run with the default 7-day retention would archive.
.EXAMPLE
    .\Skills\\Orchestration\Invoke-TasksLogRotation.ps1 -RetentionDays 14
    Archive entries older than 14 days into Tasks/Logs/Archive/<YYYY-MM>/.
.NOTES
    Run telemetry is appended (one JSON line per run) to
    Tasks/Logs/log-rotation-runs.jsonl, which is itself gitignored.
    Concurrency: best-effort — a file in active use by an orchestrator job is
    skipped (logged), not force-moved. This is the safe default for a fleet
    where agents write logs continuously.
#>
param(
    [string]$RepoRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [int]$RetentionDays = 7,
    [string]$ArchiveDir = "Tasks/Logs/Archive",
    [switch]$WhatIf,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$LogsRoot    = Join-Path $RepoRoot "Tasks/Logs"
$ArchiveRoot = Join-Path $RepoRoot $ArchiveDir
$TelemetryPath = Join-Path $LogsRoot "log-rotation-runs.jsonl"
$Cutoff = (Get-Date).AddDays(-$RetentionDays)
$RunId = [Guid]::NewGuid().ToString('N').Substring(0,8)
$Sw = [System.Diagnostics.Stopwatch]::StartNew()

# Streaming telemetry — append one jsonl line per event so a crash or partial
# run is diagnosable from the tail of the log, not just a final summary.
function Write-RotationEvent {
    param([string]$Action, [string]$Detail, [ValidateSet('info','warn','error')][string]$Severity = 'info', [int]$DurationMs = 0)
    $evt = [PSCustomObject]@{
        ts                = (Get-Date -Format "o")
        runId             = $RunId
        action            = $Action
        detail            = $Detail
        severity          = $Severity
        stage_duration_ms = $DurationMs
    }
    try {
        $dir = Split-Path $TelemetryPath -Parent
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        ($evt | ConvertTo-Json -Compress) | Add-Content -Path $TelemetryPath -Encoding UTF8
    } catch { Write-Warning "[log-rotation] telemetry write failed: $_" }
}
Write-RotationEvent 'rotation-start' "retentionDays=$RetentionDays whatIf=$([bool]$WhatIf)" 'info'

if (-not (Test-Path $LogsRoot)) {
    Write-RotationEvent 'rotation-noop' "Tasks/Logs/ not found at $LogsRoot" 'warn'
    Write-Host "[log-rotation] Tasks/Logs/ not found at $LogsRoot — nothing to rotate."
    if ($PassThru) { return [PSCustomObject]@{ Moved = 0; Skipped = 0; ArchivedTo = $ArchiveRoot; RunId = $RunId } }
    exit 0
}

# Enumerate top-level entries ONLY (not recursive — Archive/ is a sibling and
# would be caught by a recursive scan; we also exclude it explicitly by name).
$entries = Get-ChildItem -Path $LogsRoot -Force | Where-Object { $_.Name -ne "Archive" }

$candidates = @()
$skipped    = @()
$moved      = @()

foreach ($entry in $entries) {
    if ($entry.LastWriteTime -ge $cutoff) { continue }   # too young

    # Best-effort lock probe: try to open with share-deny. If a running job
    # holds the file, the open fails and we skip rather than disturb it.
    if (-not $entry.PSIsContainer) {
        try {
            $fs = [System.IO.File]::Open($entry.FullName, 'Open', 'Read', 'None')
            $fs.Close(); $fs.Dispose()
        } catch {
            $skipped += $entry.Name
            Write-RotationEvent 'entry-skipped-locked' $entry.Name 'warn'
            continue
        }
    }

    $candidates += $entry
}

if ($candidates.Count -eq 0) {
    Write-RotationEvent 'rotation-noop' "no entries older than $RetentionDays days; skipped=$($skipped.Count)" 'info'
    Write-Host "[log-rotation] No entries older than $RetentionDays days to archive."
    if ($PassThru) { return [PSCustomObject]@{ Moved = 0; Skipped = $skipped.Count; ArchivedTo = $ArchiveRoot; RunId = $RunId } }
    exit 0
}

if ($WhatIf) {
    Write-RotationEvent 'whatif-candidates' "$($candidates.Count) entries would be archived; skipped=$($skipped.Count)" 'info'
    Write-Host "[log-rotation] WhatIf: would archive $($candidates.Count) entries older than $RetentionDays days:" -ForegroundColor Cyan
    foreach ($c in $candidates) {
        Write-Host "  $($c.LastWriteTime.ToString('yyyy-MM-dd'))  $($c.Name)" -ForegroundColor Gray
    }
    if ($skipped.Count -gt 0) {
        Write-Host "[log-rotation] WhatIf: also skipped $($skipped.Count) locked entries:" -ForegroundColor Yellow
        $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
    }
    $summary = [PSCustomObject]@{
        timestamp     = (Get-Date -Format "o")
        runId         = $RunId
        retentionDays = $RetentionDays
        moved         = 0
        skipped       = $skipped.Count
        archivedTo    = $ArchiveRoot
        wallClockMs   = 0
        whatIf        = $true
        candidatesListed = $candidates.Count
    }
    try { $summary | ConvertTo-Json -Compress | Add-Content -Path $TelemetryPath -Encoding UTF8 } catch {}
    if ($PassThru) { return $summary }
    exit 0
}

# Real run: month-bucket each candidate into Archive/<YYYY-MM>/.
foreach ($entry in $candidates) {
    $monthBucket = $entry.LastWriteTime.ToString("yyyy-MM")
    $dest = Join-Path $ArchiveRoot $monthBucket
    if (-not (Test-Path $dest)) { $null = New-Item -ItemType Directory -Path $dest -Force }

    try {
        Move-Item -Path $entry.FullName -Destination $dest -Force -ErrorAction Stop
        $moved += $entry.Name
        Write-RotationEvent 'entry-archived' "$($entry.Name) -> Archive/$monthBucket/" 'info'
    } catch {
        # Move failed (likely a race — file got locked between probe and move).
        # Skip it; it'll be retried next run. Do not abort the whole rotation.
        $skipped += $entry.Name
        Write-RotationEvent 'entry-move-failed' "$($entry.Name): $_" 'warn'
    }
}

$Sw.Stop()
Write-RotationEvent 'rotation-complete' "moved=$($moved.Count) skipped=$($skipped.Count) wallClockMs=$($Sw.ElapsedMilliseconds)" 'info' ([int]$Sw.ElapsedMilliseconds)

Write-Host "[log-rotation] Archived $($moved.Count) entries to $ArchiveRoot/<YYYY-MM>/ (skipped $($skipped.Count) locked)." -ForegroundColor Green
if ($PassThru) {
    return [PSCustomObject]@{
        timestamp     = (Get-Date -Format "o")
        runId         = $RunId
        retentionDays = $RetentionDays
        moved         = $moved.Count
        skipped       = $skipped.Count
        archivedTo    = $ArchiveRoot
        wallClockMs   = $Sw.ElapsedMilliseconds
        whatIf        = $false
    }
}
