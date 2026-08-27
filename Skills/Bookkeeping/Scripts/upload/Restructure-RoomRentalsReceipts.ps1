<#
.SYNOPSIS
    Restructure room-rentals receipts: de-duplicate by SHA256, add sidecars, categorize into per-account folders.
.DESCRIPTION
    Scans all receipt images (PDF/JPG), computes SHA256 for dedup, categorizes by vendor/amount into
    per-account 2026 Receipts folders, creates SHA256 sidecar CSVs+MDs, moves duplicates to Receipts/Duplicates/,
    and unmatched files to Receipts/Non-Matching/.
.PARAMETER ReceiptsDir
    Path to the 2026 Receipts directory. Defaults to room-rentals\2026 Receipts.
.PARAMETER BooksRoot
    Root path for the entity's books. Defaults to room-rentals.
.PARAMETER WhatIf
    Show what would be done without making changes.
.EXAMPLE
    & .\Restructure-RoomRentalsReceipts.ps1 -WhatIf
    Dry-run to preview changes.
.EXAMPLE
    & .\Restructure-RoomRentalsReceipts.ps1
    Execute restructuring.
#>
param(
    [string]$ReceiptsDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts",
    [string]$BooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# ── Helpers ──
function Get-Sha256($Path) { (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower() }

$accountConfig = @(
    @{ folder = "RBC-FRA";        dirName = "RBC";
       patterns = @('INTERSITE CONSULTING', 'MISC PAYMENT', 'OVERDRAFT PROTECTION', 'MONTHLY FEE', 'PROPERTY TAX', 'FEES/DUES', 'INSURANCE TD', 'BC HYDRO.*77\.00') }
    @{ folder = "RBC-6679-Visa";  dirName = "RBC-6679";
       patterns = @('ANOMALY', 'PURCHASE INTEREST', 'AUTOMATIC PAYMENT') }
    @{ folder = "TD-MLM";         dirName = "TD";
       patterns = @('INTERNET LIGHTSPEED', 'FACEBOOK META', 'AMAZON', 'PETRO-CANADA', 'SHELL', 'SUPER SAVE', 'VERNON CO-OP', 'CANCO', 'BUZZLY', 'NETFLIX', 'WAVE PRO', 'ROOMIES', 'COURT SERVICES', 'ALIEXPRESS', 'HIYETTOIA', 'CHIYUE', 'ERICOPART', 'FANMAIKEJI', 'XYQMLY', 'UNKNOWN', 'IKEA', 'KAL TIRE', 'REINVESTWEALTH', 'RECEIPT', 'WESTMINSTER', 'CHEVRON', 'CHV', 'META ADS', 'INVOICE', 'COINAMATIC', 'BCAA') }
    @{ folder = "SCOTIA-TMH";     dirName = "Scotia";
       patterns = @('153\.44|169\.89|182\.61|175\.86') }
)

# Amount-based account routing for BC Hydro (amount determines account)
$bchydroAmountMap = @{
    '36.00'  = 'TD'
    '89.00'  = 'RBC'
    '77.00'  = 'RBC'
    '153.44' = 'Scotia'
    '169.89' = 'Scotia'
    '182.61' = 'Scotia'
    '175.86' = 'Scotia'
}

function Get-AccountForFile($Path, $FileName) {
    $rel = $Path -replace [regex]::Escape($ReceiptsDir), ''
    $parts = $rel -split '\\'
    $parentDir = $parts[1]

    if ($parentDir -in @('RBC','RBC-6679','TD','Scotia')) {
        foreach ($acct in $accountConfig) {
            if ($parentDir -eq $acct.dirName) { return $acct }
        }
    }

    $clean = ($FileName -replace '\.(pdf|jpg|jpeg|png)$','') -replace '_',' '
    $upper = $clean.ToUpper()

    # Extract amount for routing
    $amount = ''
    if ($clean -match ' (\d+\.\d{2}) ') { $amount = $Matches[1] }

    # BC Hydro special handling: amount → account
    if ($upper -match 'BC HYDRO|B\.C\. HYDRO') {
        if ($bchydroAmountMap.ContainsKey($amount)) {
            $targetDir = $bchydroAmountMap[$amount]
            foreach ($acct in $accountConfig) {
                if ($acct.dirName -eq $targetDir) { return $acct }
            }
        }
    }

    # Home Depot: route by amount and context
    if ($upper -match 'HOME DEPOT|THE HOME DEPOT') {
        if ($amount -eq '31.25') { return $accountConfig[0] }   # RBC-FRA (FRA Repairs)
        if ($amount -eq '1.10')  { return $accountConfig[1] }   # RBC-6679 (FRA 6679 HDX)
        if ($amount -eq '0.98')  { return $accountConfig[3] }   # Scotia (TMH)
        if ($amount -eq '1.03')  { return $accountConfig[1] }   # RBC-6679
        if ($amount -eq '10.01') { return $accountConfig[1] }   # RBC-6679 (from unmatched)
        return $accountConfig[2]  # default to TD
    }

    # Pattern matching for all other vendors
    foreach ($acct in $accountConfig) {
        foreach ($p in $acct.patterns) {
            if ($upper -match $p) { return $acct }
        }
    }

    # Fallback by parent dir
    if ($parentDir -eq 'non-matching') { return $null }
    if ($parentDir -eq 'incoming') { return $accountConfig[1] }  # incoming → RBC-6679 (Anomaly)
    if ($parentDir -eq 'unmatched') { return $null }
    return $null
}

# Files that should stay in Non-Matching (2025 or older, wrong entity, personal)
$nonMatchingFiles = @(
    '2015-10-25 - 32.31 - Dollarama',
    '2023-07-25 - 21.28 - Dollarama',
    '2023-08-03 - 35.35 - Petro-Canada',
    '2023-09-20 - 50.87 - Esso',
    '2023-10-01 - 50.85 - Freedom Mobile',
    '2025-02-01 - 219.98 - Intersite Consulting Inc.',
    '2025-03-01 - 219.98 - Intersite Consulting Inc.',
    '2025-03-25 - 33.6 - Freedom Mobile',
    '2025-04-01 - 219.98 - Intersite Consulting Inc.',
    '2025-04-01 - 246.23 - Intersite Consulting Inc.',
    '2025-04-01 - 690.35 - Intersite Consulting Inc.',
    '2025-04-06 - 131.03 - Dulux',
    '2025-04-11 - 193.38 - Home Depot',
    '2025-04-15 - 283.5 - Intersite Consulting Inc.',
    '2025-04-17 - 5.42 - Central Okanagan Food Bank',
    '2025-04-25 - 33.6 - Freedom Mobile',
    '2025-05-01 - 219.98 - Intersite Consulting Inc.',
    '2025-05-01 - 246.23 - Intersite Consulting Inc.',
    '2025-05-01 - 690.35 - Intersite Consulting Inc.',
    '2025-05-15 - 283.5 - Intersite Consulting Inc.',
    '2025-06-22 - 3.5 - City of Richmond',
    '2025-07-11 - 124.97 - Home Depot',
    '2025-07-11 - 528.8 - Home Depot',
    '2025-07-13 - 9.2 - Impark',
    '2025-07-18 - 36.18 - Lordco Auto Parts',
    '2025-07-18 - 86.1 - Lordco Auto Parts',
    '2025-07-19 - 170.19 - Lordco Auto Parts',
    '2025-07-29 - 17.24 - MT. LEHMAN TOWN PANT',
    '2025-07-30 - 168 - Vernon Lock & Security Solutions Ltd.',
    '2025-07-31 - 59.96 - CITY PARK TOWN PANTR',
    '2025-08-05 - 151.99 - Kal Tire',
    '2025-08-06 - 90.17 - Kal Tire',
    '2025-08-11 - 214.76 - Kal Tire',
    '2025-08-13 - 10.74 - Kal Tire',
    '2025-08-13 - 135.65 - Kal Tire',
    '2025-08-16 - 45.24 - Petro-Canada',
    '2025-08-16 - 49.11 - MT. LEHMAN TOWN PANT',
    '2025-08-18 - 1093 - ICBC',
    '2025-08-19 - 61.71 - Seven Oaks Chev.Town',
    '2025-10-21 - 33.32 - Unknown Gas Station',
    '2025-10-29 - 23.67 - Esso',
    '2025-10-31 - 29.19 - Petro-Canada',
    '2025-11-03 - 55.68 - Petro-Canada',
    '2025-11-05 - 245.95 - Home Depot',
    '2025-11-05 - 64.45 - Temu',
    '2025-11-07 - 56.9 - Canco',
    '2025-12-07 - 35.71 - Petro-Canada',
    '2026-02-04 - 296.83 - Temu',
    '2026-02-13 - 58.62 - Vendu par hangzhoubaoerkejiyouxiangongsi',
    '2026-03-05 - 139.80 - KAL TIRE',
    '2026-05-05 - 102.33 - BC Hydro',
    '2026-01-25 - 67.29 - ***REMOVED-NAME*** Salmon Account No. DBC000-9590-7978'
)

# ── Phase 1: Scan all receipt image files ──
Write-Host "=== Phase 1: Scanning receipt images ===" -ForegroundColor Cyan
$imageFiles = Get-ChildItem -Recurse $ReceiptsDir -Include *.pdf,*.jpg,*.jpeg,*.png |
    Where-Object { $_.DirectoryName -notmatch 'Duplicates' -and $_.DirectoryName -notmatch 'dumped-bodies' -and $_.DirectoryName -notmatch 'Non-Matching' -and $_.DirectoryName -notmatch 'RBC' -and $_.DirectoryName -notmatch 'RBC-6679' -and $_.DirectoryName -notmatch 'TD' -and $_.DirectoryName -notmatch 'Scotia' }
# also include TD\ file that's an image
$allImages = Get-ChildItem -Recurse $ReceiptsDir -Include *.pdf,*.jpg,*.jpeg,*.png |
    Where-Object { $_.DirectoryName -notmatch 'Duplicates' -and $_.DirectoryName -notmatch 'dumped-bodies' }

Write-Host "  Found $($allImages.Count) receipt image files total"
Write-Host "  Processing $($imageFiles.Count) files outside already-categorized folders"

# ── Phase 2: Hash + dedup ──
Write-Host "`n=== Phase 2: Deduplication ===" -ForegroundColor Cyan
$hashIndex = @{}
foreach ($f in $allImages) {
    $hash = Get-Sha256 -Path $f.FullName
    if (-not $hashIndex.ContainsKey($hash)) { $hashIndex[$hash] = @() }
    $hashIndex[$hash] += $f.FullName
}

$dupDir = Join-Path $BooksRoot "Receipts\Duplicates"
if (-not (Test-Path $dupDir)) { if (-not $WhatIf) { New-Item -ItemType Directory -Path $dupDir -Force | Out-Null } }

$dupCount = 0
$processedHashes = @{}
foreach ($hash in $hashIndex.Keys) {
    $files = $hashIndex[$hash]
    if ($files.Count -gt 1) {
        # Keep the first one, move rest to Duplicates
        $primary = $files[0]
        $dupes = $files | Select-Object -Skip 1
        $dupCount += $dupes.Count

        foreach ($dup in $dupes) {
            $dupName = Split-Path -Leaf $dup
            $dupDir2 = Split-Path -Parent $dup
            $dupBase = [System.IO.Path]::GetFileNameWithoutExtension($dupName)
            $dupExt = [System.IO.Path]::GetExtension($dupName)
            $destName = $dupName
            $counter = 1
            $dupDest = Join-Path $dupDir $destName
            while (Test-Path $dupDest) {
                $destName = "${dupBase}_${counter}${dupExt}"
                $dupDest = Join-Path $dupDir $destName
                $counter++
            }

            $note = if ($dup -ne $primary) { " (primary: $(Split-Path -Leaf $primary))" } else { "" }
            Write-Host "  DUPE: $($destName)$note" -ForegroundColor Yellow

            if (-not $WhatIf) {
                # Move sidecars too
                foreach ($ext in @('.csv', '.md')) {
                    $sidecar = Join-Path $dupDir2 "$dupBase$ext"
                    if (Test-Path $sidecar) {
                        $destSidecar = Join-Path $dupDir "$dupBase$ext"
                        if (-not (Test-Path $destSidecar)) {
                            Move-Item -Path $sidecar -Destination $destSidecar -Force -ErrorAction SilentlyContinue
                        } else {
                            Remove-Item -Path $sidecar -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                Move-Item -Path $dup -Destination $dupDest -Force
            }
        }
    }
}
Write-Host "  Moved $dupCount duplicate files to $dupDir" -ForegroundColor $('Green','Yellow')[$dupCount -gt 0]

# ── Phase 3: Create target directories ──
Write-Host "`n=== Phase 3: Setting up account directories ===" -ForegroundColor Cyan
$targets = @{}
$nonMatchingDir = Join-Path $BooksRoot "Receipts\Non-Matching"
if (-not (Test-Path $nonMatchingDir)) { if (-not $WhatIf) { New-Item -ItemType Directory -Path $nonMatchingDir -Force | Out-Null } }

foreach ($acct in $accountConfig) {
    $targets[$acct.dirName] = Join-Path $BooksRoot "2026 Receipts\$($acct.dirName)"
    if (-not (Test-Path $targets[$acct.dirName])) {
        if (-not $WhatIf) { New-Item -ItemType Directory -Path $targets[$acct.dirName] -Force | Out-Null }
    }
}

# ── Phase 4: Categorize and move remaining files ──
Write-Host "=== Phase 4: Categorizing & moving receipts ===" -ForegroundColor Cyan
$stats = @{ moved = 0; toNonMatching = 0; sidecarsCreated = 0 }

# Process all files not yet in a categorized folder
$uncategorized = Get-ChildItem -Recurse $ReceiptsDir -Include *.pdf,*.jpg,*.jpeg,*.png,*.csv,*.md |
    Where-Object {
        $dn = $_.DirectoryName
        $dn -notmatch 'Duplicates' -and
        $dn -notmatch 'dumped-bodies' -and
        $dn -notmatch 'Non-Matching' -and
        $dn -notmatch '\\RBC$' -and
        $dn -notmatch '\\RBC-6679$' -and
        $dn -notmatch '\\TD$' -and
        $dn -notmatch '\\Scotia$' -and
        $_.Name -ne 'manifest.csv' -and
        $_.Name -ne 'manifest-enriched.csv' -and
        $_.Name -ne 'download-checkpoint.json' -and
        $_.Name -ne 'manifest.csv.bak' -and
        $_.Name -ne 'manifest.csv.bak2' -and
        $_.Name -ne 'manifest-old-enriched.csv' -and
        $_.Name -ne 'legacy~*' -and
        $_.Name -notmatch '^legacy~'
    } | Sort-Object Name

# Then categorize the non-legacy files only
$uncategorized = $uncategorized | Where-Object { $_.Name -notmatch '^legacy~' -and $_.Name -notmatch '^rbc-' }

Write-Host "  Files to categorize: $($uncategorized.Count)"

foreach ($f in $uncategorized) {
    $fName = Split-Path -Leaf $f.Name
    $fBase = [System.IO.Path]::GetFileNameWithoutExtension($fName)
    $fExt = [System.IO.Path]::GetExtension($fName)
    $isImage = $fExt -match '\.(pdf|jpg|jpeg|png)'

    # Determine if this is a non-matching file (pre-2026, wrong entity, etc.)
    $isNonMatching = $false
    foreach ($nm in $nonMatchingFiles) {
        if ($fName -match [regex]::Escape($nm)) { $isNonMatching = $true; break }
    }

    if ($isNonMatching) {
        $targetDir = $nonMatchingDir
    } else {
        $acct = Get-AccountForFile -Path $f.FullName -FileName $fName
        if ($acct) {
            $targetDir = $targets[$acct.dirName]
        } else {
            $targetDir = $nonMatchingDir
        }
    }

    $targetPath = Join-Path $targetDir $fName
    if ($f.FullName -ne $targetPath) {
        Write-Host "  $($fName) -> $(Split-Path $targetDir -Leaf)" -ForegroundColor Gray
        if (-not $WhatIf) {
            Copy-Item -Path $f.FullName -Destination $targetPath -Force
            Remove-Item -Path $f.FullName -Force
            $stats.moved++
            if ($isNonMatching -or (-not $acct)) { $stats.toNonMatching++ }
        }
    }
}

# ── Phase 5: Create/update sidecars with SHA256 ──
Write-Host "`n=== Phase 5: Creating/updating sidecars with SHA256 ===" -ForegroundColor Cyan

$allAccounts = $accountConfig | ForEach-Object { $targets[$_.dirName] }
$allAccountDirs = $allAccounts + @($nonMatchingDir, (Join-Path $BooksRoot "Receipts\Duplicates"))

foreach ($dir in $allAccountDirs) {
    if (-not (Test-Path $dir)) { continue }
    Write-Host "  Processing: $(Split-Path $dir -Leaf)" -ForegroundColor Cyan

    $images = Get-ChildItem $dir -Include *.pdf,*.jpg,*.jpeg,*.png
    foreach ($img in $images) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($img.Name)
        $csvPath = Join-Path $dir "$base.csv"
        $mdPath = Join-Path $dir "$base.md"
        $hash = Get-Sha256 -Path $img.FullName

        # Parse metadata from name
        $nameClean = $img.Name -replace '\.(pdf|jpg|jpeg|png)$',''
        $date = ''
        $amount = ''
        $vendor = $nameClean
        $nameClean2 = $nameClean -replace '_','-'
        if ($nameClean2 -match '^(\d{4}-\d{2}-\d{2})') { $date = $Matches[1] }
        if ($nameClean2 -match ' - ([\d.]+) -') { $amount = $Matches[1]; $vendor = ($nameClean2 -replace '^[\d.-]+ - [\d.]+ - ','') }

        # CSV sidecar
        $csvContent = if (Test-Path $csvPath) {
            # Update hash if present
            $existing = Get-Content $csvPath -Raw
            if ($existing -match 'sha256') {
                $existing -replace '(?<=sha256,).*', $hash
            } else {
                $existing.TrimEnd() + "`n$date,$amount,$vendor,$hash,$base"
            }
        } else {
            "date,amount,vendor,sha256,filename`n$date,$amount,$vendor,$hash,$base"
        }
        if (-not $WhatIf) { Set-Content -Path $csvPath -Value $csvContent -Encoding utf8; $stats.sidecarsCreated++ }

        # MD sidecar
        $mdContent = if (Test-Path $mdPath) {
            $existing = Get-Content $mdPath -Raw
            if ($existing -match 'SHA256') {
                $existing -replace '(?<=SHA256: ).*', $hash
            } elseif ($existing -match 'sha256') {
                $existing -replace '(?<=sha256: ).*', $hash
            } else {
                $existing.TrimEnd() + "`n- SHA256: $hash"
            }
        } else {
            "# Receipt: $base`n`n- Date: $date`n- Amount: $amount`n- Vendor: $vendor`n- SHA256: $hash`n- Filename: $($img.Name)"
        }
        if (-not $WhatIf) { Set-Content -Path $mdPath -Value $mdContent -Encoding utf8; $stats.sidecarsCreated++ }
    }
}

# ── Phase 6: Clean up empty dirs ──
Write-Host "`n=== Phase 6: Cleaning up ===" -ForegroundColor Cyan
$dirsToClean = @('matched', 'non-matching', 'unmatched', 'incoming', 'tx-reference', 'ingest')
foreach ($d in $dirsToClean) {
    $full = Join-Path $ReceiptsDir $d
    if (Test-Path $full) {
        $remaining = Get-ChildItem $full -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.Name -notmatch '^manifest' -and $_.Name -notmatch '^download-checkpoint' }
        if ($remaining.Count -eq 0) {
            if (-not $WhatIf) { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  Removed: $d" -ForegroundColor Gray }
        } else {
            Write-Host "  Not empty: $d ($($remaining.Count) files remain)" -ForegroundColor Yellow
        }
    }
}

# Remove leftover legacy~ and rbc-* files from matched/
Get-ChildItem $ReceiptsDir -Recurse -Filter 'legacy~*' -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $WhatIf) { Remove-Item -Path $_.FullName -Force; Write-Host "  Cleaned: $($_.Name)" -ForegroundColor DarkGray }
}
Get-ChildItem $ReceiptsDir -Recurse -Filter 'rbc-*' -Include *.pdf,*.jpg,*.jpeg,*.png -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $WhatIf) { Remove-Item -Path $_.FullName -Force; Write-Host "  Cleaned: $($_.Name)" -ForegroundColor DarkGray }
}
Get-ChildItem $ReceiptsDir -Recurse -Filter 'rbc-*' -Include *.csv,*.md -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $WhatIf) { Remove-Item -Path $_.FullName -Force; Write-Host "  Cleaned: $($_.Name)" -ForegroundColor DarkGray }
}

# ── Report ──
Write-Host "`n=== Final Summary ===" -ForegroundColor Cyan
Write-Host "  Files moved to account folders:   $($stats.moved)" -ForegroundColor Green
Write-Host "  Files moved to Non-Matching:      $($stats.toNonMatching)" -ForegroundColor Yellow
Write-Host "  Sidecars created/updated:         $($stats.sidecarsCreated)" -ForegroundColor Green
Write-Host "  Duplicates moved:                 $dupCount" -ForegroundColor Yellow
Write-Host "`n  Per-account directories:" -ForegroundColor Cyan
foreach ($acct in $accountConfig) {
    $d = $targets[$acct.dirName]
    if (Test-Path $d) {
        $cnt = (Get-ChildItem $d -Include *.pdf,*.jpg,*.jpeg,*.png).Count
        Write-Host "    $($acct.folder): $cnt receipts" -ForegroundColor Green
    }
}
if (Test-Path $nonMatchingDir) {
    $nmCnt = (Get-ChildItem $nonMatchingDir -Include *.pdf,*.jpg,*.jpeg,*.png -ErrorAction SilentlyContinue).Count
    Write-Host "    Non-Matching: $nmCnt receipts" -ForegroundColor Yellow
}
