<#
.SYNOPSIS
    Match receipt files to TAS transactions across both organizations, with cross-org matching.
.DESCRIPTION
    Scans ALL receipt files in both room-rentals and intersite-consulting receipt directories.
    For each receipt (with date+amount extracted from filename), attempts to match against:
      - Its own org's TAS (exact date+amount, then fuzzy)
      - The other org's TAS (exact date+amount, then fuzzy)
    Returns match results that can be piped to Invoke-ReceiptOrganize.ps1 for execution.
#>
param(
    [switch]$DryRun,
    [switch]$PassThru,
    [string]$OutputJson
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath

# -- Org definitions ---------------------------------------------------------
$orgs = @(
    @{
        Name          = 'room-rentals'
        ReceiptsBase  = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts"
        TasPath       = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\TAS-2026.csv"
        ManifestPath  = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts\manifest.csv"
        TasAccountCol = 'bank_account'
        TasDateCol    = 'date'
        TasAmtCol     = 'amount'
        TasRecCol     = 'receipt_filename'
    }
    @{
        Name          = 'intersite-consulting'
        ReceiptsBase  = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts"
        TasPath       = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\TAS-2026.csv"
        ManifestPath  = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting\2026 Filing\Receipts\_manifest.csv"
        TasAccountCol = 'bank_account'
        TasDateCol    = 'date'
        TasAmtCol     = 'amount'
        TasRecCol     = 'receipt_filename'
    }
)

$allReceipts = @()
$allTasRows = @{}
$matchResults = @()

# -- Helpers -----------------------------------------------------------------

function Parse-DateFlexible {
    param([string]$DateStr)
    if ([string]::IsNullOrWhiteSpace($DateStr)) { return $null }
    $d = $DateStr.Trim()
    $result = [datetime]::MinValue
    if ([datetime]::TryParseExact($d, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParseExact($d, 'M/d/yyyy', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParseExact($d, 'yyyy-M-d', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParse($d, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    return $null
}

function Extract-DateAmountFromFilename {
    param([string]$FileName)
    $date = $null; $amount = $null
    if ($FileName -match '(\d{4}-\d{2}-\d{2})') { $date = $matches[1] }
    if ($FileName -match '(\d+\.\d{2})') { $amount = [double]$matches[1] }
    return @{ date = $date; amount = $amount }
}

function Compute-Similarity {
    param([string]$a, [string]$b)
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return 0 }
    $a = $a.ToLower().Trim()
    $b = $b.ToLower().Trim()
    if ($a -eq $b) { return 1.0 }
    $wordsA = $a -split '\s+'
    $wordsB = $b -split '\s+'
    $common = 0
    foreach ($wa in $wordsA) {
        if ($wa.Length -lt 3) { continue }
        foreach ($wb in $wordsB) {
            if ($wb.Length -lt 3) { continue }
            if ($wa -eq $wb -or $wa -like "*$wb*" -or $wb -like "*$wa*") { $common++; break }
        }
    }
    $max = [math]::Max($wordsA.Count, $wordsB.Count)
    if ($max -eq 0) { return 0 }
    return [math]::Round($common / $max, 2)
}

function Match-ReceiptToTas {
    param(
        [object]$Receipt,
        [array]$TasRows,
        [string]$OrgName
    )
    $rd = $Receipt.date
    $ra = $Receipt.amount
    if (-not $rd -or -not $ra) { return $null }

    $rDate = Parse-DateFlexible $rd
    if (-not $rDate) { return $null }

    $roundAmt = [math]::Round([math]::Abs($ra), 2)

    $best = $null
    foreach ($tr in $TasRows) {
        $tDate = Parse-DateFlexible $tr.date
        $tAmt = [double]$tr.amount
        if (-not $tDate) { continue }

        $dd = [math]::Abs(($rDate - $tDate).TotalDays)
        $da = [math]::Abs([math]::Abs($tAmt) - $roundAmt)
        $score = 0
        $matchType = ''

        # Exact date + exact amount
        if ($dd -eq 0 -and $da -le 0.005) {
            $score = 1.0
            $matchType = 'exact-date-amount'
        }
        # Same date + amount -$0.10
        elseif ($dd -eq 0 -and $da -le 0.10) {
            $score = 0.95
            $matchType = 'date-near-amount'
        }
        # Date -1 day + exact amount
        elseif ($dd -le 1 -and $da -le 0.005) {
            $score = 0.9
            $matchType = 'near-date-exact-amount'
        }
        # Date -3 days + amount -$0.10
        elseif ($dd -le 3 -and $da -le 0.10) {
            $score = 0.7
            $matchType = 'fuzzy-date-amount'
        }
        # Date -5 days + amount -$0.50
        elseif ($dd -le 5 -and $da -le 0.50) {
            $score = 0.4
            $matchType = 'wide-fuzzy'
        }

        # Vendor similarity bonus
        if ($score -gt 0 -and $Receipt.vendor -and $tr.description) {
            $sim = Compute-Similarity $Receipt.vendor $tr.description
            $score = [math]::Min(1.0, $score + $sim * 0.15)
        }

        if ($score -gt 0 -and (-not $best -or $score -gt $best.score)) {
            $best = @{
                score      = $score
                matchType  = $matchType
                tasRow     = $tr
                org        = $OrgName
            }
        }
    }

    return $best
}

# -- Step 1: Scan ALL receipt files -----------------------------------------
Write-Host "=== Step 1: Scanning receipt files ===" -ForegroundColor Cyan

foreach ($org in $orgs) {
    $base = $org.ReceiptsBase
    if (-not (Test-Path $base)) { Write-Host "  SKIP (no dir): $base" -ForegroundColor Yellow; continue }

    $files = Get-ChildItem $base -Recurse -File -Include *.pdf, *.jpg, *.jpeg, *.png
    Write-Host "  $($org.Name): $($files.Count) receipt files found"

    foreach ($f in $files) {
        $relPath = $f.FullName.Substring($base.Length + 1)
        $extracted = Extract-DateAmountFromFilename $f.Name
        $vendor = ''
        if ($f.Name -match '-\s*\d+\.\d{2}\s*-\s*(.+?)\.(pdf|jpg|jpeg|png)$') {
            $vendor = $matches[1].Trim()
        }

        # Determine current category
        $dirParts = $relPath -split '[\\/]'
        $category = if ($dirParts.Count -gt 1) { $dirParts[0] } else { 'root' }

        $allReceipts += [PSCustomObject]@{
            FullPath     = $f.FullName
            RelPath      = $relPath
            FileName     = $f.Name
            Org          = $org.Name
            ReceiptsBase = $base
            date         = $extracted.date
            amount       = $extracted.amount
            vendor       = $vendor
            category     = $category
            Sha256       = try { (Get-FileHash -Path $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { '' }
        }
    }
}

Write-Host "  Total receipts scanned: $($allReceipts.Count)" -ForegroundColor Green

# -- Step 2: Load TAS rows for both orgs -------------------------------------
Write-Host "`n=== Step 2: Loading TAS transactions ===" -ForegroundColor Cyan

foreach ($org in $orgs) {
    $rows = @()
    if (Test-Path $org.TasPath) {
        $raw = Get-Content $org.TasPath -Raw -Encoding utf8
        # Skip comment lines (start with #)
        $csvLines = ($raw -split "`n" | Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' })
        if ($csvLines.Count -gt 0) {
            $csvText = $csvLines -join "`n"
            $rows = $csvText | ConvertFrom-Csv
        }
    }
    $allTasRows[$org.Name] = $rows
    Write-Host "  $($org.Name): $($rows.Count) TAS rows"
}

# -- Step 3: Match each receipt against both orgs' TAS -----------------------
Write-Host "`n=== Step 3: Matching receipts ===" -ForegroundColor Cyan

$matchedCount = 0
$unmatchedCount = 0

foreach ($rec in $allReceipts) {
    $bestMatch = $null

    # Try matching against both orgs
    foreach ($org in $orgs) {
        $match = Match-ReceiptToTas -Receipt $rec -TasRows $allTasRows[$org.Name] -OrgName $org.Name
        if ($match -and (-not $bestMatch -or $match.score -gt $bestMatch.score)) {
            $bestMatch = $match
        }
    }

    if ($bestMatch) {
        $matchType = $bestMatch.matchType
        $matchedOrg = $bestMatch.org
        $tasRow = $bestMatch.tasRow
        $score = $bestMatch.score

        # Determine target org: if matched to its own org's TAS, stay; otherwise cross-org match
        $targetOrg = if ($rec.Org -eq $matchedOrg) { $rec.Org } else { $matchedOrg }

        Write-Host "  MATCHED ($matchType, score=$score): $($rec.FileName)" -ForegroundColor Green
        Write-Host ("    => " + $matchedOrg + " TAS: " + $tasRow.date + " " + $tasRow.amount + " " + $tasRow.description) -ForegroundColor DarkGray

        $matchResults += [PSCustomObject]@{
            Receipt           = $rec
            Status            = 'matched'
            Score             = $score
            MatchType         = $matchType
            MatchedOrg        = $matchedOrg
            MatchedAccount    = $tasRow.bank_account
            MatchedDate       = $tasRow.date
            MatchedAmount     = $tasRow.amount
            MatchedDesc       = $tasRow.description
            TasRow            = $tasRow
            TargetReceiptsBase = ($orgs | Where-Object { $_.Name -eq $targetOrg }).ReceiptsBase
        }
        $matchedCount++
    } else {
        Write-Host "  UNMATCHED: $($rec.FileName) ($($rec.Org))" -ForegroundColor Yellow
        $matchResults += [PSCustomObject]@{
            Receipt           = $rec
            Status            = 'unmatched'
            Score             = 0
            MatchType         = ''
            MatchedOrg        = ''
            MatchedAccount    = ''
            MatchedDate       = ''
            MatchedAmount     = ''
            MatchedDesc       = ''
            TasRow            = $null
            TargetReceiptsBase = $rec.ReceiptsBase
        }
        $unmatchedCount++
    }
}

Write-Host "`n=== Match Summary ===" -ForegroundColor Cyan
Write-Host "  Matched: $matchedCount" -ForegroundColor Green
Write-Host "  Unmatched: $unmatchedCount" -ForegroundColor $(if ($unmatchedCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Total: $($matchResults.Count)" -ForegroundColor Gray

if ($DryRun) {
    Write-Host "`n=== DRY RUN -- no changes made ===" -ForegroundColor Magenta
    $matched = $matchResults | Where-Object { $_.Status -eq 'matched' }
    $unmatched = $matchResults | Where-Object { $_.Status -eq 'unmatched' }

    $crossOrg = $matched | Where-Object { $_.Receipt.Org -ne $_.MatchedOrg }
    $sameOrg = $matched | Where-Object { $_.Receipt.Org -eq $_.MatchedOrg }

    Write-Host "`nMatched receipts ($($matched.Count)): $($sameOrg.Count) same-org, $($crossOrg.Count) cross-org"

    if ($crossOrg.Count -gt 0) {
        Write-Host "`nCross-org matches:" -ForegroundColor Cyan
        $crossOrg | Select-Object @{N='File';E={$_.Receipt.FileName}}, @{N='From';E={$_.Receipt.Org}}, @{N='To';E={$_.MatchedOrg}}, @{N='Account';E={$_.MatchedAccount}}, @{N='Date';E={$_.MatchedDate}}, @{N='Amount';E={$_.MatchedAmount}}, @{N='Desc';E={$_.MatchedDesc}}, @{N='Type';E={$_.MatchType}} | Format-Table -AutoSize | Out-Host
    }

    Write-Host "`nTop 20 same-org matches (sample):"
    $sameOrg | Select-Object -First 20 | ForEach-Object {
        Write-Host ("  " + $_.Receipt.FileName + " -> " + $_.MatchedOrg + " " + $_.MatchedAccount + " [" + $_.MatchType + "]")
    }

    Write-Host "`nUnmatched ($($unmatched.Count)) by org:" -ForegroundColor Yellow
    $unmatched | Group-Object { $_.Receipt.Org } | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count) files"
    }
    Write-Host "  (will be moved to non-matching/ for their org)"
}

if ($OutputJson) {
    $export = $matchResults | Select-Object @{N='Status';E={$_.Status}}, @{N='Score';E={$_.Score}}, @{N='MatchType';E={$_.MatchType}}, @{N='MatchedOrg';E={$_.MatchedOrg}}, @{N='MatchedAccount';E={$_.MatchedAccount}}, @{N='MatchedDate';E={$_.MatchedDate}}, @{N='MatchedAmount';E={$_.MatchedAmount}}, @{N='MatchedDesc';E={$_.MatchedDesc}}, @{N='ReceiptFullPath';E={$_.Receipt.FullPath}}, @{N='ReceiptRelPath';E={$_.Receipt.RelPath}}, @{N='ReceiptFileName';E={$_.Receipt.FileName}}, @{N='ReceiptOrg';E={$_.Receipt.Org}}, @{N='ReceiptDate';E={$_.Receipt.date}}, @{N='ReceiptAmount';E={$_.Receipt.amount}}, @{N='ReceiptVendor';E={$_.Receipt.vendor}}, @{N='TargetReceiptsBase';E={$_.TargetReceiptsBase}}
    $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputJson -Encoding utf8
    Write-Host "  Results written to: $OutputJson" -ForegroundColor Green
}

if ($PassThru) { return $matchResults }

Write-Host "`n=== Next step ===" -ForegroundColor Cyan
Write-Host "Run: Invoke-ReceiptOrganize.ps1 to move files and update references" -ForegroundColor White
