<#
.SYNOPSIS
    DEPRECATED — superseded by the PRP pipeline (Invoke-PrpOrgPipeline.ps1).
    Data gathering is now Step DG of the Pre-Recon Pipeline. Run:
      .\Invoke-PrpOrgPipeline.ps1 -OrgName "room-rentals"
    This script is preserved for backward compatibility but will not be updated.
    All bug fixes and enhancements go into Invoke-PrpStepDG-DataGathering.ps1.
#>

param(
    [switch]$WhatIf,
    [switch]$ContinueOnError
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path "$scriptDir\..\..\.."
$booksRoot = "C:\Repos\intersite-docs\Taxes and Bookkeeping\room-rentals"
$bankDir = "$booksRoot\2026 Bank Statements"
$tasPath = "$booksRoot\TAS-2026.csv"

# ── Workflow event logging ─────────────────────────────────────
# Emits MONTHLY_UPDATE_START / MONTHLY_UPDATE_END to
# Tasks/Logs/workflow-events.log so future runs can grep for when
# each entity was last processed and what was done.
# We write directly to the log file (rather than going through the
# Write-WorkflowEvent function) because that function is broken on
# PowerShell 5.1 (it uses a 3-arg Join-Path that only works in PS 7+).
# Patching the function is a separate concern; this is the
# minimum-viable logging for these wrappers.
$startTime = Get-Date
$mode = if ($WhatIf) { "WhatIf" } else { "Real" }
$logDir = Join-Path $repoRoot "Tasks/Logs"
$logFile = Join-Path $logDir "workflow-events.log"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
function Emit-MonthlyUpdateEvent {
    param(
        [string]$Type,
        [string]$Detail,
        [string[]]$Files = @()
    )
    $event = [ordered]@{
        ts     = [datetime]::UtcNow.ToString('o')
        type   = $Type
        phase  = "cowork"
        files  = @($Files)
        detail = $Detail
    }
    try {
        Add-Content -Path $logFile -Value ($event | ConvertTo-Json -Compress) -Encoding utf8
    } catch {
        Write-Debug "Monthly update log write failed: $_"
    }
}
Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_START" `
    -Detail "entity=room-rentals mode=$mode startedAt=$($startTime.ToString('o'))" `
    -Files @($PSCommandPath)

# Per-account mapping -- must match Build-TAS.ps1 accounts
$accountMap = @(
    @{ name = "fra"; label = "RBC-FRA 5172549";           folder = "RBC-FRA-5172549";           zoho = "2026.06.11-Present - RBC-FRA 5172549 - Zoho.csv" }
    @{ name = "mlm"; label = "TD-MLM 6467010";            folder = "TD-MLM-6467010";            zoho = "2026.06.11-Present - TD-MLM 6467010 - Zoho.csv" }
    @{ name = "tmh"; label = "SCOTIA-TMH 406000697486";   folder = "SCOTIA-TMH 406000697486";   zoho = "2026.06.11-Present - SCOTIA-TMH 406000697486 - Zoho.csv" }
    @{ name = "rbc-visa"; label = "RBC-FRA-6679 Visa";    folder = "RBC-FRA-6679";              zoho = "2026.06.11-Present - RBC-FRA-6679 Visa - Zoho.csv" }
)

$containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}"
if (-not $containerId) {
    Write-Error "Bookkeeping container not running -- is the fleet deployed?"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=room-rentals mode=$mode status=error reason=accountant_container_down" `
        -Files @($PSCommandPath)
    exit 1
}
$token = docker exec $containerId cat /run/secrets/fleet_api_token 2>$null
if (-not $token) {
    Write-Error "Could not get Bookkeeper API token"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=room-rentals mode=$mode status=error reason=token_unavailable" `
        -Files @($PSCommandPath)
    exit 1
}

Write-Host "=== Step 1: Export Zoho Plaid transactions (room-rentals) ===" -ForegroundColor Cyan
$body = @{dry_run = [bool]$WhatIf; entity = "room-rentals"} | ConvertTo-Json
$result = Invoke-RestMethod -Uri "http://localhost:21008/zoho/transactions/export" -Method POST `
    -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
    -Body $body

if (-not $result.success) {
    Write-Error "Export failed: $($result | ConvertTo-Json)"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=room-rentals mode=$mode status=error reason=export_failed" `
        -Files @($PSCommandPath)
    exit 1
}
Write-Host "  Total: $($result.total_transactions) txns across $($result.total_accounts) accounts" -ForegroundColor Green
foreach ($a in $result.accounts) {
    $color = if ($a.error) { "Red" } elseif ($a.transactions -eq 0) { "Yellow" } else { "Green" }
    $status = if ($a.error) { "ERROR: $($a.error)" } elseif ($a.transactions -eq 0) { "no Plaid data" } else { "$($a.transactions) txns -> $($a.csvFile)" }
    Write-Host "    $($a.label): $status" -ForegroundColor $color
}

