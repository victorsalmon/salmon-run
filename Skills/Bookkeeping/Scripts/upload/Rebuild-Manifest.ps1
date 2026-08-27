<#
.SYNOPSIS
    Regenerate manifest CSV from actual files on disk — authoritative source of truth.
.DESCRIPTION
    Scans the receipt directory for all PDF/JPG/PNG files, extracts metadata from
    filenames (via receipt_utils.py), computes SHA256, and writes a fresh manifest.
    Replaces the append-only approach that accumulates stale entries.
.PARAMETER Entity
    Which entity to rebuild manifest for (intersite-consulting or room-rentals).
.PARAMETER DryRun
    Show what would be written without writing.
.PARAMETER Force
    Skip confirmation prompt.
.PARAMETER BackupDir
    Where to store backup (default: next to manifest).
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [switch]$DryRun,
    [switch]$Force,
    [string]$BackupDir = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath

# Resolve entity paths
if ($Entity -eq "intersite-consulting") {
    $ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
    $ManifestPath = "$ReceiptsBase\_manifest.csv"
    $SkipDirs = @('non-matching', 'tx-reference', 'Duplicates', 'Complete', '_orphans', 'Dedup-target-candidates', '_manual-review')
} else {
    $ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts"
    $ManifestPath = "$ReceiptsBase\manifest.csv"
    $SkipDirs = @('non-matching', 'tx-reference', 'Duplicates', 'Complete', '_orphans', 'Dedup-target-candidates', '_manual-review')
}

$ManifestHeader = @('filename', 'date', 'amount', 'vendor', 'account', 'sha256', 'status', 'zoho_expense_id', 'zoho_document_id', 'source')

# Walk files on disk — include sidecar .txt/.csv/.md (statement records) alongside images
Write-Host "Scanning: $ReceiptsBase" -ForegroundColor Yellow
$files = Get-ChildItem $ReceiptsBase -Recurse -File -Include *.pdf,*.jpg,*.jpeg,*.png,*.txt,*.csv,*.md | Where-Object {
    $relDir = [System.IO.Path]::GetRelativePath($ReceiptsBase, $_.DirectoryName)
    $inSkip = $false
    foreach ($sd in $SkipDirs) {
        if ($relDir -eq $sd -or $relDir -match "^$sd[\\/]|^$sd$") { $inSkip = $true; break }
    }
    # Exclude manifest files, backups, python cache
    if ($_.Name -match '^manifest|^_|\.bak\.|\.cache') { $inSkip = $true }
    -not $inSkip
}
Write-Host "  Files on disk (excl. skipped dirs): $($files.Count)" -ForegroundColor Yellow

# Load existing manifest to preserve zoho IDs
$existingZohoIds = @{}
if (Test-Path $ManifestPath) {
    try {
        $existing = Import-Csv $ManifestPath
        foreach ($row in $existing) {
            $fn = $row.filename
            if ($fn -and $row.zoho_expense_id) {
                $existingZohoIds[$fn] = @{
                    zoho_expense_id  = $row.zoho_expense_id
                    zoho_document_id = $row.zoho_document_id
                }
            }
        }
        Write-Host "  Existing manifest: $($existing.Count) entries ($($existingZohoIds.Count) with Zoho IDs)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "  Could not read existing manifest: $_"
    }
} else {
    Write-Host "  No existing manifest found." -ForegroundColor DarkGray
}

# Build new manifest rows from disk
$newRows = [System.Collections.ArrayList]@()
$unparseable = 0
$zohoPreserved = 0
$total = $files.Count
$i = 0

