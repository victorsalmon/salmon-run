<#
.SYNOPSIS
    Regenerates the two gap-analysis CSVs (tx-without-receipts and unmatched-receipts)
    from the current TAS and receipt manifest for any entity.

.DESCRIPTION
    Reads TAS-<year>.csv and manifest.csv from the entity's bookkeeping directory,
    cross-references them to produce:
      - tx-without-receipts.csv: expense debits with no receipt file matched
      - <entity>-unmatched-receipts.csv: receipt files with no matching TAS transaction

.PARAMETER Entity
    Entity name (e.g., "room-rentals", "intersite-consulting"). Default: "room-rentals".

.PARAMETER Year
    Tax year. Default: 2026.

.PARAMETER DocsRoot
    Root bookkeeping directory. Default: ~/intersite-docs/Taxes and Bookkeeping/<Entity>.

.PARAMETER TasPath
    Explicit path to TAS CSV. Overrides Entity+Year.

.PARAMETER ManifestPath
    Explicit path to manifest CSV. Overrides Entity+DocsRoot.

.PARAMETER OutDir
    Output directory. Default: DocsRoot.

.EXAMPLE
    .\Regenerate-GapCSVs.ps1
    # Regenerates for room-rentals 2026

.EXAMPLE
    .\Regenerate-GapCSVs.ps1 -Entity intersite-consulting -Year 2026
    # Regenerates for intersite-consulting

.EXAMPLE
    .\Regenerate-GapCSVs.ps1 -TasPath "C:\...\TAS-2026.csv" -ManifestPath "C:\...\manifest.csv"
    # Uses explicit paths
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Entity = "room-rentals",
    [int]$Year = 2026,
    [string]$DocsRoot = "",
    [string]$TasPath = "",
    [string]$ManifestPath = "",
    [string]$OutDir = ""
)

# Resolve paths
if (-not $DocsRoot) {
    $DocsRoot = Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping\$Entity"
}
if (-not $TasPath) {
    $TasPath = Join-Path $DocsRoot "TAS-$Year.csv"
}
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $DocsRoot "$Year Receipts\manifest.csv"
}
if (-not $OutDir) {
    $OutDir = $DocsRoot
}

# Validate inputs
if (-not (Test-Path $TasPath)) { Write-Error "TAS not found: $TasPath"; exit 1 }
if (-not (Test-Path $ManifestPath)) { Write-Error "Manifest not found: $ManifestPath"; exit 1 }

# --- tx-without-receipts.csv ---
$tasContent = Get-Content $TasPath | Where-Object { $_ -notmatch '^#' }
$tasContent | ConvertFrom-Csv -Delimiter ',' | Out-Null
$tasData = $tasContent | ConvertFrom-Csv -Delimiter ','

$excludeCategories = @('Rent','Damage Deposit','Owner Funding','Other Income')
$txWithoutReceipts = $tasData | Where-Object {
    $rec = $_.receipt_filename
    [string]::IsNullOrWhiteSpace($rec) -and
    [double]$_.amount -lt 0 -and
    $excludeCategories -notcontains $_.category
} | ForEach-Object {
    [PSCustomObject]@{
        date = $_.date
        amount = [math]::Abs([double]$_.amount)
        payee = $_.description
        transaction_id = if ($_.zoho_transaction_id) { $_.zoho_transaction_id } else { $_.source -replace '^Raw:','' }
    }
}

$txOut = Join-Path $OutDir "tx-without-receipts.csv"
$txWithoutReceipts | Export-Csv -Path $txOut -NoTypeInformation
Write-Host "tx-without-receipts.csv: $($txWithoutReceipts.Count) rows"

# --- <entity>-unmatched-receipts.csv ---
$manifestData = Import-Csv -Path $ManifestPath

$tasReceiptSet = [System.Collections.Generic.HashSet[string]]::new()
$tasData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.receipt_filename) } | ForEach-Object {
    $r = $_.receipt_filename.Trim()
    $null = $tasReceiptSet.Add($r)
    $null = $tasReceiptSet.Add(($r -replace '^[^/\\]+[/\\]', ''))
    $null = $tasReceiptSet.Add((Split-Path $r -Leaf))
}

$unmatched = $manifestData | Where-Object {
    $f = $_.filename.Trim()
    $noFolder = $f -replace '^[^/\\]+[/\\]', ''
    $leaf = Split-Path $f -Leaf
    -not ($tasReceiptSet.Contains($f) -or $tasReceiptSet.Contains($noFolder) -or $tasReceiptSet.Contains($leaf))
} | ForEach-Object {
    [PSCustomObject]@{
        filename = $_.filename
        date = $_.date
        amount = $_.amount
        vendor = $_.vendor -replace ' \? .*$', ''
        notes = $_.notes
    }
}

$unmatchedOut = Join-Path $OutDir "$Entity-unmatched-receipts.csv"
$unmatched | Export-Csv -Path $unmatchedOut -NoTypeInformation
Write-Host "$Entity-unmatched-receipts.csv: $($unmatched.Count) rows"

Write-Host "Done. Files written to $OutDir"
