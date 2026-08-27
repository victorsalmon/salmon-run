<#
.SYNOPSIS
    Phase 2-i: Extract text from PDF receipts, or convert to images for OCR.
.DESCRIPTION
    Reads manifest.csv, processes receipts with pending pdf_extraction status.
    PDFs: delegates to convert-pdf-to-text.py. If no text found (exit 2),
    renders to JPEG via convert-pdf-to-image.py for vision-based OCR.
    Images (JPG/PNG): marks status_pdf_extraction as n/a.
.PARAMETER ReceiptsDir
    Path to the receipts directory (e.g., "{Year} Receipts/").
.PARAMETER ManifestPath
    Path to manifest.csv. Defaults to "manifest.csv" relative to ReceiptsDir.
.PARAMETER Force
    Ignore status columns and re-process all receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReceiptsDir,
    [string]$ManifestPath = "manifest.csv",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$manifestPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $ReceiptsDir $ManifestPath }

if (-not (Test-Path $manifestPath)) { Write-Warning "Manifest not found: $manifestPath"; return }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$convertPdfToText = Join-Path $scriptDir "convert-pdf-to-text.py"
$convertPdfToImage = Join-Path $scriptDir "convert-pdf-to-image.py"

$manifest = Import-Csv $manifestPath

if ($Force) {
    $pending = $manifest
} else {
    $pending = $manifest | Where-Object { $_.status_pdf_extraction -ne "done" -and $_.status_pdf_extraction -ne "n/a" -and $_.status_pdf_extraction -ne "error" }
}

if (-not $pending) { Write-Host "No receipts pending PDF extraction." -ForegroundColor Green; return }

$total = @($pending).Count
$processed = 0

$sidecarDir = Join-Path $ReceiptsDir ".sidecars"
New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null

$imageDir = Join-Path $ReceiptsDir "_pdf_images"

foreach ($receipt in $pending) {
    $processed++
    Write-Progress -Activity "PDF Data Extraction" -Status $receipt.filename -PercentComplete (($processed / $total) * 100)

    $filePath = Join-Path $ReceiptsDir $receipt.filename
    if (-not (Test-Path $filePath)) { Write-Warning "Source file not found: $filePath"; continue }

    $ext = [System.IO.Path]::GetExtension($receipt.filename).ToLower()

    if ($ext -eq '.pdf') {
        & python $convertPdfToText $filePath --output-dir $sidecarDir 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $receipt.status_pdf_extraction = "done"
        } elseif ($exitCode -eq 2) {
            New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
            $tempPdfDir = Join-Path $env:TEMP "oc_pdf_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempPdfDir -Force | Out-Null
            Copy-Item -LiteralPath $filePath -Destination (Join-Path $tempPdfDir $receipt.filename) -Force
            & python $convertPdfToImage --input-dir $tempPdfDir --output-dir $imageDir --dpi 200 2>&1 | Out-Null
            Remove-Item -Path $tempPdfDir -Recurse -Force -ErrorAction SilentlyContinue
            $receipt.status_pdf_extraction = "done"
        } else {
            $receipt.status_pdf_extraction = "error"
        }
    } elseif ($ext -match '\.(jpg|jpeg|png)$') {
        $receipt.status_pdf_extraction = "n/a"
    }
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "PDF data extraction complete. Manifest: $manifestPath" -ForegroundColor Green