foreach ($file in $files) {
    $i++
    if ($i % 50 -eq 0) { Write-Host "  Progress: $i/$total" -ForegroundColor DarkGray }

    $relPath = [System.IO.Path]::GetRelativePath($ReceiptsBase, $file.FullName)
    $acct = ($relPath -split '[\\/]')[0]

    # Parse filename via receipt_utils.py
    $pythonScript = "$scriptDir\receipt_utils.py"
    # Double-quote the filename to handle special chars
    $escapedName = $file.Name -replace "'", "'\\''"
    $result = & python -c "import sys; sys.path.insert(0, '$scriptDir'); from receipt_utils import parse_filename_meta; import json; meta = parse_filename_meta('$escapedName'); print(json.dumps(meta) if meta else 'null')" 2>$null
    $parsed = $result | ConvertFrom-Json -ErrorAction SilentlyContinue

    # SHA256
    $sha256 = ""
    try {
        $sha256 = (Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
    } catch {
        Write-Warning "  Could not hash: $($file.Name): $_"
    }

    $dateVal = if ($parsed -and $parsed.date) { $parsed.date } else { "" }
    $amtVal = if ($parsed -and $parsed.amount -ne $null) { "{0:F2}" -f [double]$parsed.amount } else { "" }
    $vendorVal = if ($parsed -and $parsed.vendor) { $parsed.vendor } else { "" }
    $statusVal = if ($dateVal -and $amtVal) { "matched" } else { "unparseable" }
    if (-not $dateVal -or -not $amtVal) { $unparseable++ }

    # Preserve Zoho IDs from existing manifest
    $zId = ""
    $zDocId = ""
    if ($existingZohoIds.ContainsKey($relPath)) {
        $zId = $existingZohoIds[$relPath].zoho_expense_id
        $zDocId = $existingZohoIds[$relPath].zoho_document_id
        $zohoPreserved++
    }

    $row = [PSCustomObject]@{
        filename          = $relPath
        date              = $dateVal
        amount            = $amtVal
        vendor            = $vendorVal
        account           = $acct
        sha256            = $sha256
        status            = $statusVal
        zoho_expense_id   = $zId
        zoho_document_id  = $zDocId
        source            = "rebuild-manifest"
    }
    [void]$newRows.Add($row)
}

# Sort by date then filename
$newRows = $newRows | Sort-Object date, filename

Write-Host "  Parseable: $($newRows.Count - $unparseable), Unparseable: $unparseable" -ForegroundColor Yellow
Write-Host "  Zoho IDs preserved: $zohoPreserved" -ForegroundColor DarkGray

# Backup old manifest
$backupPath = ""
if (Test-Path $ManifestPath) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = if ($BackupDir) { "$BackupDir\_manifest.bak.$timestamp.csv" } else { "$ReceiptsBase\_manifest.bak.$timestamp.csv" }
    Copy-Item $ManifestPath $backupPath -Force
    Write-Host "  Old manifest backed up: $backupPath" -ForegroundColor DarkGray
}

# Dry run
if ($DryRun) {
    $existingCount = if (Test-Path $ManifestPath) { (Import-Csv $ManifestPath).Count } else { 0 }
    $staleCount = [math]::Max(0, $existingCount - $newRows.Count)
    Write-Host "`n===== Rebuild-Manifest (DRY RUN) =====" -ForegroundColor Cyan
    Write-Host "Entity: $Entity"
    Write-Host "Base: $ReceiptsBase"
    Write-Host "Files on disk: $($files.Count)"
    Write-Host "Current manifest: $existingCount entries ($staleCount stale)"
    Write-Host "Would write: $($newRows.Count) entries"
    Write-Host "Unparseable: $unparseable filenames"
    Write-Host "===================================" -ForegroundColor Cyan
    return
}

# Write new manifest
$newRows | Export-Csv -Path $ManifestPath -NoTypeInformation -Encoding utf8
Write-Host "`nManifest written: $ManifestPath ($($newRows.Count) rows)" -ForegroundColor Green

# Validate
try {
    $reRead = Import-Csv $ManifestPath
    $rowCount = $reRead.Count
    $emptyFilename = @($reRead | Where-Object { [string]::IsNullOrWhiteSpace($_.filename) }).Count
    $emptyDate = @($reRead | Where-Object { [string]::IsNullOrWhiteSpace($_.date) }).Count
    $emptyAmount = @($reRead | Where-Object { [string]::IsNullOrWhiteSpace($_.amount) }).Count
    Write-Host "  Validation: $rowCount rows, $emptyFilename empty filenames, $emptyDate empty dates, $emptyAmount empty amounts" -ForegroundColor $(if ($emptyFilename -eq 0 -and $rowCount -eq $newRows.Count) { "Green" } else { "Yellow" })
    if ($rowCount -ne $newRows.Count) {
        Write-Warning "  Row count mismatch: wrote $($newRows.Count), re-read $rowCount"
    }
    if ($emptyFilename -gt 0) {
        Write-Warning "  $emptyFilename rows have empty filename"
    }
} catch {
    Write-Warning "  Validation failed: $_"
}