if ($WhatIf) {
    Write-Host "`n=== Step 2: Copy to bank statements (SKIP -- WhatIf) ===" -ForegroundColor Yellow
    Write-Host "=== Step 3: Build TAS (SKIP -- WhatIf) ===" -ForegroundColor Yellow
    $endTime = Get-Date
    $duration = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=room-rentals mode=WhatIf status=success duration=${duration}s totalTxns=$($result.total_transactions) copiedFiles=0 tasRows=0" `
        -Files @($PSCommandPath)
    exit 0
}

Write-Host "`n=== Step 2: Copy + rename Zoho CSVs to bank statement folders ===" -ForegroundColor Cyan
$copied = 0
foreach ($a in $result.accounts) {
    if (-not $a.csvFile) { continue }
    $map = $accountMap | Where-Object { $_.name -eq $a.account }
    if (-not $map) {
        Write-Warning "No folder mapping for account $($a.account) -- skipping"
        continue
    }
    $src = "${containerId}:/app/zoho-transactions/room-rentals/$($a.csvFile)"
    $dst = "$bankDir\$($map.folder)\$($map.zoho)"
    try {
        docker cp $src $dst | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp exit code $LASTEXITCODE" }
        Write-Host "  $($a.label): $($a.csvFile) -> $($map.folder)\$($map.zoho)" -ForegroundColor Green
        $copied++
    } catch {
        Write-Warning "  $($a.label): copy failed - $_"
        if (-not $ContinueOnError) { throw }
    }
}
if ($copied -eq 0) {
    Write-Host "  No CSVs to copy (Plaid not linked for rental accounts -- see Tasks/ToDo/to-do.md)" -ForegroundColor Yellow
    Write-Host "  Run will continue with raw bank CSVs (Jan-Jun 10) for TAS rebuild." -ForegroundColor Yellow
}

Write-Host "`n=== Step 3: Backup current TAS ===" -ForegroundColor Cyan
$backupPath = "$booksRoot\TAS-2026.bak"
$tasChanged = $false
if (Test-Path $tasPath) {
    Copy-Item -LiteralPath $tasPath -Destination $backupPath -Force
    Write-Host "  Backup saved: $backupPath" -ForegroundColor Green
}

Write-Host "`n=== Step 3b: Regenerate TAS-2026.csv ===" -ForegroundColor Cyan
& "$repoRoot\Skills\Bookkeeping\Scripts\reconciliation\Build-TAS.ps1"

# Read TAS row count from the regenerated file
$tasRows = 0
if (Test-Path $tasPath) {
    foreach ($line in (Get-Content $tasPath -TotalCount 10 -ErrorAction SilentlyContinue)) {
        if ($line -match "^# Total transactions:\s*(\d+)") {
            $tasRows = [int]$Matches[1]
            break
        }
    }
}

