# Bookkeeping Archive — Receipt Archival to intersite-docs

## Overview

After receipts are processed (extracted, enriched, uploaded to Zoho, and reconciled), the source files should be archived to `~/intersite-docs/Taxes and Bookkeeping/` for permanent record. Archiving happens **after a year is complete** — the books are finalized, no more receipts are expected for that period.

## Year Definition Per Entity

| Entity | Year Type | Current Year | Period |
|--------|-----------|-------------|--------|
| Victor Salmon Room Rentals | Calendar year | 2026 | Jan 1 → Dec 31 |
| Intersite Consulting Inc. | Fiscal year | Fiscal 2026 | Apr 1, 2025 → Mar 31, 2026 |

Fiscal years are named after the **completion year** (e.g., Apr 2025 – Mar 2026 = "Fiscal 2026").

## Archive Directory Structure

```
~/intersite-docs/Taxes and Bookkeeping/
├── room-rentals/
│   └── 2026 - Receipts/
│       ├── manifest.csv
│       ├── Complete/
│       │   ├── original-files...
│       │   └── manifest.csv
│       └── (other years as completed)
├── intersite-consulting/
│   └── Fiscal 2026 - Receipts/
│       ├── manifest.csv
│       ├── Complete/
│       │   ├── original-files...
│       │   └── manifest.csv
│       └── (other fiscal years as completed)
```

## What Gets Archived

| Item | Source | Destination |
|------|--------|-------------|
| Manifest CSV | Complete/manifest.csv | Archive root + copy in Complete/ subfolder |
| Receipt images (JPGs) | `Complete/*.jpg` | `Complete/` subfolder |
| Merged PDFs | `Complete/*.pdf` | `Complete/` subfolder |
| Sidecar JSON files | `Complete/*.jpg.json` | `Complete/` subfolder |
| Enriched manifest | `Process-ReceiptsState/*.json` | Archive root |
| Bank statements | `2026 Bank Statements/` | Archive root, as `Bank Statements/` subfolder |
| Reconciliation CSVs | `*-reconciliation.csv` | Archive root |

## Procedure

### 1. Identify Completed Year

```powershell
function Get-ArchiveYear {
    param([string]$EntitySlug)
    switch ($EntitySlug) {
        "room-rentals" {
            # Calendar year: archive when current date > Dec 31 of target year
            $year = (Get-Date).Year - 1
            return @{ Label = "$year"; Path = "$year - Receipts" }
        }
        "intersite-consulting" {
            # Fiscal year: archive when current date > Mar 31 of completion year
            $now = Get-Date
            if ($now.Month -ge 4) {
                $fyLabel = $now.Year
            } else {
                $fyLabel = $now.Year - 1
            }
            $completedFy = $fyLabel - 1  # Previous fiscal year is complete
            return @{ Label = "Fiscal $completedFy"; Path = "Fiscal $completedFy - Receipts" }
        }
    }
}
```

### 2. Copy Files to Archive

```powershell
function Invoke-BookkeepingArchive {
    param(
        [string]$EntitySlug,
        [string]$EntityDisplayName,
        [string]$SourceReceiptsDir,   # e.g., "2026.05.21 - Receipts - room-rentals"
        [string]$BankStatementsDir,   # e.g., "2026 Bank Statements"
        [string]$ReconciliationCsv,   # e.g., "room-rentals-reconciliation.csv"
        [string]$ArchiveRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"
    )

    $yearInfo = Get-ArchiveYear -EntitySlug $EntitySlug
    $destDir = Join-Path $ArchiveRoot $EntitySlug $yearInfo.Path
    New-Item -ItemType Directory -Path "$destDir\Complete" -Force | Out-Null
    New-Item -ItemType Directory -Path "$destDir\Bank Statements" -Force | Out-Null

    # Copy Complete/ receipt files
    if (Test-Path $SourceReceiptsDir) {
        Copy-Item -Path "$SourceReceiptsDir\Complete\*" -Destination "$destDir\Complete\" -Recurse -Force
        Write-Host "Copied receipts to $destDir\Complete\"
    }

    # Copy enriched state
    $stateDir = "Process-ReceiptsState"
    if (Test-Path $stateDir) {
        Copy-Item -Path "$stateDir\*.json" -Destination "$destDir\" -Force
    }

    # Copy bank statements
    if (Test-Path $BankStatementsDir) {
        Copy-Item -Path "$BankStatementsDir\*" -Destination "$destDir\Bank Statements\" -Recurse -Force
        Write-Host "Copied bank statements to $destDir\Bank Statements\"
    }

    # Copy reconciliation CSV
    if ($ReconciliationCsv -and (Test-Path $ReconciliationCsv)) {
        Copy-Item -Path $ReconciliationCsv -Destination "$destDir\" -Force
        Write-Host "Copied reconciliation CSV"
    }

    # Write archive manifest
    $archiveManifest = @{
        Entity = $EntityDisplayName
        Year = $yearInfo.Label
        ArchivedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ReceiptCount = (Get-ChildItem "$destDir\Complete\*.jpg","$destDir\Complete\*.pdf" -ErrorAction SilentlyContinue).Count
        SourceDir = $SourceReceiptsDir
        BankStatementsDir = $BankStatementsDir
        Reconciliation = $ReconciliationCsv
    }
    $archiveManifest | ConvertTo-Json | Out-File "$destDir\_archive-manifest.json" -Force
    Write-Host "Archive manifest written to $destDir\_archive-manifest.json"
}
```

## Current Year Status

Project-specific status is tracked in `~/intersite-docs/Documentation/Memory/mem-bookkeeping-intersite.md` (client repo — resolve via `_project-map.json`).

## Gotchas

1. **Fiscal year naming:** Intersite Fiscal 2026 = Apr 2025 → Mar 2026. Do NOT name it "Fiscal 2025" — the year is named after the completion year.
2. **Calendar year naming:** Room-rentals 2026 = Jan 1 → Dec 31. Simple.
3. **Archive only after reconciliation.** Do not archive incomplete years — reconciliation flags discrepancies that need source files for reference.
4. **Do not delete source files after archiving.** The `intersite-docs/` archive is a COPY. Source directories in the working tree remain until the next cleanup cycle.
5. **The current fiscal year for intersite (Apr 2025 – Mar 2026) ended March 31, 2026** — it is overdue for finalization. Prioritize this.
