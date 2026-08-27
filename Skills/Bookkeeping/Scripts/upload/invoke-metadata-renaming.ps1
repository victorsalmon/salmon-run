<#
.SYNOPSIS
    Phase 2-iii: Rename receipt file groups based on extracted metadata.
.DESCRIPTION
    Reads manifest.csv, processes receipts with pending file_rename status.
    Collects all files sharing the receipt's original base name across
    ReceiptsDir and .sidecars/ (.pdf, .md, .json, .jpg, .jpeg, .png)
    and renames them as a group using manifest metadata.
    New base name format: {YYYY-MM-DD} - ${amount} - {Vendor} - {summary}
.PARAMETER ReceiptsDir
    Path to the receipts directory.
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

$manifest = Import-Csv $manifestPath

if ($Force) {
    $pending = $manifest
} else {
    $pending = $manifest | Where-Object { $_.status_file_rename -ne "done" -and $_.status_file_rename -ne "n/a" }
}

if (-not $pending) { Write-Host "No receipts pending file rename." -ForegroundColor Green; return }

$total = @($pending).Count
$processed = 0
$sidecarDir = Join-Path $ReceiptsDir ".sidecars"
$usedNames = @{}

$searchDirs = @($ReceiptsDir)
if (Test-Path $sidecarDir) { $searchDirs += $sidecarDir }

foreach ($receipt in $pending) {
    $processed++
    Write-Progress -Activity "Metadata Renaming" -Status $receipt.filename -PercentComplete (($processed / $total) * 100)

    $date = if ($receipt.date) { $receipt.date } else { "unknown-date" }
    $amount = if ($receipt.amount) { "{0:N2}" -f [double]$receipt.amount } else { "0.00" }
    $vendor = if ($receipt.vendor) { $receipt.vendor -replace '[^\w\s-]','' } else { "unknown-vendor" }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($receipt.filename)

    $summary = ""
    $jsonSidecarPath = Join-Path $sidecarDir "$baseName.json"
    if (Test-Path $jsonSidecarPath) {
        try { $sc = Get-Content $jsonSidecarPath -Raw | ConvertFrom-Json; $summary = if ($sc.summary) { ($sc.summary -replace '[^\w\s-]','').Trim() } else { "" } } catch { }
    }

    $displayAmount = $amount -replace '[, ]',''
    $newBaseName = "$date - `$$displayAmount - $vendor"
    if ($summary) { $newBaseName += " - $summary" }

    $resolvedBase = $newBaseName
    $counter = 1
    while ($usedNames.ContainsKey($resolvedBase.ToLower())) {
        $counter++
        $resolvedBase = "$newBaseName ($counter)"
    }
    $usedNames[$resolvedBase.ToLower()] = $true

    $sourceExt = [System.IO.Path]::GetExtension($receipt.filename).ToLower()
    $sourceExtensions = @(".pdf",".md",".json",".jpg",".jpeg",".png") | Select-Object -Unique

    $renamedFiles = 0
    foreach ($sDir in $searchDirs) {
        foreach ($ext in $sourceExtensions) {
            $oldPath = Join-Path $sDir "$baseName$ext"
            if (Test-Path $oldPath) {
                $newPath = Join-Path $sDir "$resolvedBase$ext"
                Rename-Item -LiteralPath $oldPath -NewName "$resolvedBase$ext" -Force -ErrorAction SilentlyContinue
                $renamedFiles++
            }
        }
    }

    if ($renamedFiles -gt 0) {
        $receipt.filename = "$resolvedBase$sourceExt"
    }
    $receipt.status_file_rename = "done"
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "Metadata renaming complete. Manifest: $manifestPath" -ForegroundColor Green
