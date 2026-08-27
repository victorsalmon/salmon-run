<#
.SYNOPSIS
    DEPRECATED — superseded by the PRP pipeline (Invoke-PrpOrgPipeline.ps1).
    Data gathering is now Step DG of the Pre-Recon Pipeline. Run:
      .\Invoke-PrpOrgPipeline.ps1 -OrgName "intersite-consulting"
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
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting"
$bankDir = "$booksRoot\2026 Filing\2026 Bank Statements"
$tasPath = "$booksRoot\TAS-2026.csv"

# Workflow event logging -- write directly to workflow-events.log.
# The Write-WorkflowEvent function is broken on PowerShell 5.1 (uses a
# 3-arg Join-Path that only works in PS 7+). Patching the function
# is a separate concern; we want the wrappers to work on both.
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
    -Detail "entity=intersite-consulting mode=$mode startedAt=$($startTime.ToString('o'))" `
    -Files @($PSCommandPath)

$containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}"
if (-not $containerId) {
    Write-Error "Bookkeeping container not running -- is the fleet deployed?"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=intersite-consulting mode=$mode status=error reason=accountant_container_down" `
        -Files @($PSCommandPath)
    exit 1
}
$token = docker exec $containerId cat /run/secrets/fleet_api_token 2>$null
if (-not $token) {
    Write-Error "Could not get Bookkeeper API token"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=intersite-consulting mode=$mode status=error reason=token_unavailable" `
        -Files @($PSCommandPath)
    exit 1
}

Write-Host "=== Step 1: Export Zoho Plaid transactions ===" -ForegroundColor Cyan
$body = @{dry_run = [bool]$WhatIf; entity = "intersite-consulting"} | ConvertTo-Json
$result = Invoke-RestMethod -Uri "http://localhost:21008/zoho/transactions/export" -Method POST `
    -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
    -Body $body

if (-not $result.success) {
    Write-Error "Export failed: $($result | ConvertTo-Json)"
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=intersite-consulting mode=$mode status=error reason=export_failed" `
        -Files @($PSCommandPath)
    exit 1
}
Write-Host "  RBC: $($result.accounts[0].transactions) txns  $($result.accounts[0].csvFile)" -ForegroundColor Green
Write-Host "  MC:  $($result.accounts[1].transactions) txns  $($result.accounts[1].csvFile)" -ForegroundColor Green

