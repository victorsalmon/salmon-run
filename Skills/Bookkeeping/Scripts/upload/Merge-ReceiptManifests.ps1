<#
.SYNOPSIS
    Merge the 3 existing receipt manifests into a single canonical _manifest.csv
.DESCRIPTION
    Reads:
      - rbc-6258-manifest.csv (MC 6258 credit card statement matches + unmatched)
      - rbc-intersite-manifest.csv (RBC chequing - base)
      - rbc-intersite-manifest-enriched.csv (RBC chequing - enriched)
    Normalizes to a unified schema:
      filename, date, amount, vendor, account, sha256, zoho_expense_id,
      zoho_document_id, source, status, notes
    Dedupes by filename (preferring enriched data when present in both).
    Computes SHA256 for each file that physically exists on disk.
    Maps old subdirs to new account names: rbc-6258 -> intersite-mc-6258,
    rbc-intersite -> intersite-rbc-chequing.
.PARAMETER ReceiptsBase
    Base path for receipts. Default: $env:USERPROFILE\intersite-docs\Taxes and Bookkeeping
.PARAMETER Entity
    Entity name (currently only intersite-consulting is supported).
.PARAMETER OutputManifest
    Path to write the unified manifest. Default: <ReceiptsBase>\<Entity>\2026 Filing\Receipts\_manifest.csv
.EXAMPLE
    .\Merge-ReceiptManifests.ps1 -Entity intersite-consulting
#>
[CmdletBinding()]
param(
    [string]$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting")]
    [string]$Entity,
    [string]$OutputManifest
)

$ErrorActionPreference = "Stop"

$EntityDir = Join-Path $ReceiptsBase $Entity
$ReceiptDir = Join-Path $EntityDir "2026 Filing" "Receipts"
if (-not (Test-Path $ReceiptDir)) { Write-Error "Receipt dir not found: $ReceiptDir"; exit 1 }

if (-not $OutputManifest) {
    $OutputManifest = Join-Path $ReceiptDir "_manifest.csv"
}

$oldManifests = @{
    "intersite-mc-6258"     = Join-Path $ReceiptDir "rbc-6258-manifest.csv"
    "intersite-rbc-chequing-base"      = Join-Path $ReceiptDir "rbc-intersite-manifest.csv"
    "intersite-rbc-chequing-enriched" = Join-Path $ReceiptDir "rbc-intersite-manifest-enriched.csv"
}

function Read-ManifestCsv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $raw = Get-Content $Path -Raw -Encoding UTF8
    $bom = [char]0xFEFF
    if ($raw.Length -gt 0 -and $raw[0] -eq $bom) { $raw = $raw.Substring(1) }
    $rows = $raw | ConvertFrom-Csv
    return @($rows)
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try {
        $h = Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop
        return $h.Hash.ToLower()
    } catch {
        return ""
    }
}

$allRows = @()

# --- rbc-6258-manifest.csv (intersite-mc-6258) ---
$src = "rbc-6258"
$rows = Read-ManifestCsv -Path $oldManifests["intersite-mc-6258"]
Write-Host "  $($rows.Count) rows from $src"
foreach ($r in $rows) {
    $filename = if ($r.RenamedFilename) { $r.RenamedFilename } elseif ($r.OriginalFilename) { $r.OriginalFilename } else { $null }
    if (-not $filename) { continue }
    $date = if ($r.Date) { $r.Date } else { "" }
    $amount = if ($r.Amount) { $r.Amount } else { "" }
    $vendor = if ($r.Vendor) { $r.Vendor } else { "" }
    $matchType = if ($r.MatchType) { $r.MatchType } else { "" }
    $status = if ($matchType -in @("STATEMENT_MATCH","CARD_REF_MATCH","MANUAL_MATCH")) { "matched" } else { "orphan" }
    $notes = @()
    if ($r.OriginalFilename -and $r.OriginalFilename -ne $filename) { $notes += "original=$($r.OriginalFilename)" }
    if ($r.MatchType) { $notes += "match_type=$matchType" }
    if ($r.MatchedTxDate) { $notes += "tx_date=$($r.MatchedTxDate)" }
    if ($r.MatchedTxDesc) { $notes += "tx_desc=$($r.MatchedTxDesc)" }
    if ($r.Notes) {
        $cleanNotes = ($r.Notes -replace '[\r\n]+', ' ').Trim()
        $cleanNotes = $cleanNotes -replace '\s+', ' '
        if ($cleanNotes) { $notes += $cleanNotes }
    }
    $allRows += [pscustomobject]@{
        filename          = $filename
        date              = $date
        amount            = $amount
        vendor            = $vendor
        account           = "intersite-mc-6258"
        sha256            = ""
        zoho_expense_id   = ""
        zoho_document_id  = ""
        source            = $src
        status            = $status
        notes             = ($notes -join "; ")
    }
}