# Detect manual edits by comparing backup with regenerated TAS
if (Test-Path $backupPath) {
    $diffOutput = & git diff --no-index -- "$backupPath" "$tasPath" 2>&1
    if ($LASTEXITCODE -ne 0 -and $diffOutput) {
        $tasChanged = $true
        $changeCount = ($diffOutput | Select-String -Pattern '^[+-].' | Where-Object { $_ -notmatch '^[+-]#' } | Measure-Object).Count
        if ($changeCount -gt 0) {
            Write-Host "  WARNING: TAS content differs from backup ($changeCount data-line changes)" -ForegroundColor Yellow
            Write-Host "  Manual edits detected — backup preserved at: $backupPath" -ForegroundColor Yellow
            Write-Host "  Run: git diff --no-index `"$backupPath`" `"$tasPath`" to review changes" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  TAS unchanged from backup — no manual edits to reconcile" -ForegroundColor Green
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Step 4: Check email for new receipts ===" -ForegroundColor Cyan
$emailBody = @{mailbox = "receipts_rentals"; since_days = 30; download = $true; download_dir = "/data/receipts/room-rentals/ingest"} | ConvertTo-Json
$emailResult = Invoke-RestMethod -Uri "http://localhost:21008/sources/check-email" -Method POST `
    -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
    -Body $emailBody
$newReceipts = $emailResult.total_downloaded
if ($newReceipts -gt 0) {
    Write-Host "  Downloaded $newReceipts new receipt(s) from email" -ForegroundColor Green
    # Process downloaded invoices: convert PDFs, move to receipts dir, update manifest
    $ingestDir = "$booksRoot\2026 Receipts\ingest"
    if (-not (Test-Path $ingestDir)) { New-Item -ItemType Directory -Path $ingestDir -Force | Out-Null }
    $converterPy = "$repoRoot\Skills\Bookkeeping\Scripts\pdf\convert-pdf-invoice-to-sidecar.py"
    # Copy new files from container ingest dir to host
    $containerFiles = docker exec $containerId ls /data/receipts/room-rentals/ingest/ 2>$null
    if ($containerFiles) {
        $containerFiles -split "`n" | ForEach-Object { $fn = $_.Trim(); if ($fn -and $fn -ne "logo.png") {
            docker cp "${containerId}:/data/receipts/room-rentals/ingest/$fn" "$ingestDir\$fn" 2>$null
            Write-Host "    Copied: $fn" -ForegroundColor Gray
        }}
        # Run invoice converter on each PDF
        Get-ChildItem "$ingestDir\*.pdf" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    Converting: $($_.Name)" -ForegroundColor Gray
            & python $converterPy $_.FullName 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        # Move converted files to receipt folders (FRA vs TD based on amount/description)
        $receiptDir = "$booksRoot\2026 Receipts"
        Get-ChildItem "$ingestDir\*.pdf", "$ingestDir\*.csv", "$ingestDir\*.md" -ErrorAction SilentlyContinue | ForEach-Object {
            $dest = if ($_.Name -match "83.95.*Internet") { "$receiptDir\TD" } else { $receiptDir }
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Move-Item $_.FullName "$dest\" -Force
            Write-Host "    Filed: $($_.Name) -> $(Split-Path $dest -Leaf)" -ForegroundColor Gray
        }
        # Update manifest
        & "$PSScriptRoot\update-manifest.ps1" -ReceiptsDir $receiptDir 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    Manifest update: skipped (update-manifest.ps1 not found or failed)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  No new receipts found in email" -ForegroundColor Yellow
}

# Record email check timestamp
$emailCheckFile = "$booksRoot\email-last-checked.json"
$emailCheckRecord = [ordered]@{
    checked_at = (Get-Date).ToString('o')
    mailbox    = "receipts_rentals"
    checked_by = "Invoke-RoomRentalsMonthlyUpdate.ps1"
    downloaded = if ($emailResult.total_downloaded) { $emailResult.total_downloaded } else { 0 }
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($emailCheckFile, ($emailCheckRecord | ConvertTo-Json), $utf8NoBom)
Write-Host "  Email check recorded: $($emailCheckFile)" -ForegroundColor Gray

Write-Host "`n=== Step 5: Update organization status ===" -ForegroundColor Cyan
& "$PSScriptRoot\Invoke-StatusCheck.ps1" -Organization room-rentals

# Read status dates for the event log
$statusTxDate = ""; $statusRcDate = ""; $statusReconDate = ""
$statusFile = "$booksRoot\room-rentals-status.json"
if (Test-Path $statusFile) {
    $st = Get-Content $statusFile -Raw | ConvertFrom-Json
    $statusTxDate = if ($st.cloud_transaction_complete_date) { $st.cloud_transaction_complete_date } else { "" }
    $statusRcDate = if ($st.cloud_receipt_complete_date) { $st.cloud_receipt_complete_date } else { "" }
    $statusReconDate = if ($st.reconciliation_date) { $st.reconciliation_date } else { "" }
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "Room Rentals books updated." -ForegroundColor Green

$endTime = Get-Date
$duration = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
$endFiles = @($PSCommandPath, $tasPath, $statusFile) | Where-Object { Test-Path $_ }
Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
    -Detail "entity=room-rentals mode=Real status=success duration=${duration}s totalTxns=$($result.total_transactions) copiedFiles=$copied tasRows=$tasRows txComplete=$statusTxDate receiptComplete=$statusRcDate reconDate=$statusReconDate" `
    -Files $endFiles
