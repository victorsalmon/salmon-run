<#
.SYNOPSIS
    Reconcile manifest status flags (archived/promoted) with the actual filesystem location of each file.

.DESCRIPTION
    [Used by: Skills/Bookkeeping/processing/orphan-reconciliation.md]
    [Pester tests: Skills/Docker/Tests/Bookkeeper.OrphanReconciliation.Tests.ps1]

    Stage 2 of the two-stage orphan reconciliation workflow (paired with
    Resolve-OrphanReceipts.ps1 for Stage 1). Indexes the receipts tree, then
    aligns the manifest's status/account fields with the actual filesystem
    location of each file. Idempotent — second run shows 0 changes.

    After a Resolve-OrphanReceipts.ps1 -Apply pass, the manifest should show files in their claimed
    locations (_orphans/archived/ for archived, per-account dirs for promoted). If drift has occurred
    (e.g., the apply run failed silently, or a downstream process reclassified files), this script
    sweeps the manifest to reflect reality: for each archived/promoted row, find the file in the
    receipts tree and set status + account to match the actual location.

    Status transitions:
      - archived row, file in _orphans/archived/          → keep status: archived, account: _orphans
      - archived row, file in non-matching/ or matched/   → status: matched, account: <actual>
      - archived row, file not found anywhere             → status: orphan, account: <empty>
      - promoted row, file in claimed per-account dir     → keep status: promoted, account: <claim>
      - promoted row, file in non-matching/ or matched/   → status: matched, account: <actual>
      - promoted row, file not found anywhere             → status: orphan, account: <empty>

    The script is idempotent — running it twice produces no further changes.

.PARAMETER ReceiptsDir
    Path to the Receipts/ directory. Default: intersite-consulting/2026 Filing/Receipts

.PARAMETER ManifestPath
    Path to the unified _manifest.csv. Default: <ReceiptsDir>/_manifest.csv

.PARAMETER WhatIf
    Dry run — print changes without writing the manifest.

.EXAMPLE
    .\Reconcile-ManifestStatus.ps1
    Sweep the default manifest. Writes updated manifest in place.

.EXAMPLE
    .\Reconcile-ManifestStatus.ps1 -WhatIf
    Show what would change without writing.
#>
[CmdletBinding()]
param(
    [string]$ReceiptsDir = (Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"),

    [string]$ManifestPath,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not $ManifestPath) { $ManifestPath = Join-Path $ReceiptsDir "_manifest.csv" }

if (-not (Test-Path $ManifestPath)) { Write-Error "Manifest not found: $ManifestPath"; exit 1 }
if (-not (Test-Path $ReceiptsDir)) { Write-Error "Receipts dir not found: $ReceiptsDir"; exit 1 }

# Directories to index — covers the locations a receipt might be in.
# Order matters: earlier entries win when a basename exists in multiple dirs.
# Use [ordered]@{} to guarantee enumeration order (regular hashtable is non-deterministic).
$indexDirs = [ordered]@{
    "_orphans/archived"      = "_orphans/archived"
    "_orphans"               = "_orphans"
    "non-matching"           = "non-matching"
    "matched"                = "matched"
    "intersite-mc-6258"      = "intersite-mc-6258"
    "intersite-rbc-chequing" = "intersite-rbc-chequing"
    "intersite-outbound"     = "intersite-outbound"
}

# Build filename → location index (basename, case-insensitive)
Write-Host "Indexing files in receipts tree..." -ForegroundColor Cyan
$fileIndex = @{}  # basename_lower -> first @{} Dir, Path
foreach ($entry in $indexDirs.GetEnumerator()) {
    $path = Join-Path $ReceiptsDir $entry.Value
    if (-not (Test-Path $path)) { continue }
    Get-ChildItem $path -File -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLower()
        if (-not $fileIndex.ContainsKey($key)) {
            $fileIndex[$key] = @{
                Dir  = $entry.Key
                Path = $_.FullName
            }
        }
    }
}
Write-Host "  $($fileIndex.Count) unique basenames indexed" -ForegroundColor Gray

# Read manifest
$manifest = Import-Csv $ManifestPath
Write-Host "  $($manifest.Count) manifest rows" -ForegroundColor Gray
Write-Host ""

# Sweep
$changes = 0
$unchanged = 0
$notFound = @()
$updatedRows = foreach ($row in $manifest) {
    if ($row.status -ne "archived" -and $row.status -ne "promoted") {
        $unchanged++
        $row
        continue
    }

    $bn = ([System.IO.Path]::GetFileName($row.filename)).ToLower()
    if (-not $fileIndex.ContainsKey($bn)) {
        $notFound += $row.filename
        # File is missing — set to orphan
        if ($row.status -ne "orphan" -or $row.account -ne "") {
            $changes++
            $row.status = "orphan"
            $row.account = ""
        } else {
            $unchanged++
        }
        $row
        continue
    }

    $loc = $fileIndex[$bn]
    $newStatus = "matched"
    $newAccount = $loc.Dir

    # Preserve archived status if the file is actually in _orphans/archived/
    if ($row.status -eq "archived" -and $loc.Dir -eq "_orphans/archived") {
        $newStatus = "archived"
        $newAccount = "_orphans"
    }
    # Preserve promoted status if the file is in the claimed per-account dir
    elseif ($row.status -eq "promoted" -and $loc.Dir -eq $row.account) {
        $newStatus = "promoted"
        $newAccount = $row.account
    }

    if ($newStatus -ne $row.status -or $newAccount -ne $row.account) {
        $changes++
        Write-Host "  [CHG] $($row.filename): $($row.status)/$($row.account) → $newStatus/$newAccount" -ForegroundColor Yellow
        $row.status = $newStatus
        $row.account = $newAccount
    } else {
        $unchanged++
    }
    $row
}

Write-Host ""
Write-Host "─── Summary ───" -ForegroundColor Cyan
Write-Host "  Rows scanned:    $($manifest.Count)"
Write-Host "  Unchanged:       $unchanged"
Write-Host "  Changed:         $changes"
Write-Host "  Files not found: $($notFound.Count)"

if ($notFound.Count -gt 0) {
    Write-Host ""
    Write-Host "  Files referenced in manifest but missing from filesystem:" -ForegroundColor Yellow
    $notFound | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
    if ($notFound.Count -gt 10) { Write-Host "    ... and $($notFound.Count - 10) more" }
}

if ($WhatIf) {
    Write-Host ""
    Write-Host "  [WhatIf] No changes written" -ForegroundColor Cyan
    return
}

if ($changes -gt 0) {
    $updatedRows | Export-Csv -Path $ManifestPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "  Manifest written: $ManifestPath" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  No changes — manifest already in sync" -ForegroundColor Green
}