# --- rbc-intersite-manifest-enriched.csv (preferred) ---
$src = "rbc-intersite-enriched"
$rows = Read-ManifestCsv -Path $oldManifests["intersite-rbc-chequing-enriched"]
Write-Host "  $($rows.Count) rows from $src"
foreach ($r in $rows) {
    $filename = if ($r.filename) { $r.filename } else { $null }
    if (-not $filename) { continue }
    $date = if ($r.date) { $r.date } else { "" }
    $amount = if ($r.amount) { $r.amount } else { "" }
    $vendor = if ($r.vendor) { $r.vendor } else { "" }
    $estatus = if ($r.enrichment_status) { $r.enrichment_status } else { "" }
    $status = if ($estatus -eq "enriched") { "matched" } elseif ($estatus -eq "uploaded") { "uploaded" } else { "orphan" }
    $notes = @()
    if ($r.notes) { $notes += $r.notes }
    if ($r.suggested_account_id) { $notes += "suggested_account_id=$($r.suggested_account_id)" }
    if ($r.skip_reason) { $notes += "skip_reason=$($r.skip_reason)" }
    if ($r.error_status) { $notes += "error=$($r.error_status)" }
    $allRows += [pscustomobject]@{
        filename          = $filename
        date              = $date
        amount            = $amount
        vendor            = $vendor
        account           = "intersite-rbc-chequing"
        sha256            = ""
        zoho_expense_id   = ""
        zoho_document_id  = ""
        source            = $src
        status            = $status
        notes             = ($notes -join "; ")
    }
}

# --- rbc-intersite-manifest.csv (base - skipped during dedup if enriched has the file) ---
$src = "rbc-intersite-base"
$rows = Read-ManifestCsv -Path $oldManifests["intersite-rbc-chequing-base"]
Write-Host "  $($rows.Count) rows from $src"
foreach ($r in $rows) {
    $filename = if ($r.filename) { $r.filename } else { $null }
    if (-not $filename) { continue }
    $date = if ($r.date) { $r.date } else { "" }
    $amount = if ($r.amount) { $r.amount } else { "" }
    $vendor = if ($r.vendor) { $r.vendor } else { "" }
    $estatus = if ($r.enrichment_status) { $r.enrichment_status } else { "" }
    $status = if ($estatus -eq "enriched") { "matched" } elseif ($estatus -eq "uploaded") { "uploaded" } else { "orphan" }
    $notes = @()
    if ($r.notes) { $notes += $r.notes }
    if ($r.suggested_account_id) { $notes += "suggested_account_id=$($r.suggested_account_id)" }
    if ($r.skip_reason) { $notes += "skip_reason=$($r.skip_reason)" }
    $allRows += [pscustomobject]@{
        filename          = $filename
        date              = $date
        amount            = $amount
        vendor            = $vendor
        account           = "intersite-rbc-chequing"
        sha256            = ""
        zoho_expense_id   = ""
        zoho_document_id  = ""
        source            = $src
        status            = $status
        notes             = ($notes -join "; ")
    }
}

Write-Host "`nTotal merged rows: $($allRows.Count)"

# --- Dedup by filename, preferring enriched over base over rbc-6258 ---
$dedup = @{}
$priority = @{
    "rbc-intersite-enriched" = 3
    "rbc-intersite-base"     = 2
    "rbc-6258"               = 1
}
foreach ($r in $allRows) {
    $key = $r.filename
    if (-not $dedup.ContainsKey($key)) {
        $dedup[$key] = $r
    } else {
        $existing = $dedup[$key]
        $newPrio = $priority[$r.source]
        $oldPrio = $priority[$existing.source]
        if ($newPrio -gt $oldPrio) {
            $dedup[$key] = $r
        }
    }
}
Write-Host "  After dedup: $($dedup.Count) unique filenames"

# --- Compute SHA256 for files that physically exist ---
$accountSubdir = @{
    "intersite-mc-6258"     = "intersite-mc-6258"
    "intersite-rbc-chequing" = "intersite-rbc-chequing"
}
$searchDirs = @{
    "intersite-mc-6258"     = @( "intersite-mc-6258", "rbc-6258", "rbc-6258\non-matching", "rbc-6258\_unknown", "rbc-6258-ingest" )
    "intersite-rbc-chequing" = @( "intersite-rbc-chequing", "rbc-intersite" )
}
$resolved = 0
$missing = 0
foreach ($key in @($dedup.Keys)) {
    $r = $dedup[$key]
    $candidates = @()
    foreach ($sd in $searchDirs[$r.account]) {
        $candidates += Join-Path $ReceiptDir $sd $r.filename
    }
    $candidates += Join-Path $ReceiptDir "rbc-6258-ingest" $r.filename
    $candidates += Join-Path $ReceiptDir $r.filename
    $found = $null
    foreach ($c in $candidates) { if (Test-Path $c) { $found = $c; break } }
    if ($found) {
        $r.sha256 = Get-FileSha256 -Path $found
        $resolved++
    } else {
        $missing++
    }
}
Write-Host "  SHA256 resolved for $resolved files; $missing missing on disk"

# --- Write _manifest.csv ---
$out = $dedup.Values | Sort-Object account, filename
$out | Export-Csv -Path $OutputManifest -NoTypeInformation -Encoding UTF8
Write-Host "`nWrote: $OutputManifest ($($out.Count) rows)"

# --- Summary by account/status ---
Write-Host "`nSummary:"
$out | Group-Object account, status | ForEach-Object {
    Write-Host ("  {0,-50} {1,5}" -f $_.Name, $_.Count)
}
