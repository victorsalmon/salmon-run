<#
.SYNOPSIS
    Phase 2-ii: Extract structured receipt data from images using vision AI.
.DESCRIPTION
    Reads manifest.csv, processes receipts with pending image_extraction status.
    Delegates to extract-receipt-ocr.py for GPT-4o-mini vision analysis.
    Uses hash-based caching to avoid re-processing unchanged images.
    Scans both ReceiptsDir and _pdf_images/ (converted PDF pages from Phase 2-i).
.PARAMETER ReceiptsDir
    Path to the receipts directory.
.PARAMETER ManifestPath
    Path to manifest.csv. Defaults to "manifest.csv" relative to ReceiptsDir.
.PARAMETER Model
    Vision model identifier. Default: gpt-4o-mini.
.PARAMETER Force
    Ignore status columns and re-process all receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReceiptsDir,
    [string]$ManifestPath = "manifest.csv",
    [string]$Model = "gpt-4o-mini",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$manifestPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $ReceiptsDir $ManifestPath }

if (-not (Test-Path $manifestPath)) { Write-Warning "Manifest not found: $manifestPath"; return }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$extractOcr = Join-Path $scriptDir "extract-receipt-ocr.py"

$manifest = Import-Csv $manifestPath

if ($Force) {
    $pending = $manifest
} else {
    $pending = $manifest | Where-Object { $_.status_image_extraction -ne "done" -and $_.status_image_extraction -ne "error" -and $_.status_image_extraction -ne "n/a" }
}

if (-not $pending) { Write-Host "No receipts pending image extraction." -ForegroundColor Green; return }

$total = @($pending).Count
$processed = 0
$sidecarDir = Join-Path $ReceiptsDir ".sidecars"
New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null
$cacheFile = Join-Path $ReceiptsDir ".ocr-cache.json"

$imagePaths = @()
$pendingMap = @{}
foreach ($receipt in $pending) {
    $ext = [System.IO.Path]::GetExtension($receipt.filename).ToLower()
    if ($ext -match '\.(jpg|jpeg|png)$') {
        $fp = Join-Path $ReceiptsDir $receipt.filename
        $imagePaths += $fp
        $pendingMap[$fp] = $receipt
    } elseif ($ext -eq '.pdf') {
        $pendingMap["pdf:$($receipt.filename)"] = $receipt
    }
}

$pdfImageDir = Join-Path $ReceiptsDir "_pdf_images"
if (Test-Path $pdfImageDir) {
    $convertedFiles = Get-ChildItem -Path $pdfImageDir -Include "*.jpg","*.jpeg","*.png" -File
    foreach ($cf in $convertedFiles) { $imagePaths += $cf.FullName }
}

if ($imagePaths.Count -eq 0) {
    foreach ($receipt in $pending) { $receipt.status_image_extraction = "n/a" }
    $manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    Write-Host "No images to process. Marked pending as n/a." -ForegroundColor Yellow
    return
}

& python $extractOcr $imagePaths --output-dir $sidecarDir --model $Model --cache-file $cacheFile 2>&1

foreach ($receipt in $pending) {
    $processed++
    Write-Progress -Activity "Image Data Extraction" -Status $receipt.filename -PercentComplete (($processed / $total) * 100)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($receipt.filename)
    $jsonPath = Join-Path $sidecarDir "$baseName.json"

    $ext = [System.IO.Path]::GetExtension($receipt.filename).ToLower()
    if ($ext -eq '.pdf') {
        $pdfJson = Get-ChildItem -Path $sidecarDir -Filter "$($baseName)_p*.json" -File
        if ($pdfJson) {
            $allOk = $true
            foreach ($j in $pdfJson) {
                try { $sc = Get-Content $j.FullName -Raw | ConvertFrom-Json; if ($sc.error_status) { $allOk = $false } } catch { $allOk = $false }
            }
            $receipt.status_image_extraction = if ($allOk) { "done" } else { "error" }
        } else {
            $receipt.status_image_extraction = "error"
        }
    } elseif ($ext -match '\.(jpg|jpeg|png)$') {
        if (Test-Path $jsonPath) {
            try { $sc = Get-Content $jsonPath -Raw | ConvertFrom-Json; $receipt.status_image_extraction = if ($sc.error_status) { "error" } else { "done" } } catch { $receipt.status_image_extraction = "error" }
        } else {
            $receipt.status_image_extraction = "error"
        }
    }
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "Image data extraction complete. Manifest: $manifestPath" -ForegroundColor Green
