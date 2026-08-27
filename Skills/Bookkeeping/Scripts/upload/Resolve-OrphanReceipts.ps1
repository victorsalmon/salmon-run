<#
.SYNOPSIS
    Reconcile orphan receipt files against the unified manifest and TAS to identify
    duplicates, promotable matches, and truly unmatched files.

.DESCRIPTION
    [Used by: Skills/Bookkeeping/processing/orphan-reconciliation.md]
    [Pester tests: Skills/Docker/Tests/Bookkeeper.OrphanReconciliation.Tests.ps1]

    Stage 1 of the two-stage orphan reconciliation workflow (paired with
    Reconcile-ManifestStatus.ps1 for Stage 2). Scans _orphans/ for files that
    Invoke-ReceiptScanAndRebuild.ps1 could not match, runs 4 matching strategies
    to classify each (exact manifest duplicate / exact TAS gap / fuzzy TAS gap /
    filename heuristic), and with -Apply actually moves files to _orphans/archived/
    or per-account dirs while updating _manifest.csv.

    Companion scripts: Format-ReconciliationReports.ps1 (post-process CSV to MD),
    Reconcile-ManifestStatus.ps1 (Stage 2 manifest drift sweep).

.DESCRIPTION
    Used by: Skills/Bookkeeping/processing/orphan-reconciliation.md

.DESCRIPTION
    The _orphans/ directory accumulates files that Invoke-ReceiptScanAndRebuild.ps1
    could not match to any transaction. This script runs four matching strategies
    to categorize each orphan:

    Strategy 1: Exact match against _manifest.csv entries with `status: matched`
                using date+amount key — finds files that duplicate an already-matched
                receipt (multiple downloads, copies, etc.) → ARCHIVE.
    Strategy 2: Exact match against TAS transactions (Zoho-derived) where the
                transaction has no `receipt_filename` in TAS — finds receipts that
                could fill a gap → PROMOTE.
    Strategy 3: Fuzzy match (date ±3 days, amount ±$0.10) against TAS transactions
                without a receipt — fallback for parse-tolerant matching → PROMOTE.
    Strategy 4: Filename heuristic — strip _2, _3 suffixes and check if the base
                filename exists in any per-account directory — finds duplicate copies
                of receipts already filed under their proper account → ARCHIVE.

    The script writes a per-orphan CSV report and a human-readable summary table.
    With -Apply, it actually moves files (archives duplicates to _orphans/archived/,
    promotes matched files to their account subdirectory, updates _manifest.csv).
    Default (no -Apply) is report-only — safe to run anytime.

.PARAMETER OrphansDir
    Path to the _orphans/ directory. Default: intersite-consulting/2026 Filing/Receipts/_orphans

.PARAMETER ManifestPath
    Path to the unified _manifest.csv. Default: <OrphansDir>/../_manifest.csv

.PARAMETER TasPath
    Path to the TAS-2026.csv. Default: <OrphansDir>/../../TAS-2026.csv

.PARAMETER ReceiptsRoot
    Path to the Receipts/ directory (parent of per-account subdirs). Default: <OrphansDir>/..

.PARAMETER ReportPath
    Output CSV path (per-orphan reconciliation results). Default: <OrphansDir>/RECONCILIATION-REPORT.csv

.PARAMETER SummaryPath
    Output markdown summary path. Default: <OrphansDir>/RECONCILIATION-SUMMARY.md

.PARAMETER Apply
    Actually move files (archive duplicates, promote matched) and update _manifest.csv.
    Without this switch, the script runs in report-only mode.

.PARAMETER ApplyMode
    When -Apply is set, controls which actions to perform:
      - All (default): both archive and promote
      - Archive: only archive duplicates
      - Promote: only promote matched

.EXAMPLE
    .\Resolve-OrphanReceipts.ps1
    Report-only run against intersite-consulting. Prints summary, writes CSVs.

.EXAMPLE
    .\Resolve-OrphanReceipts.ps1 -Apply
    Report + actually move files.

