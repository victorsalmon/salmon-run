<#
.SYNOPSIS
    Post-process Resolve-OrphanReceipts.RECONCILIATION-REPORT.csv into the
    RECONCILIATION-SUMMARY.md and UNMATCHED-README.md artifacts that the main
    script's heredoc blocks fail to emit when invoked from the bash tool.

.DESCRIPTION
    [Used by: Skills/Bookkeeping/processing/orphan-reconciliation.md]
    [Pester tests: Skills/Docker/Tests/Bookkeeper.OrphanReconciliation.Tests.ps1]

    Auto-invoked by Resolve-OrphanReceipts.ps1 (Stage 1) after the per-orphan
    CSV is written. Reads the per-orphan reconciliation report produced by
    Resolve-OrphanReceipts.ps1 (run earlier, with or without -Apply) and emits:
      - RECONCILIATION-SUMMARY.md — strategy counts + apply actions log
      - UNMATCHED-README.md — per-bucket unmatched file list

    Use this only when Resolve-OrphanReceipts.ps1 was already run and produced
    RECONCILIATION-REPORT.csv but the markdown artifacts were not written.
    The array-join approach here avoids the heredoc-with-subexpression failure
    mode that affects the main script when invoked from the opencode bash tool.
#>
[CmdletBinding()]
param(
    [string]$OrphansDir = (Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts\_orphans"),
    [string]$ReportPath,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

if (-not $ReportPath) { $ReportPath = Join-Path $OrphansDir "RECONCILIATION-REPORT.csv" }
$SummaryPath = Join-Path $OrphansDir "RECONCILIATION-SUMMARY.md"
$UnmatchedPath = Join-Path $OrphansDir "UNMATCHED-README.md"

if (-not (Test-Path $ReportPath)) { Write-Error "Report not found: $ReportPath"; exit 1 }

$rows = Import-Csv $ReportPath
$stats = @{
    Total           = $rows.Count
    ExactDuplicate  = ($rows | Where-Object { $_.MatchedStatus -eq "exact-duplicate" }).Count
    ExactTasMatch   = ($rows | Where-Object { $_.MatchedStatus -eq "exact-tas-match" }).Count
    FuzzyTasMatch   = ($rows | Where-Object { $_.MatchedStatus -eq "fuzzy-tas-match" }).Count
    FilenameDuplicate = ($rows | Where-Object { $_.MatchedStatus -eq "filename-duplicate" }).Count
    ArchiveTarget   = ($rows | Where-Object { $_.SuggestedAction -eq "archive" }).Count
    PromoteTarget   = ($rows | Where-Object { $_.SuggestedAction -eq "promote" }).Count
    Unmatched       = ($rows | Where-Object { $_.MatchedStatus -eq "unmatched" }).Count
}
$dateAmountFound = ($rows | Where-Object { $_.ExtractedDate -and $_.ExtractedAmount }).Count

Write-Host "Report rows: $($rows.Count)" -ForegroundColor Cyan
Write-Host "Strategy 1 (exact dupe):    $($stats.ExactDuplicate)"
Write-Host "Strategy 2 (exact TAS):     $($stats.ExactTasMatch)"
Write-Host "Strategy 3 (fuzzy TAS):     $($stats.FuzzyTasMatch)"
Write-Host "Strategy 4 (filename dupe): $($stats.FilenameDuplicate)"
Write-Host "→ archive:                  $($stats.ArchiveTarget)"
Write-Host "→ promote:                  $($stats.PromoteTarget)"
Write-Host "unmatched:                  $($stats.Unmatched)"

$runMode = if ($Apply) { 'APPLY' } else { 'Report-only' }

# ─── RECONCILIATION-SUMMARY.md ────────────────────────────────────────────────
$summaryLines = @(
    "# Orphan Reconciliation Summary",
    "",
    "**Generated**: $(Get-Date -Format 'o')",
    "**Mode**: $runMode",
    "**Orphans dir**: ``$OrphansDir``",
    "",
    "## Counts",
    "",
    "| Bucket | Count |",
    "|---|---|",
    "| Total scanned | $($stats.Total) |",
    "| With date+amount in filename | $dateAmountFound |",
    "| **Strategy 1** — exact manifest duplicate | $($stats.ExactDuplicate) |",
    "| **Strategy 2** — exact TAS gap match | $($stats.ExactTasMatch) |",
    "| **Strategy 3** — fuzzy TAS gap match | $($stats.FuzzyTasMatch) |",
    "| **Strategy 4** — filename duplicate | $($stats.FilenameDuplicate) |",
    "| → Suggested archive | $($stats.ArchiveTarget) |",
    "| → Suggested promote | $($stats.PromoteTarget) |",
    "| Unmatched | $($stats.Unmatched) |",
    "",
    "## Per-orphan detail",
    "",
    "See ``RECONCILIATION-REPORT.csv`` for the full per-file table.",
    "",
    "## Apply actions",
    "",
    $(if (-not $Apply) {
        "Run with ``-Apply`` to actually move files (archive duplicates to ``_orphans/archived/`` and promote matched files to their per-account directory)."
    } else {
        "Applied: archived duplicates and promoted matched files. See archive count above."
    }),
    ""
)
$summary = $summaryLines -join "`n"
$summary | Out-File -FilePath $SummaryPath -Encoding UTF8 -Force
Write-Host "Wrote: $SummaryPath" -ForegroundColor Green

# ─── UNMATCHED-README.md ─────────────────────────────────────────────────────
$unmatchedRows = $rows | Where-Object { $_.MatchedStatus -eq "unmatched" }
$noDateList = @($unmatchedRows | Where-Object { -not $_.ExtractedDate -or -not $_.ExtractedAmount })
$withDateList = @($unmatchedRows | Where-Object { $_.ExtractedDate -and $_.ExtractedAmount })

$noDateLines = @()
foreach ($f in ($noDateList | Select-Object -First 50)) {
    $noDateLines += "- ``$($f.Filename)``"
}
if ($noDateList.Count -gt 50) {
    $noDateLines += ""
    $noDateLines += "_… and $($noDateList.Count - 50) more (see RECONCILIATION-REPORT.csv)_"
}
$noDateBlock = if ($noDateLines.Count -gt 0) { $noDateLines -join "`n" } else { "_None_" }

$withDateLines = @()
foreach ($f in ($withDateList | Select-Object -First 50)) {
    $withDateLines += "- ``$($f.Filename)`` (date=$($f.ExtractedDate), amount=`$$($f.ExtractedAmount))"
}
if ($withDateList.Count -gt 50) {
    $withDateLines += ""
    $withDateLines += "_… and $($withDateList.Count - 50) more (see RECONCILIATION-REPORT.csv)_"
}
$withDateBlock = if ($withDateLines.Count -gt 0) { $withDateLines -join "`n" } else { "_None_" }

$unmatchedLines = @(
    "# Unmatched Orphans",
    "",
    "**Generated**: $(Get-Date -Format 'o')",
    "**Source**: ``$OrphansDir``",
    "**Run mode**: $runMode",
    "",
    "## Summary",
    "",
    "- **Total unmatched**: $($unmatchedRows.Count)",
    "- **No date+amount in filename** (UUID / random names — needs manual review or OCR): $($noDateList.Count)",
    "- **Has date+amount but no TAS match** (older years, refunds, internal transfers, room-rentals misplaced): $($withDateList.Count)",
    "",
    "## Bucket 1 — No date+amount in filename ($($noDateList.Count) files)",
    "",
    "These files have UUID-style or random names. They likely came from automated",
    "downloaders (Amazon order pages, browser saves) and never went through the",
    "filename renamer that prefixes the date and amount. They cannot be matched",
    "by key. Action: open each in a viewer and either:",
    "1. Rename to ``YYYY-MM-DD - AMOUNT - VENDOR.ext`` to enable re-matching, or",
    "2. Archive to ``archived/no-date-amount/`` if the content is irrelevant.",
    "",
    $noDateBlock,
    "",
    "## Bucket 2 — Has date+amount but no TAS match ($($withDateList.Count) files)",
    "",
    "These files have parseable date+amount but no corresponding TAS transaction.",
    "Likely causes:",
    "- Pre-2025 receipts (TAS only covers 2025-2026)",
    "- Refunds, credits, or intersite internal transfers (not in TAS)",
    "- Files for room-rentals accidentally placed in intersite-consulting",
    "- Files for amounts with small differences vs TAS (tax-inclusive vs exclusive)",
    "",
    "Action: review each, and either:",
    "1. Move to a different entity's receipts dir (e.g., room-rentals) if misfiled",
    "2. Rename to flag as non-business (e.g., ``YYYY-MM-DD - AMOUNT - Personal - VENDOR.pdf``)",
    "3. If genuinely unmatched, leave in ``_orphans/`` and re-run after TAS is rebuilt",
    "4. If the file content is irrelevant (test downloads, accidental captures), delete it",
    "",
    $withDateBlock,
    "",
    "## How to use this report",
    "",
    "After reviewing, the suggested actions for the matched buckets are at",
    "``RECONCILIATION-SUMMARY.md``. To actually apply them:",
    "",
    '```powershell',
    "# Archive duplicates only (safest first pass):",
    ".\Resolve-OrphanReceipts.ps1 -Apply -ApplyMode Archive",
    "",
    "# Promote matched files only:",
    ".\Resolve-OrphanReceipts.ps1 -Apply -ApplyMode Promote",
    "",
    "# Both (full apply):",
    ".\Resolve-OrphanReceipts.ps1 -Apply",
    '```',
    ""
)
$unmatchedReadme = $unmatchedLines -join "`n"
$unmatchedReadme | Out-File -FilePath $UnmatchedPath -Encoding UTF8 -Force
Write-Host "Wrote: $UnmatchedPath" -ForegroundColor Green
