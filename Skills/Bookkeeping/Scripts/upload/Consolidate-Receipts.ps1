#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Renames and consolidates all Amazon and vendor receipts into Complete/
    following the receipt naming convention: {date} - {amount} - {summary}.{ext}
.PARAMETER ReceiptsDir
    Base directory for source receipts. Defaults to intersite-docs path.
.PARAMETER OutputDir
    Destination directory for consolidated Complete/ output.
.PARAMETER DryRun
    Print what would be done without copying.
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ReceiptsDir,

    [string]$OutputDir,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $ReceiptsDir) {
    $ReceiptsDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting"
}

$AmazonDir = Join-Path $ReceiptsDir "2026 Fiscal Year - Bank Statements\amazon-invoices"
$NewDir = Join-Path $ReceiptsDir "2026.05.28 - new receipts"

if (-not $OutputDir) {
    $OutputDir = Join-Path $ReceiptsDir "2026.05.28 - Receipts - intersite-consulting\Complete"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$OrderJson = Get-Content "$ReceiptsDir\2026 Fiscal Year - Bank Statements\amazon-orders-to-retrieve.json" | ConvertFrom-Json

$OrderLookup = @{}
foreach ($o in $OrderJson.amazon_orders) {
    if ($o.order_id) {
        $OrderLookup[$o.order_id] = $o
    }
}

function Convert-Date($d) {
    $parts = $d -split '/'
    if ($parts.Count -eq 3) {
        return "{0:D4}-{1:D2}-{2:D2}" -f [int]$parts[2], [int]$parts[0], [int]$parts[1]
    }
    return $d
}

function Sanitize-FileName($s) {
    return $s -replace '[/\\?%*:|"<>]', '-' -replace '\s+', ' ' -replace '_-_', ' - '
}

Write-Host "=== Renaming Amazon PDFs ===" -ForegroundColor Cyan
$AmazonItems = @()
if (Test-Path $AmazonDir) {
    Get-ChildItem $AmazonDir -Filter *.pdf | ForEach-Object {
        $pdf = $_
        $parts = $pdf.BaseName -split ' - '
        if ($parts.Count -ge 3) {
            $datePart = $parts[0].Trim()
            $amtPart = $parts[1].Trim()
            $summaryPart = "Amazon.ca Order Summary"
            $dateParts = $datePart -split '-'
            if ($dateParts.Count -eq 3) {
                $newDate = "{0:D4}-{1:D2}-{2:D2}" -f [int]$dateParts[2], [int]$dateParts[0], [int]$dateParts[1]
                $newName = "{0} - {1} - {2}.pdf" -f $newDate, $amtPart, $summaryPart
                $newName = Sanitize-FileName $newName
                $destPath = Join-Path $OutputDir $newName
                if ($DryRun) {
                    Write-Host "  [DRY RUN] $($pdf.Name) -> $newName" -ForegroundColor Magenta
                } else {
                    Copy-Item $pdf.FullName $destPath -Force
                    Write-Host "  $($pdf.Name) -> $newName" -ForegroundColor Gray
                }
                $AmazonItems += @{filename=$newName; original_filename=$pdf.Name; date=$newDate; amount=$amtPart; vendor="Amazon.ca"}
            }
        }
    }
}

Write-Host "`n=== Renaming new receipts ===" -ForegroundColor Cyan
$NewItems = @()

$ReceiptMap = @(
    @{pattern='aliexpress 10\.76'; date='2025-11-12'; amount='10.76'; vendor='AliExpress'; summary='AliExpress Page Markers Cable Velcro'}
    @{pattern='aliexpress 13\.43'; date='2025-10-19'; amount='13.43'; vendor='AliExpress'; summary='AliExpress Office Supplies'}
    @{pattern='aliexpress 18\.31'; date='2025-10-16'; amount='18.31'; vendor='AliExpress'; summary='AliExpress Office Supplies'}
    @{pattern='aliexpress 23\.67'; date='2025-10-30'; amount='23.67'; vendor='AliExpress'; summary='AliExpress Office Desk Storage Hooks'}
    @{pattern='aliexpress 24\.57'; date='2025-10-19'; amount='24.57'; vendor='AliExpress'; summary='AliExpress Mop Clips'}
    @{pattern='aliexpress 50\.33'; date='2025-11-11'; amount='50.33'; vendor='AliExpress'; summary='AliExpress Office Seat Foam'}
    @{pattern='Anomaly Receipt-2198'; date='2026-04-14'; amount='7.16'; vendor='Anomaly'; summary='Anomaly AI Service Apr 14'}
    @{pattern='Anomaly Receipt-2428'; date='2026-04-15'; amount='7.16'; vendor='Anomaly'; summary='Anomaly AI Service Apr 15'}
    @{pattern='Anomaly Receipt-2669'; date='2026-04-16'; amount='7.12'; vendor='Anomaly'; summary='Anomaly AI Service Apr 16'}
    @{pattern='Anomaly Receipt-2984'; date='2026-04-19'; amount='7.12'; vendor='Anomaly'; summary='Anomaly AI Service Apr 19'}
    @{pattern='bc registry'; date='2026-03-26'; amount='44.89'; vendor='BC Registry'; summary='BC Government Registration'}
    @{pattern='creative fabrica'; date='2026-04-29'; amount='84.06'; vendor='Creative Fabrica'; summary='Creative Fabrica Design Subscription'}
    @{pattern='Kilo Code'; date='2026-04-09'; amount='14.40'; vendor='Kilo Code Inc'; summary='Kilo Code AI Coding Service'}
    @{pattern='Namecheap'; date='2026-04-27'; amount='15.72'; vendor='Namecheap'; summary='Namecheap Domain clocklobster.com'}
    @{pattern='Openrouter'; date='2026-04-20'; amount='59.56'; vendor='OpenRouter Inc'; summary='OpenRouter AI API Usage'}
    @{pattern='P\. skool'; date='2026-03-25'; amount='83.27'; vendor='P.skool'; summary='P.skool Online Course Platform'}
    @{pattern='reinvest wealth.*2408'; date='2026-02-13'; amount='82.95'; vendor='Re Invest Wealth Inc'; summary='RelInvestWealth AI Accounting Software'}
    @{pattern='reinvest wealth.*2669'; date='2026-02-25'; amount='82.95'; vendor='Re Invest Wealth Inc'; summary='RelInvestWealth AI Accounting Software'}
    @{pattern='Roomies'; date='2026-04-16'; amount='20.00'; vendor='Roomies'; summary='Roomies Rental Listing Fee'}
    @{pattern='Squarespace.*17.*intersite\.rsvp'; date='2026-01-05'; amount='17.00'; vendor='Squarespace'; summary='Squarespace Domain intersite.rsvp'}
    @{pattern='Squarespace.*2026\.03\.07'; date='2026-03-09'; amount='17.00'; vendor='Squarespace'; summary='Squarespace Domain intersite.ca'}
    @{pattern='Squarespace.*21\.00'; date='2026-01-06'; amount='21.00'; vendor='Squarespace'; summary='Squarespace Domain victorsalmon.com'}
    @{pattern='temu'; date='2026-02-05'; amount='60.59'; vendor='Temu'; summary='Temu Office Supplies Gloves'}
    @{pattern='visions'; date='2025-11-28'; amount='566.44'; vendor='Visions Electronics'; summary='Visions Electronics Purchase'}
    @{pattern='Z\.ai'; date='2026-04-20'; amount='25.30'; vendor='Stripe-z.ai'; summary='Z.ai AI Service via Stripe'}
)

if (Test-Path $NewDir) {
    Get-ChildItem $NewDir -Recurse -File | ForEach-Object {
        $file = $_
        $matched = $null
        foreach ($entry in $ReceiptMap) {
            if ($file.Name -match $entry.pattern) {
                $matched = $entry
                break
            }
        }
        if ($matched) {
            $ext = $file.Extension
            $newName = "{0} - {1} - {2}{3}" -f $matched.date, $matched.amount, $matched.summary, $ext
            $newName = Sanitize-FileName $newName
            $destPath = Join-Path $OutputDir $newName
            if ($DryRun) {
                Write-Host "  [DRY RUN] $($file.Name) -> $newName" -ForegroundColor Magenta
            } else {
                Copy-Item $file.FullName $destPath -Force
                Write-Host "  $($file.Name) -> $newName" -ForegroundColor Gray
            }
            $NewItems += @{filename=$newName; original_filename=$file.Name; date=$matched.date; amount=$matched.amount; vendor=$matched.vendor}
        } else {
            Write-Host "  [UNMATCHED] $($file.Name)" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n=== Generating manifest ===" -ForegroundColor Cyan
$AllItems = $AmazonItems + $NewItems | Sort-Object date, amount

$manifestPath = Join-Path $OutputDir "manifest.csv"
@"
filename,original_filename,date,amount,vendor
"@ | Set-Content $manifestPath -Encoding UTF8

foreach ($item in $AllItems) {
    "{0},{1},{2},{3},{4}" -f $item.filename, $item.original_filename, $item.date, $item.amount, $item.vendor | Add-Content $manifestPath -Encoding UTF8
}

Write-Host "`nDone! Complete/: $((Get-ChildItem $OutputDir -File | Where-Object { $_.Extension -ne '.csv' }).Count) files"
Write-Host "Manifest: $manifestPath"
Write-Host "Amazon PDFs: $($AmazonItems.Count)"
Write-Host "New receipts: $($NewItems.Count)"
Write-Host "Total: $($AllItems.Count)"
