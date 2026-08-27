<#
.SYNOPSIS
    Phase 2-iv: Update manifest.csv with directory scan and metadata consolidation.
.DESCRIPTION
    Scans ReceiptsDir for receipt files (PDF, JPG, PNG), reconciles against
    manifest.csv, adds new entries, flags hash changes, consolidates metadata
    from .json sidecars (extracted by Phase 2-ii), and computes
    invoice_extraction_method from available sidecar files.
.PARAMETER ReceiptsDir
    Path to the receipts directory.
.PARAMETER ManifestPath
    Path to manifest.csv. Defaults to "manifest.csv" relative to ReceiptsDir.
.PARAMETER Entity
    Optional path to cloud-books-entities.json for entity context.
.PARAMETER Force
    Ignore status columns and re-process all receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReceiptsDir,
    [string]$ManifestPath = "manifest.csv",
    [string]$Entity,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$manifestPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $ReceiptsDir $ManifestPath }

$hasExistingManifest = Test-Path $manifestPath
$manifest = if ($hasExistingManifest) { Import-Csv $manifestPath } else { @() }

$sidecarDir = Join-Path $ReceiptsDir ".sidecars"

$receiptExtensions = @("*.pdf","*.jpg","*.jpeg","*.png")
$receiptFiles = Get-ChildItem -Path "$ReceiptsDir\*" -Include $receiptExtensions -File

if (-not $receiptFiles) { Write-Host "No receipt files found in $ReceiptsDir" -ForegroundColor Yellow; return }

$total = @($receiptFiles).Count
$processed = 0
$addedCount = 0
$changedCount = 0

$manifestIndex = @{}
if ($hasExistingManifest) {
    foreach ($row in $manifest) {
        if ($row.filename) { $manifestIndex[$row.filename] = $row }
        if ($row.original_filename -and $row.original_filename -ne $row.filename) { $manifestIndex[$row.original_filename] = $row }
    }
}

$entityData = $null
if ($Entity -and (Test-Path $Entity)) {
    try { $entityData = Get-Content $Entity -Raw | ConvertFrom-Json } catch { Write-Warning "Could not read entity file: $Entity" }
}

foreach ($rf in $receiptFiles) {
    $processed++
    Write-Progress -Activity "Updating Manifest" -Status $rf.Name -PercentComplete (($processed / $total) * 100)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($rf.FullName)
    $hashBytes = $sha.ComputeHash($stream)
    $stream.Close()
    $currentHash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

    $existing = $manifestIndex[$rf.Name]

    if (-not $existing) {
        $newRow = [PSCustomObject]@{
            filename = $rf.Name
            original_filename = $rf.Name
            date = ""
            amount = ""
            vendor = ""
            invoice_extraction_method = ""
            cloud_books_match_id = ""
            cloud_books_date = ""
            cloud_books_name = ""
            cloud_books_amount = ""
            is_fx_purchase = ""
            currency = ""
            fx_rate = ""
            hash = $currentHash
            notes = ""
            error_status = ""
            status_phase1_find = "done"
            status_pdf_extraction = ""
            status_image_extraction = ""
            status_file_rename = ""
            status_manifest_update = ""
            status_cloud_match = ""
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($rf.Name)
        $jsonSidecar = Join-Path $sidecarDir "$baseName.json"
        if (Test-Path $jsonSidecar) {
            try {
                $meta = Get-Content $jsonSidecar -Raw | ConvertFrom-Json
                if ($meta.date) { $newRow.date = $meta.date }
                if ($meta.amount -or $meta.total) { $newRow.amount = if ($meta.amount -and $meta.amount -ne 0) { "$($meta.amount)" } elseif ($meta.total) { "$($meta.total)" } else { "" } }
                if ($meta.vendor) { $newRow.vendor = $meta.vendor }
                if ($meta.currency) { $newRow.currency = $meta.currency }
                if ($meta.summary) { $newRow.notes = $meta.summary }
            } catch { }
        }

        $hasMd = Test-Path (Join-Path $sidecarDir "$baseName.md")
        $hasJson = Test-Path $jsonSidecar
        if ($hasMd -and $hasJson) { $newRow.invoice_extraction_method = "pdfplumber+gpt4o-mini" }
        elseif ($hasMd) { $newRow.invoice_extraction_method = "pdfplumber" }
        elseif ($hasJson) { $newRow.invoice_extraction_method = "gpt4o-mini" }

        $manifest += $newRow
        $manifestIndex[$rf.Name] = $newRow
        $addedCount++
    } else {
        if ($existing.hash -and $existing.hash -ne $currentHash) {
            $existing.hash = $currentHash
            $existing.notes = if ($existing.notes) { "$($existing.notes); hash changed" } else { "hash changed" }
            $existing.status_manifest_update = ""
            $changedCount++
        }
    }
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "Manifest update complete. $($manifest.Count) entries ($addedCount added, $changedCount hash changes)." -ForegroundColor Green
