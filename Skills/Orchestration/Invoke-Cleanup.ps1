<#
.SYNOPSIS
    Post-session garbage collection for stale generated artifacts.
.DESCRIPTION
    Scans known locations for stale artifacts — Zoho CSVs with 0
    transactions, orphaned PID/heartbeat files from dead agents,
    opencode DB backups, old image build logs, orphan volume backups,
    stale orchestrator reports, and root-level temp files. Dry-run by
    default; use -Apply to delete.

    Exit code: 0 (all clean or nothing found), 1 (stale artifacts
    found in dry-run mode).
.PARAMETER RepoRoot
    Root of the ORCHESTRATOR repository. Defaults to script's parent's parent.
.PARAMETER BooksRoot
    Root of the intersite-docs bookkeeping tree. Defaults to
    $env:USERPROFILE\intersite-docs\Taxes and Bookkeeping.
.PARAMETER Apply
    Actually delete stale artifacts. Default is dry-run (report only).
.PARAMETER PassThru
    Return stale-file objects instead of printing.
.EXAMPLE
    .\Skills\\Orchestration\Invoke-Cleanup.ps1
    .\Skills\\Orchestration\Invoke-Cleanup.ps1 -Apply
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [string]$BooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [switch]$Apply,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$findings = @()

# ── Pattern 1: Zoho CSVs with 0 transactions ──────────────────────
$zohoDirs = @()
foreach ($org in @("intersite-consulting", "room-rentals")) {
    $bankDir = "$BooksRoot\$org"
    if (-not (Test-Path $bankDir)) { continue }
    $subDirs = Get-ChildItem -Path $bankDir -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue
    foreach ($d in $subDirs) {
        if ($d.Name -match "Bank Statements|bank statements") {
            $zohoDirs += Get-ChildItem -Path $d.FullName -Directory -ErrorAction SilentlyContinue
        }
    }
    # Also check 2026 Bank Statements directly
    $statementsDir = "$bankDir\2026 Bank Statements"
    if (Test-Path $statementsDir) {
        $zohoDirs += Get-ChildItem -Path $statementsDir -Directory -ErrorAction SilentlyContinue
    }
    $statementsDir2 = "$bankDir\2026 Filing\2026 Bank Statements"
    if (Test-Path $statementsDir2) {
        $zohoDirs += Get-ChildItem -Path $statementsDir2 -Directory -ErrorAction SilentlyContinue
    }
}

$zohoDirs = $zohoDirs | Select-Object -Unique
foreach ($dir in $zohoDirs) {
    $csvFiles = Get-ChildItem -Path $dir.FullName -Filter "*Zoho.csv" -ErrorAction SilentlyContinue
    foreach ($f in $csvFiles) {
        $header = Get-Content $f.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        if ($header -match "# Transactions:\s*0\s*$") {
            $findings += [PSCustomObject]@{
                Path     = $f.FullName
                Pattern  = "zoho-csv-zero-txns"
                Size     = $f.Length
                Modified = $f.LastWriteTime
                Reason   = "Zoho CSV with 0 transactions — stale from an earlier naming convention or account pre-Plaid"
            }
        }
    }
}

# ── Pattern 2: Orphaned agent PID files (no running process) ──────
$agentDir = Join-Path $RepoRoot "Tasks/Logs/agents"
if (Test-Path $agentDir) {
    $pidFiles = Get-ChildItem -Path $agentDir -Filter "*.pid" -ErrorAction SilentlyContinue
    foreach ($pf in $pidFiles) {
        $processId = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
        if ($processId) {
            $processId = $processId.Trim()
            $alive = $false
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) { $alive = $true }
            } catch {
                Write-Host "  [CLEANUP] Failed to query process ${processId}: $_" -ForegroundColor DarkGray
            }
            if (-not $alive) {
                $hbPath = [System.IO.Path]::ChangeExtension($pf.FullName, ".heartbeat")
                $hbAge = ""
                if (Test-Path $hbPath) {
                    $hbContent = Get-Content $hbPath -Raw -ErrorAction SilentlyContinue
                    if ($hbContent) {
                        try {
                            $hbDt = [datetime]::Parse($hbContent.Trim())
                            $hbAge = " (last heartbeat: $((Get-Date - $hbDt).TotalHours.ToString('0.0'))h ago)"
                        } catch {
                            Write-Host "  [CLEANUP] Failed to parse heartbeat for $($pf.BaseName): $_" -ForegroundColor DarkGray
                        }
                    }
                }
                $findings += [PSCustomObject]@{
                    Path     = $pf.FullName
                    Pattern  = "orphaned-agent-pid"
                    Size     = $pf.Length
                    Modified = $pf.LastWriteTime
                    Reason   = "Orphaned PID file for dead agent PID $processId$hbAge"
                }
            }
        }
    }
}