if ($WhatIf) {
    Write-Host "`n=== Step 2: Copy to bank statements (SKIP -- WhatIf) ===" -ForegroundColor Yellow
    Write-Host "=== Step 3: Build TAS (SKIP -- WhatIf) ===" -ForegroundColor Yellow
    $endTime = Get-Date
    $duration = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
    Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
        -Detail "entity=intersite-consulting mode=WhatIf status=success duration=${duration}s totalTxns=$($result.total_transactions) copiedFiles=0 tasRows=0" `
        -Files @($PSCommandPath)
    exit 0
}

Write-Host "`n=== Step 2: Copy bank statements to local (merge mode) ===" -ForegroundColor Cyan

function Merge-ZohoCsv {
    param(
        [string]$ExistingPath,
        [string]$FreshPath
    )
    if (-not (Test-Path $FreshPath)) { Write-Host "  Fresh export not found at $FreshPath — skipping merge" -ForegroundColor Yellow; return }
    if (-not (Test-Path $ExistingPath)) {
        Write-Host "  No existing ref file at $ExistingPath — using fresh export as-is" -ForegroundColor Yellow
        Move-Item -LiteralPath $FreshPath -Destination $ExistingPath -Force
        return
    }

    $existingLines = Get-Content $ExistingPath
    $freshLines = Get-Content $FreshPath

    $headerEnd = 0
    for ($i = 0; $i -lt $existingLines.Count; $i++) {
        if ($existingLines[$i] -notmatch '^#') { $headerEnd = $i; break }
    }
    $headerLines = $existingLines[0..($headerEnd - 1)]

    $colHeaderLine = $existingLines[$headerEnd]
    $existingDataLines = $existingLines[($headerEnd + 1)..($existingLines.Count - 1)]

    $freshDataStart = 0
    for ($i = 0; $i -lt $freshLines.Count; $i++) {
        if ($freshLines[$i] -notmatch '^#') { $freshDataStart = $i + 1; break }
    }
    $freshDataLines = $freshLines[$freshDataStart..($freshLines.Count - 1)]

    $existingIds = @{}
    foreach ($line in $existingDataLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line -split ','
        if ($cols.Count -gt 5 -and $cols[5]) { $existingIds[$cols[5].Trim()] = $true }
    }

    $newCount = 0
    foreach ($line in $freshDataLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line -split ','
        if ($cols.Count -gt 5 -and $cols[5] -and -not $existingIds.ContainsKey($cols[5].Trim())) {
            $existingDataLines += $line
            $existingIds[$cols[5].Trim()] = $true
            $newCount++
        }
    }

    $totalCount = $existingDataLines.Count
    $generatedDate = (Get-Date -Format 'yyyy-MM-dd')
    $sourceName = if ($ExistingPath -match '(RBC|MC)') { $Matches[1] } else { "Zoho" }

    $newHeader = @(
        "# Source: Zoho Books API (Plaid-synced transactions) - MERGED",
        "# Account: $sourceName",
        "# Generated: $generatedDate",
        "# Transactions: $totalCount",
        "# Merged from: existing ($($existingDataLines.Count - $newCount) txns) + latest export ($newCount new txns)",
        $colHeaderLine
    )

    $mergedContent = $newHeader + $existingDataLines
    $mergedContent | Set-Content -Path $ExistingPath -Encoding utf8
    Write-Host "  ${sourceName}: merged ($newCount new, $totalCount total)" -ForegroundColor Green
    return $newCount
}

$copied = 0

function Copy-CsvFromContainer {
    param([string]$ContainerId, [string]$RemotePath, [string]$LocalPath, [string]$Label)
    try {
        docker cp "${ContainerId}:${RemotePath}" $LocalPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker cp exit code $LASTEXITCODE" }
        return $true
    } catch {
        Write-Warning "  ${Label}: copy failed - $_"
        return $false
    }
}

$rbcDir = "$bankDir\RBC-INTERSITE"
$rbcSrc = "$($result.accounts[0].csvFile)"
$rbcTemp = Join-Path $rbcDir "temp-$rbcSrc"
$rbcOk = Copy-CsvFromContainer -ContainerId $containerId -RemotePath "/app/zoho-transactions/intersite-consulting/$rbcSrc" -LocalPath $rbcTemp -Label $result.accounts[0].label
if ($rbcOk) {
    $rbcExisting = Join-Path $rbcDir (Get-ChildItem -Path $rbcDir -Filter "*Present*Zoho*" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty Name)
    if (-not $rbcExisting) { $rbcExisting = Join-Path $rbcDir $rbcSrc }
    Merge-ZohoCsv -ExistingPath $rbcExisting -FreshPath $rbcTemp
    Remove-Item -LiteralPath $rbcTemp -Force -ErrorAction SilentlyContinue
    $copied++
} elseif (-not $ContinueOnError) { throw "RBC CSV copy failed" }

$mcDir = "$bankDir\MC 6241 (6258)"
$mcSrc = "$($result.accounts[1].csvFile)"
$mcTemp = Join-Path $mcDir "temp-$mcSrc"
$mcOk = Copy-CsvFromContainer -ContainerId $containerId -RemotePath "/app/zoho-transactions/intersite-consulting/$mcSrc" -LocalPath $mcTemp -Label $result.accounts[1].label
if ($mcOk) {
    $mcExisting = Join-Path $mcDir (Get-ChildItem -Path $mcDir -Filter "*Present*Zoho*" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty Name)
    if (-not $mcExisting) { $mcExisting = Join-Path $mcDir $mcSrc }
    Merge-ZohoCsv -ExistingPath $mcExisting -FreshPath $mcTemp
    Remove-Item -LiteralPath $mcTemp -Force -ErrorAction SilentlyContinue
    $copied++
} elseif (-not $ContinueOnError) { throw "MC CSV copy failed" }

Write-Host "`n=== Step 3: Backup current TAS ===" -ForegroundColor Cyan
$backupPath = "$booksRoot\TAS-2026.bak"
$tasChanged = $false
if (Test-Path $tasPath) {
    Copy-Item -LiteralPath $tasPath -Destination $backupPath -Force
    Write-Host "  Backup saved: $backupPath" -ForegroundColor Green
}

Write-Host "`n=== Step 3b: Regenerate TAS ===" -ForegroundColor Cyan
& "$repoRoot\Skills\Bookkeeping\Scripts\reconciliation\Build-IntersiteTAS.ps1"

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
        # Count non-header changed lines
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

Write-Host "`n=== Step 4: Update organization status ===" -ForegroundColor Cyan
& "$PSScriptRoot\Invoke-StatusCheck.ps1" -Organization intersite-consulting

# Read status dates for the event log
$statusTxDate = ""; $statusRcDate = ""; $statusReconDate = ""
$statusFile = "$booksRoot\intersite-consulting-status.json"
if (Test-Path $statusFile) {
    $st = Get-Content $statusFile -Raw | ConvertFrom-Json
    $statusTxDate = if ($st.cloud_transaction_complete_date) { $st.cloud_transaction_complete_date } else { "" }
    $statusRcDate = if ($st.cloud_receipt_complete_date) { $st.cloud_receipt_complete_date } else { "" }
    $statusReconDate = if ($st.reconciliation_date) { $st.reconciliation_date } else { "" }
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "Intersite Consulting books updated with latest Zoho Plaid transactions." -ForegroundColor Green

$endTime = Get-Date
$duration = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
$endFiles = @($PSCommandPath, $tasPath, $statusFile) | Where-Object { Test-Path $_ }
Emit-MonthlyUpdateEvent -Type "MONTHLY_UPDATE_END" `
    -Detail "entity=intersite-consulting mode=Real status=success duration=${duration}s totalTxns=$($result.total_transactions) copiedFiles=$copied tasRows=$tasRows txComplete=$statusTxDate receiptComplete=$statusRcDate reconDate=$statusReconDate" `
    -Files $endFiles
