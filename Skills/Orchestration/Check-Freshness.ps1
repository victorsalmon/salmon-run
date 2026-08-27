<#
.SYNOPSIS
    Checks _freshness.json for stale observational-state entries and warns.
.DESCRIPTION
    Reads the project-root _freshness.json and compares each entry's
    verified date + expires_days against the current date. Emits warnings
    for stale entries so agents don't rely on out-of-date observations.

    Exit code: 0 (all fresh or no entries), 1 (stale entries found).
.PARAMETER RepoRoot
    Root of the ORCHESTRATOR repository. Defaults to the script's parent's parent.
.PARAMETER MaxDays
    Override the per-entry expires_days for all entries. Useful for
    ad-hoc strict checks (e.g., -MaxDays 1 to flag anything >1 day old).
.PARAMETER PassThru
    Return stale entries as objects instead of printing.
.EXAMPLE
    .\Skills\\Orchestration\Check-Freshness.ps1
    .\Skills\\Orchestration\Check-Freshness.ps1 -MaxDays 1 -PassThru
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [int]$MaxDays = -1,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$freshPath = Join-Path $RepoRoot "_freshness.json"

if (-not (Test-Path $freshPath)) {
    Write-Host "[FRESHNESS] No _freshness.json found at $freshPath — skipping check" -ForegroundColor DarkGray
    exit 0
}

$fresh = Get-Content $freshPath -Raw -Encoding utf8 | ConvertFrom-Json
$now = Get-Date
$stale = @()

foreach ($key in $fresh.entries.PSObject.Properties.Name) {
    $entry = $fresh.entries.$key
    $expiresDays = $entry.expires_days
    if ($MaxDays -ge 0) { $expiresDays = $MaxDays }

    $verified = [datetime]::ParseExact($entry.verified, "yyyy-MM-dd", $null)
    $age = ($now - $verified).TotalDays

    if ($age -gt $expiresDays) {
        $stale += [PSCustomObject]@{
            Key       = $key
            Value     = $entry.value
            Verified  = $entry.verified
            By        = $entry.by
            AgeDays   = [math]::Round($age, 1)
            ExpiresIn = $expiresDays
        }
    }
}

if ($PassThru) { return $stale }

if ($stale.Count -eq 0) {
    Write-Host "[FRESHNESS] All observational state is current ($($fresh.entries.PSObject.Properties.Name.Count) entries checked)" -ForegroundColor Green
    exit 0
}

Write-Host "`n============================================" -ForegroundColor Yellow
Write-Host "  STALE OBSERVATIONAL STATE" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  The following entries in _freshness.json have expired" -ForegroundColor Yellow
Write-Host "  and should be re-verified before relying on them:" -ForegroundColor Yellow
Write-Host ""

foreach ($s in $stale) {
    Write-Host "  [$($s.Key)]" -ForegroundColor Red
    Write-Host "    Value:    $($s.Value)" -ForegroundColor Gray
    Write-Host "    Verified: $($s.Verified) ($($s.AgeDays) days ago)" -ForegroundColor DarkYellow
    Write-Host "    By:       $($s.By)" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "  To update: edit _freshness.json and set \"verified\": \"$(Get-Date -Format 'yyyy-MM-dd')\"" -ForegroundColor Cyan
Write-Host "  To suppress: increase expires_days for the relevant entry" -ForegroundColor Cyan
Write-Host ""

exit 1