.EXAMPLE
    .\Resolve-OrphanReceipts.ps1 -Apply -ApplyMode Archive
    Report + only archive duplicates; leave promotable files in place for manual review.
#>
[CmdletBinding()]
param(
    [string]$OrphansDir = (Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts\_orphans"),

    [string]$ManifestPath,

    [string]$TasPath,

    [string]$ReceiptsRoot,

    [string]$ReportPath,

    [string]$SummaryPath,

    [switch]$Apply,

    [ValidateSet("All", "Archive", "Promote")]
    [string]$ApplyMode = "All"
)

$ErrorActionPreference = "Stop"

# Resolve defaults relative to OrphansDir
if (-not $ManifestPath) { $ManifestPath = Join-Path (Split-Path $OrphansDir -Parent) "_manifest.csv" }
if (-not $TasPath) { $TasPath = Join-Path (Split-Path (Split-Path (Split-Path $OrphansDir -Parent) -Parent) -Parent) "TAS-2026.csv" }
if (-not $ReceiptsRoot) { $ReceiptsRoot = Split-Path $OrphansDir -Parent }
if (-not $ReportPath) { $ReportPath = Join-Path $OrphansDir "RECONCILIATION-REPORT.csv" }
if (-not $SummaryPath) { $SummaryPath = Join-Path $OrphansDir "RECONCILIATION-SUMMARY.md" }

if (-not (Test-Path $OrphansDir)) { Write-Error "Orphans dir not found: $OrphansDir"; exit 1 }
if (-not (Test-Path $ManifestPath)) { Write-Error "Manifest not found: $ManifestPath"; exit 1 }
if (-not (Test-Path $TasPath)) { Write-Error "TAS not found: $TasPath"; exit 1 }

$archivedDir = Join-Path $OrphansDir "archived"
$null = New-Item -ItemType Directory -Path $archivedDir -Force

Write-Host "Orphans dir:    $OrphansDir" -ForegroundColor Gray
Write-Host "Manifest:       $ManifestPath" -ForegroundColor Gray
Write-Host "TAS:            $TasPath" -ForegroundColor Gray
Write-Host "Receipts root:  $ReceiptsRoot" -ForegroundColor Gray
Write-Host "Mode:           $(if ($Apply) { 'APPLY (will move files)' } else { 'Report-only' })" -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Cyan' })
Write-Host ""

# ─── Load manifest ────────────────────────────────────────────────────────────
Write-Host "Loading manifest..." -ForegroundColor Cyan
$manifestRaw = Get-Content $ManifestPath -Raw -Encoding UTF8
$bom = [char]0xFEFF
if ($manifestRaw[0] -eq $bom) { $manifestRaw = $manifestRaw.Substring(1) }
$manifestRows = $manifestRaw | ConvertFrom-Csv
$manifestByKey = @{}  # key = date|amount
foreach ($r in $manifestRows) {
    if (-not $r.date -or -not $r.amount) { continue }
    $key = "$($r.date)|$([math]::Round([math]::Abs([double]$r.amount), 2))"
    if (-not $manifestByKey.ContainsKey($key)) { $manifestByKey[$key] = @() }
    $manifestByKey[$key] += $r
}
$matchedByKey = @{}
foreach ($k in $manifestByKey.Keys) {
    $matched = $manifestByKey[$k] | Where-Object { $_.status -eq "matched" }
    if ($matched) { $matchedByKey[$k] = $matched }
}
Write-Host "  $($manifestRows.Count) total rows, $($matchedByKey.Count) unique matched keys" -ForegroundColor Gray

# ─── Load TAS ─────────────────────────────────────────────────────────────────
Write-Host "Loading TAS..." -ForegroundColor Cyan
$tasRaw = Get-Content $TasPath -Raw -Encoding UTF8
if ($tasRaw[0] -eq $bom) { $tasRaw = $tasRaw.Substring(1) }
# TAS has comment lines starting with # — strip them before CSV parse
$tasLines = $tasRaw -split "`n" | Where-Object { $_ -and -not $_.StartsWith("#") }
$tasCsv = $tasLines -join "`n"
$tasRows = $tasCsv | ConvertFrom-Csv
# TAS rows where receipt_filename is empty → candidates for fill
$tasGaps = @($tasRows | Where-Object { -not $_.receipt_filename -or $_.receipt_filename -eq "" })
Write-Host "  $($tasRows.Count) transactions, $($tasGaps.Count) with no receipt" -ForegroundColor Gray

# Index TAS by date|amount for exact lookups
$tasByKey = @{}
foreach ($t in $tasGaps) {
    $amount = [math]::Abs([double]$t.amount)
    $key = "$($t.date)|$([math]::Round($amount, 2))"
    if (-not $tasByKey.ContainsKey($key)) { $tasByKey[$key] = @() }
    $tasByKey[$key] += $t
}
Write-Host "  $($tasByKey.Count) unique gap keys" -ForegroundColor Gray
Write-Host ""

# ─── Build per-account basename index (for Strategy 4) ────────────────────────
Write-Host "Indexing per-account directories..." -ForegroundColor Cyan
$perAccountDirs = @("intersite-mc-6258", "intersite-rbc-chequing")
$accountBasenames = @{}  # basename (lowercase) -> full path
foreach ($d in $perAccountDirs) {
    $dirPath = Join-Path $ReceiptsRoot $d
    if (-not (Test-Path $dirPath)) { continue }
    Get-ChildItem $dirPath -File -ErrorAction SilentlyContinue | ForEach-Object {
        $accountBasenames[$_.Name.ToLower()] = $_.FullName
    }
}
Write-Host "  $($accountBasenames.Count) files indexed across $($perAccountDirs.Count) account dirs" -ForegroundColor Gray
Write-Host ""

# ─── Enumerate orphans (excluding archived/) ──────────────────────────────────
$orphanFiles = Get-ChildItem $OrphansDir -File -ErrorAction SilentlyContinue
Write-Host "Found $($orphanFiles.Count) files in _orphans/" -ForegroundColor Cyan
Write-Host ""

# ─── Pattern for date+amount extraction from filename ─────────────────────────
$filenamePattern = '(\d{4}-\d{2}-\d{2}).*?([0-9]+\.[0-9]{2})'
$basenameSuffixPattern = '_\d+(?=\.[^.]+$)'  # matches _2, _3, etc. before extension

# ─── Reconcile each orphan ────────────────────────────────────────────────────
$results = @()
$stats = @{
    Total           = 0
    DateAmountFound = 0
    ExactDuplicate  = 0   # Strategy 1 — archive
    ExactTasMatch   = 0   # Strategy 2 — promote
    FuzzyTasMatch   = 0   # Strategy 3 — promote
    FilenameDuplicate = 0 # Strategy 4 — archive
    PromoteTarget   = 0
    ArchiveTarget   = 0
    Unmatched       = 0
    Ambiguous       = 0
    Errors          = 0
}

foreach ($file in $orphanFiles) {
    $stats.Total++

    $entry = [ordered]@{
        Filename       = $file.Name
        ExtractedDate  = ""
        ExtractedAmount = ""
        MatchedStatus  = "unmatched"
        MatchSource    = ""
        MatchDetail    = ""
        SuggestedAction = "leave"
        TargetPath     = ""
    }

    # Try to extract date+amount from filename
    $m = [regex]::Match($file.Name, $filenamePattern)
    if ($m.Success) {
        $entry.ExtractedDate = $m.Groups[1].Value
        $entry.ExtractedAmount = $m.Groups[2].Value
        $stats.DateAmountFound++

        $key = "$($entry.ExtractedDate)|$([math]::Round([math]::Abs([double]$entry.ExtractedAmount), 2))"

        # Strategy 1: exact match against manifest matched entries
        if ($matchedByKey.ContainsKey($key)) {
            $match = $matchedByKey[$key] | Select-Object -First 1
            $entry.MatchedStatus = "exact-duplicate"
            $entry.MatchSource = "manifest:matched"
            $entry.MatchDetail = "$($match.filename) (sha256=$($match.sha256.Substring(0,12))…)"
            $entry.SuggestedAction = "archive"
            $stats.ExactDuplicate++
        }
        # Strategy 2: exact match against TAS gaps
        elseif ($tasByKey.ContainsKey($key)) {
            $t = $tasByKey[$key] | Select-Object -First 1
            # Determine target account from bank_account field
            $accountDir = Switch -Regex ($t.bank_account) {
                "MC 6258|MasterCard|Credit" { "intersite-mc-6258" }
                "RBC|Chequing" { "intersite-rbc-chequing" }
                default { $null }
            }
            $entry.MatchedStatus = "exact-tas-match"
            $entry.MatchSource = "tas:gap"
            $entry.MatchDetail = "$($t.date) `$$($t.amount) txn=$($t.zoho_transaction_id)"
            $entry.SuggestedAction = if ($accountDir) { "promote" } else { "review" }
            if ($accountDir) {
                $entry.TargetPath = Join-Path $ReceiptsRoot $accountDir $file.Name
            }
            $stats.ExactTasMatch++
        }
        # Strategy 3: fuzzy match against TAS gaps (date ±3d, amount ±$0.10)
        else {
            $orphanDate = Get-Date $entry.ExtractedDate
            $orphanAmt = [math]::Abs([double]$entry.ExtractedAmount)
            $fuzzyHit = $null
            foreach ($t in $tasGaps) {
                $tAmt = [math]::Abs([double]$t.amount)
                if ([math]::Abs($orphanAmt - $tAmt) -le 0.10) {
                    $tDate = Get-Date $t.date
                    $dd = [math]::Abs(($orphanDate - $tDate).TotalDays)
                    if ($dd -le 3) {
                        # Check if this key is already claimed by an earlier match
                        if (-not $fuzzyHit -or $dd -lt $fuzzyHit._days) {
                            $fuzzyHit = $t
                            $fuzzyHit | Add-Member -NotePropertyName _days -NotePropertyValue $dd -Force
                        }
                    }
                }
            }
            if ($fuzzyHit) {
                $accountDir = Switch -Regex ($fuzzyHit.bank_account) {
                    "MC 6258|MasterCard|Credit" { "intersite-mc-6258" }
                    "RBC|Chequing" { "intersite-rbc-chequing" }
                    default { $null }
                }
                $entry.MatchedStatus = "fuzzy-tas-match"
                $entry.MatchSource = "tas:gap:fuzzy"
                $entry.MatchDetail = "$($fuzzyHit.date) `$$($fuzzyHit.amount) txn=$($fuzzyHit.zoho_transaction_id) (delta-d=$([math]::Round($fuzzyHit._days,1)))"
                $entry.SuggestedAction = if ($accountDir) { "promote" } else { "review" }
                if ($accountDir) {
                    $entry.TargetPath = Join-Path $ReceiptsRoot $accountDir $file.Name
                }
                $stats.FuzzyTasMatch++
            }
        }
    }

    # Strategy 4: filename heuristic — strip _2, _3 suffix, check per-account dirs
    if ($entry.MatchedStatus -eq "unmatched") {
        $baseName = $file.Name
        $baseName = [regex]::Replace($baseName, $basenameSuffixPattern, '')
        $lowerBase = $baseName.ToLower()
        if ($accountBasenames.ContainsKey($lowerBase)) {
            $entry.MatchedStatus = "filename-duplicate"
            $entry.MatchSource = "account-dir:basename"
            $entry.MatchDetail = $accountBasenames[$lowerBase]
            $entry.SuggestedAction = "archive"
            $stats.FilenameDuplicate++
        }
    }

    # Final tally
    if ($entry.SuggestedAction -eq "archive") { $stats.ArchiveTarget++ }
    elseif ($entry.SuggestedAction -eq "promote") { $stats.PromoteTarget++ }
    elseif ($entry.SuggestedAction -eq "review") { $stats.Ambiguous++ }
    elseif ($entry.MatchedStatus -eq "unmatched") { $stats.Unmatched++ }

    $results += [pscustomobject]$entry
}

Write-Host ""
Write-Host "─── Summary ───" -ForegroundColor Cyan
Write-Host ("  Total orphans scanned:        {0}" -f $stats.Total)
Write-Host ("  With date+amount in filename: {0}" -f $stats.DateAmountFound) -ForegroundColor Gray
Write-Host ("  Strategy 1 (exact dupe):      {0}" -f $stats.ExactDuplicate) -ForegroundColor $(if ($stats.ExactDuplicate) { 'Yellow' } else { 'Gray' })
Write-Host ("  Strategy 2 (exact TAS):       {0}" -f $stats.ExactTasMatch) -ForegroundColor $(if ($stats.ExactTasMatch) { 'Green' } else { 'Gray' })
Write-Host ("  Strategy 3 (fuzzy TAS):       {0}" -f $stats.FuzzyTasMatch) -ForegroundColor $(if ($stats.FuzzyTasMatch) { 'Green' } else { 'Gray' })
Write-Host ("  Strategy 4 (filename dupe):   {0}" -f $stats.FilenameDuplicate) -ForegroundColor $(if ($stats.FilenameDuplicate) { 'Yellow' } else { 'Gray' })
Write-Host ("  → archive:                    {0}" -f $stats.ArchiveTarget) -ForegroundColor Yellow
Write-Host ("  → promote:                    {0}" -f $stats.PromoteTarget) -ForegroundColor Green
Write-Host ("  unmatched:                    {0}" -f $stats.Unmatched) -ForegroundColor $(if ($stats.Unmatched) { 'Red' } else { 'Gray' })
Write-Host ""

# ─── Write per-orphan CSV report ──────────────────────────────────────────────
Write-Host "Writing per-orphan report: $ReportPath" -ForegroundColor Cyan
$results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
Write-Host "  $($results.Count) rows" -ForegroundColor Gray

# ─── Write summary + unmatched markdown (via Format-ReconciliationReports.ps1) ─
# The summary heredoc with subexpressions fails when the script is invoked via
# some PowerShell hosts (e.g., the opencode bash tool), producing empty output
# files. Delegate to a sibling script that uses an array-join approach instead.
$formatScript = Join-Path $PSScriptRoot "Format-ReconciliationReports.ps1"
if (Test-Path $formatScript) {
    Write-Host "Writing summary: $SummaryPath (via Format-ReconciliationReports.ps1)" -ForegroundColor Cyan
    & $formatScript -OrphansDir $OrphansDir -ReportPath $ReportPath -Apply:$Apply | Out-Null
} else {
    Write-Host "  [WARN] Format-ReconciliationReports.ps1 not found at $formatScript" -ForegroundColor Yellow
}

# ─── Apply actions (if -Apply) ────────────────────────────────────────────────
if ($Apply) {
    Write-Host ""
    Write-Host "─── Applying changes ───" -ForegroundColor Yellow
    $applyStats = @{ Archived = 0; Promoted = 0; Skipped = 0; Errors = 0 }
    $manifestUpdates = @()  # list of @{ filename, newStatus, account }

    foreach ($r in $results) {
        # Split-Path -Leaf strips any directory prefix from legacy manifest entries (e.g., `_orphans\foo.pdf`)
        $sourcePath = Join-Path $OrphansDir (Split-Path $r.Filename -Leaf)
        if (-not (Test-Path $sourcePath)) {
            $applyStats.Skipped++
            continue
        }

        $shouldArchive = ($r.SuggestedAction -eq "archive") -and ($ApplyMode -in @("All", "Archive"))
        $shouldPromote = ($r.SuggestedAction -eq "promote") -and ($ApplyMode -in @("All", "Promote"))

        if ($shouldArchive) {
            try {
                $destPath = Join-Path $archivedDir $r.Filename
                if (Test-Path $destPath) {
                    # Compare SHA256: same content = idempotent skip, different = overwrite (with warning)
                    $srcHash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash
                    $dstHash = (Get-FileHash $destPath -Algorithm SHA256).Hash
                    if ($srcHash -eq $dstHash) {
                        $applyStats.Skipped++  # same content, already archived
                        Remove-Item -LiteralPath $sourcePath -Force  # remove duplicate in source
                    } else {
                        Write-Host "  [WARN] archive collision with different content: $($r.Filename)" -ForegroundColor Yellow
                        $applyStats.Skipped++
                    }
                } else {
                    Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
                    $applyStats.Archived++
                    $manifestUpdates += @{ Filename = $r.Filename; NewStatus = "archived" }
                }
            } catch {
                Write-Host "  [ERR] archive $($r.Filename): $_" -ForegroundColor Red
                $applyStats.Errors++
            }
        }
        elseif ($shouldPromote -and $r.TargetPath) {
            try {
                $destDir = Split-Path $r.TargetPath -Parent
                $null = New-Item -ItemType Directory -Path $destDir -Force
                if (Test-Path $r.TargetPath) {
                    # Compare SHA256 before overwrite
                    $srcHash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash
                    $dstHash = (Get-FileHash $r.TargetPath -Algorithm SHA256).Hash
                    if ($srcHash -eq $dstHash) {
                        # Same content — drop the orphan copy, mark as promoted
                        Remove-Item -LiteralPath $sourcePath -Force
                        $applyStats.Skipped++  # already in place, no actual move
                        $accountName = Split-Path $destDir -Leaf
                        $manifestUpdates += @{ Filename = $r.Filename; NewStatus = "promoted"; Account = $accountName }
                    } else {
                        # Different content — preserve the existing file, leave orphan in place
                        Write-Host "  [WARN] promote collision with different content: $($r.Filename) → $($r.TargetPath)" -ForegroundColor Yellow
                        $applyStats.Skipped++
                    }
                } else {
                    Move-Item -LiteralPath $sourcePath -Destination $r.TargetPath -Force
                    $applyStats.Promoted++
                    $accountName = Split-Path $destDir -Leaf
                    $manifestUpdates += @{ Filename = $r.Filename; NewStatus = "promoted"; Account = $accountName }
                }
            } catch {
                Write-Host "  [ERR] promote $($r.Filename): $_" -ForegroundColor Red
                $applyStats.Errors++
            }
        }
    }

    Write-Host "  Archived: $($applyStats.Archived)" -ForegroundColor Yellow
    Write-Host "  Promoted: $($applyStats.Promoted)" -ForegroundColor Green
    Write-Host "  Skipped:  $($applyStats.Skipped)" -ForegroundColor Gray
    Write-Host "  Errors:   $($applyStats.Errors)" -ForegroundColor $(if ($applyStats.Errors) { 'Red' } else { 'Gray' })

    # Update manifest in-place
    if ($manifestUpdates.Count -gt 0) {
        Write-Host "  Updating manifest: $($manifestUpdates.Count) entries" -ForegroundColor Cyan
        $updateMap = @{}
        foreach ($u in $manifestUpdates) { $updateMap[$u.Filename] = $u }

        # Build basename index — manifest may have `_orphans\filename` (legacy) or bare `filename` (new)
        $updateByBasename = @{}
        foreach ($k in $updateMap.Keys) {
            $bn = Split-Path $k -Leaf  # strips any directory prefix
            $updateByBasename[$bn] = $updateMap[$k]
        }

        $updatedRows = foreach ($r in $manifestRows) {
            $bn = Split-Path $r.filename -Leaf
            if ($updateByBasename.ContainsKey($bn)) {
                $update = $updateByBasename[$bn]
                $r.status = $update.NewStatus
                if ($update.Account) {
                    $r.account = $update.Account
                    # Normalize: drop any directory prefix from filename
                    $r.filename = $bn
                }
            }
            $r
        }
        $updatedRows | Export-Csv -Path $ManifestPath -NoTypeInformation -Encoding UTF8
        Write-Host "  Manifest updated" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Report:    $ReportPath"
Write-Host "  Summary:   $SummaryPath"
if (-not $Apply) {
    Write-Host "  (Run with -Apply to actually move files)" -ForegroundColor Yellow
}
