<#
.SYNOPSIS
    Scan receipt directories for unlisted files, enrich, rebuild TAS, update status.
.DESCRIPTION
    Runs the full cycle: scan for new receipts → add to manifest → enrich → rebuild TAS → status check.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [switch]$ShowFiles
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath

Write-Host "=== Receipt Scan & Rebuild: $Entity ===" -ForegroundColor Cyan

# Step 1: Scan for new receipt files not in manifest
Write-Host "`n[1/4] Scanning for new receipt files..." -ForegroundColor Yellow

if ($Entity -eq "room-rentals") {
    $ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts"
    $ManifestPath = "$ReceiptsBase\manifest.csv"
} else {
    $ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
    $ManifestPath = "$ReceiptsBase\_manifest.csv"
}

$raw = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop
if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
$manifest = $raw | ConvertFrom-Csv
$existingFilenames = @($manifest | ForEach-Object { $_.filename })

Write-Host "  Existing manifest: $($manifest.Count) entries"
Write-Host "  Scanning: $ReceiptsBase"

$newCount = 0
Get-ChildItem $ReceiptsBase -Recurse -File -Include *.pdf,*.jpg,*.jpeg,*.png | Where-Object {
    $_.DirectoryName -notmatch 'non-matching|tx-reference'
} | ForEach-Object {
    $relPath = $_.FullName.Substring($ReceiptsBase.Length + 1)
    $inManifest = $existingFilenames -contains $relPath
    if (-not $inManifest) {
        $date = if ($_.Name -match '(\d{4}-\d{2}-\d{2})') { $matches[1] } else { '' }
        $amount = if ($_.Name -match '(\d+\.\d{2})') { $matches[1] } else { '' }
        $account = ($relPath -split '[\\/]')[0]
        $sha256 = ''
        try { $sha256 = (Get-FileHash -Path $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { }

        Write-Host "  NEW: $relPath  (account=$account)"
        $manifest += [PSCustomObject]@{
            filename           = $relPath
            date               = $date
            amount             = $amount
            vendor             = ''
            account            = $account
            sha256             = $sha256
            zoho_expense_id    = ''
            zoho_document_id   = ''
            source             = 'scan-rebuild'
            status             = 'orphan'
            notes              = ''
        }
        $newCount++
    }
}

if ($newCount -eq 0) { Write-Host "  No new files found." }

# Step 2: Write updated manifest
Write-Host "`n[2/4] Writing updated manifest ($($manifest.Count) entries)..." -ForegroundColor Yellow
# Backup current manifest
Copy-Item $ManifestPath "$ManifestPath.bak" -Force -ErrorAction SilentlyContinue
# Use Export-Csv which handles quoting properly
$manifest | Export-Csv -Path $ManifestPath -NoTypeInformation -Encoding utf8

# Step 3: Run enrichment
Write-Host "`n[3/4] Running enrichment..." -ForegroundColor Yellow
& "$scriptDir\Invoke-BookkeepingEnrichment.ps1" -Entity $Entity

# Step 4: Rebuild TAS
Write-Host "`n[4/4] Rebuilding TAS..." -ForegroundColor Yellow
if ($Entity -eq "room-rentals") {
    & "$scriptDir\..\reconciliation\Build-TAS.ps1"
} else {
    & "$scriptDir\..\reconciliation\Build-IntersiteTAS.ps1"
}

# Step 5: Status check
Write-Host "`n=== Status check ===" -ForegroundColor Cyan
& "$scriptDir\Invoke-StatusCheck.ps1" -Organization $Entity -Display

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "New files added: $newCount"