# ── Pattern 3: Stale build logs and backup directories ────────────
$logsDir = Join-Path $RepoRoot "Tasks/Logs"
if (Test-Path $logsDir) {
    # Pattern 3a: opencode-db-backup-* — large SQLite DB dumps
    $backupDirs = Get-ChildItem -Path $logsDir -Directory -Filter "opencode-db-backup-*" -ErrorAction SilentlyContinue
    foreach ($d in $backupDirs) {
        $sizeBytes = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $findings += [PSCustomObject]@{
            Path     = $d.FullName
            Pattern  = "stale-db-backup"
            Size     = $sizeBytes
            Modified = $d.LastWriteTime
            Reason   = "Stale opencode DB backup — keep only the latest, delete older ones"
        }
    }

    # Pattern 3b: build-* and build-preflight-* — old image build logs
    $buildDirPatterns = @("build-*", "build-preflight-*")
    foreach ($pattern in $buildDirPatterns) {
        $dirs = Get-ChildItem -Path $logsDir -Directory -Filter $pattern -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $sizeBytes = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $findings += [PSCustomObject]@{
                Path     = $d.FullName
                Pattern  = "stale-build-log"
                Size     = $sizeBytes
                Modified = $d.LastWriteTime
                Reason   = "Stale image build log directory — safe to delete after deploy"
            }
        }
    }

    # Pattern 3c: pre-apply-orphans-backup — orphan cleanup backups
    $orphanDir = Join-Path $logsDir "pre-apply-orphans-backup"
    if (Test-Path $orphanDir) {
        $sizeBytes = (Get-ChildItem $orphanDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $findings += [PSCustomObject]@{
            Path     = $orphanDir
            Pattern  = "stale-orphan-backup"
            Size     = $sizeBytes
            Modified = (Get-Item $orphanDir).LastWriteTime
            Reason   = "Pre-apply orphan volume backup — safe to delete after volume fix"
        }
    }

    # Pattern 3d: stale-orchestrator-reports — old orchestrator crash reports
    $staleOrchDir = Join-Path $logsDir "stale-orchestrator-reports"
    if (Test-Path $staleOrchDir) {
        $sizeBytes = (Get-ChildItem $staleOrchDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $findings += [PSCustomObject]@{
            Path     = $staleOrchDir
            Pattern  = "stale-orch-report"
            Size     = $sizeBytes
            Modified = (Get-Item $staleOrchDir).LastWriteTime
            Reason   = "Stale orchestrator crash reports from previous agent sessions"
        }
    }
}

# ── Pattern 4: Root-level temp artifacts ──────────────────────────
$rootPatterns = @(
    @{ Name = "stderr.txt"; Reason = "Root-level stderr capture from a previous session" },
    @{ Name = "stdout.txt"; Reason = "Root-level stdout capture from a previous session" },
    @{ Name = ".session-start.txt"; Reason = "Session timing marker from a previous agent" }
)
foreach ($p in $rootPatterns) {
    $fp = Join-Path $RepoRoot $p.Name
    if (Test-Path $fp) {
        $fi = Get-Item $fp
        $findings += [PSCustomObject]@{
            Path     = $fp
            Pattern  = "root-temp-artifact"
            Size     = $fi.Length
            Modified = $fi.LastWriteTime
            Reason   = $p.Reason
        }
    }
}

# ── Report ────────────────────────────────────────────────────────
if ($PassThru) { return $findings }

if ($findings.Count -eq 0) {
    Write-Host "[CLEANUP] No stale artifacts found" -ForegroundColor Green
    exit 0
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  STALE ARTIFACTS FOUND" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
foreach ($f in $findings) {
    $label = "  [$($f.Pattern)]"
    Write-Host "$label $($f.Path)" -ForegroundColor Yellow
    Write-Host "             $($f.Reason)" -ForegroundColor Gray
    if ($f.Size -gt 0) {
        Write-Host "             $($f.Size) bytes | modified $($f.Modified)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($Apply) {
    foreach ($f in $findings) {
        try {
            Remove-Item -Path $f.Path -Force -ErrorAction Stop
            Write-Host "  [DELETED] $($f.Path)" -ForegroundColor Red
        } catch {
            Write-Host "  [FAILED]  $($f.Path): $_" -ForegroundColor Red
        }
    }
    Write-Host "`n  $($findings.Count) artifact(s) removed." -ForegroundColor Cyan
    exit 0
}

Write-Host "  Run with -Apply to delete these artifacts." -ForegroundColor Cyan
exit 1
