<#
.SYNOPSIS
    Archive completed bookkeeping data to intersite-docs for permanent record.
.DESCRIPTION
    Copies processed receipts, bank statements, and reconciliation reports
    to ~/intersite-docs/Taxes and Bookkeeping/<entity> for archival.
    Run after all pipeline stages are complete.
.PARAMETER Entity
    Which entity to archive: "intersite-consulting" or "room-rentals".
.PARAMETER Year
    Fiscal year label (e.g., "2026"). Defaults to current year.
.PARAMETER DryRun
    Preview files to be archived without copying.
.EXAMPLE
    .\Invoke-BookkeepingArchive.ps1 -Entity intersite-consulting -Year 2026
    Archive Intersite Consulting for fiscal 2026.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [string]$Year = (Get-Date -Format "yyyy"),

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$DocsRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"

# Load entity config
$configPaths = @(
    Join-Path $PSScriptRoot ".." "cloud-books-entities.json"
    Join-Path (Resolve-Path "$PSScriptRoot\..") "cloud-books-entities.json"
)
$configPath = $null
foreach ($cp in $configPaths) { if (Test-Path $cp) { $configPath = (Resolve-Path $cp).Path; break } }
if (-not $configPath) { Write-Error "cloud-books-entities.json not found"; exit 1 }

$entitiesConfig = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
$ec = $entitiesConfig.entities[$Entity]
if (-not $ec) { Write-Error "Entity '$Entity' not found in config"; exit 1 }

$displayName = if ($ec.display_name) { $ec.display_name } else { $Entity }
$receiptDir = $ec.receipt_dir

$sourceRoot = Join-Path $DocsRoot $Entity
$destDir = Join-Path $DocsRoot $Entity "$Year - Receipts"

Write-Host "=== Archiving: $displayName ===" -ForegroundColor Cyan
Write-Host "  Archive dir: $destDir" -ForegroundColor Gray

if (-not (Test-Path $destDir)) {
    Write-Warning "Archive directory does not exist. Creating it..."
    New-Item -ItemType Directory -Path "$destDir\Complete" -Force | Out-Null
    New-Item -ItemType Directory -Path "$destDir\Bank Statements" -Force | Out-Null
}

# 1. Copy Complete/ receipts
$srcComplete = Join-Path $sourceRoot $receiptDir "Complete"
if (Test-Path $srcComplete) {
    $files = Get-ChildItem -Path $srcComplete
    Write-Host "  Receipt files to archive: $($files.Count)" -ForegroundColor Gray
    if (-not $DryRun) {
        Copy-Item -Path "$srcComplete\*" -Destination "$destDir\Complete\" -Recurse -Force
        Write-Host "  ✓ Copied receipts to $destDir\Complete\" -ForegroundColor Green
    }
} else {
    Write-Warning "  Source Complete/ not found: $srcComplete"
}

# 2. Copy bank statements
$srcBank = Join-Path $sourceRoot "$Year Fiscal Year - Bank Statements"
if (-not (Test-Path $srcBank)) {
    $srcBank = Join-Path $sourceRoot "$Year Bank Statements"
}
if (Test-Path $srcBank) {
    $bankDirs = Get-ChildItem -Path $srcBank -Directory
    $bankFiles = Get-ChildItem -Path $srcBank -File
    $totalBank = $bankDirs.Count + $bankFiles.Count
    Write-Host "  Bank statement items to archive: $totalBank" -ForegroundColor Gray
    if (-not $DryRun) {
        Copy-Item -Path "$srcBank\*" -Destination "$destDir\Bank Statements\" -Recurse -Force
        Write-Host "  ✓ Copied bank statements to $destDir\Bank Statements\" -ForegroundColor Green
    }
} else {
    Write-Warning "  Source bank statements not found: $srcBank"
}

# 3. Copy reconciliation CSV
$reconCsv = Join-Path $DocsRoot "$Entity-reconciliation.csv"
if (Test-Path $reconCsv) {
    Write-Host "  Reconciliation report: $reconCsv" -ForegroundColor Gray
    if (-not $DryRun) {
        Copy-Item -Path $reconCsv -Destination "$destDir\" -Force
        Write-Host "  ✓ Copied reconciliation report" -ForegroundColor Green
    }
} else {
    Write-Host "  No reconciliation report found (run reconciliation first)" -ForegroundColor Yellow
}

# 4. Copy unmatched receipts
$unmatchedCsv = Join-Path $DocsRoot "$Entity-unmatched-receipts.csv"
if (Test-Path $unmatchedCsv) {
    Write-Host "  Unmatched receipts report: $unmatchedCsv" -ForegroundColor Gray
    if (-not $DryRun) {
        Copy-Item -Path $unmatchedCsv -Destination "$destDir\" -Force
        Write-Host "  ✓ Copied unmatched receipts report" -ForegroundColor Green
    }
}

# 5. Copy enriched state (Process-ReceiptsState)
$statePath = Join-Path $sourceRoot "Process-ReceiptsState"
if (Test-Path $statePath) {
    $stateFiles = Get-ChildItem -Path $statePath -Filter "*.json"
    Write-Host "  State files: $($stateFiles.Count)" -ForegroundColor Gray
    if (-not $DryRun) {
        Copy-Item -Path "$statePath\*.json" -Destination "$destDir\" -Force
        Write-Host "  ✓ Copied processing state" -ForegroundColor Green
    }
}

# 6. Write archive manifest
if (-not $DryRun) {
    $receiptCount = (Get-ChildItem "$destDir\Complete\*.jpg", "$destDir\Complete\*.pdf" -ErrorAction SilentlyContinue).Count
    $manifest = @{
        Entity          = $displayName
        Year            = $Year
        ArchivedAt      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ReceiptCount    = $receiptCount
        SourceReceipts  = $receiptDir
        SourceBank      = "$Year Fiscal Year - Bank Statements"
        HasReconciliation = (Test-Path "$destDir\*-reconciliation.csv")
        PipelineStages  = @{
            Extraction   = $true
            Enrichment   = $true
            ZohoUpload   = $false
            Reconciliation = (Test-Path "$destDir\*-reconciliation.csv")
            Archive      = $true
        }
    }
    $manifest | ConvertTo-Json | Out-File "$destDir\_archive-manifest.json" -Force
    Write-Host "  ✓ Wrote archive manifest" -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Cyan
