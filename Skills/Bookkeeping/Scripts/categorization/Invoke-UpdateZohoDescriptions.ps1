<#
.SYNOPSIS
    Update Zoho expense descriptions: strip the amount+date suffix added by the
    previous pass, then append line items from receipt sidecar CSVs and expense
    category.
.DESCRIPTION
    For each Zoho expense:
    1. Strips any trailing " — <amount> — <date>" appended by the previous pass
    2. Finds the matching receipt sidecar CSV (by amount+date)
    3. Extracts description_short (first line item) from the sidecar
    4. Gets the expense category from account_name
    5. Appends: " — <line item> — <Category>"
    6. For known vendors (InterServer, Freedom) — just strip suffix, no appends
.PARAMETER Entity
    Which entity to process.
.PARAMETER AwsProfile
    AWS CLI profile for SM lookup.
.PARAMETER DryRun
    Show what would be updated without making changes.
#>
[CmdletBinding()]
param(
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity = "intersite-consulting",
    [string]$AwsProfile = "intersite",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$SLEEP_MS = 500

# --- Vendors whose descriptions already describe the service adequately ---
$knownGoodVendors = @('INTERSERVER', 'FREEDOM MOBILE')
# --- Categories that are self-explanatory without item enrichment ---
$skipCategories = @('Bank Fees', 'Bank Fees and Charges', 'Credit Card Charges',
                     'Income Tax Expense', 'Interest Expense')

# --- Load entity config ---
$configPaths = @(
    Join-Path $PSScriptRoot ".." ".." "cloud-books-entities.json"
    Join-Path (Resolve-Path "$PSScriptRoot\..\..") "cloud-books-entities.json"
)
$configPath = $null
foreach ($cp in $configPaths) { if (Test-Path $cp) { $configPath = (Resolve-Path $cp).Path; break } }
if (-not $configPath) { Write-Error "cloud-books-entities.json not found"; exit 1 }
$entitiesConfig = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
$ec = $entitiesConfig.entities[$Entity]
if (-not $ec) { Write-Error "Entity '$Entity' not found in config"; exit 1 }
$OrgId = $ec.org_id
$DisplayName = $ec.display_name
$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"

Write-Host "=== $DisplayName ===" -ForegroundColor Cyan

# --- Auth ---
Write-Host "Fetching Zoho credentials..." -ForegroundColor Gray
$awsArgs = @("secretsmanager", "get-secret-value", "--secret-id", "Interclaw/FRAD/Provisioning",
             "--profile", $AwsProfile, "--region", "ca-central-1", "--query", "SecretString", "--output", "text")
$secretStr = & aws @awsArgs 2>&1
$secret = $secretStr | ConvertFrom-Json
$tokenBody = @{ client_id = $secret.ZOHO_BOOKS_ID; client_secret = $secret.ZOHO_BOOKS_SECRET
                refresh_token = $secret.ZOHO_BOOKS_REFRESH; grant_type = "refresh_token" }
$tokenResp = Invoke-ApiCall -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -Domain "Bookkeeper" -Action "zoho:token-exchange" -TimeoutSec 30
$headers = @{ Authorization = "Zoho-oauthtoken $($tokenResp.access_token)"; "Content-Type" = "application/json" }
Write-Host "  [OK] Token obtained" -ForegroundColor Green

# --- Fetch all existing Zoho expenses ---
Write-Host "`nFetching all Zoho expenses..." -ForegroundColor Gray
$allExpenses = @(); $page = 1
do {
    $url = "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId&page=$page&per_page=200"
    $resp = Invoke-ApiCall -Uri $url -Headers $headers -Domain "Bookkeeper" -Action "zoho:expenses:list" -TimeoutSec 30
    if ($resp.expenses) { $allExpenses += $resp.expenses }
    $hasMore = $resp.page_context.has_more_page; $page++
} while ($hasMore)
Write-Host "  Total: $($allExpenses.Count) expenses" -ForegroundColor Green

# --- Build sidecar lookup: key = "amount|date" -> description_short ---
Write-Host "`nScanning sidecar CSVs..." -ForegroundColor Gray
$sidecarLookup = @{}
$receiptDir = Join-Path (Join-Path $ReceiptsBase $Entity) $ec.receipt_dir
$knownProcessor = @('generic','manual','stripe','amazon','freedom-mobile','interserver','vision-gpt4o-mini+gemini-2.5-flash',
                    'vision-gpt4o-mini-only','vision-gemini-2.5-flash-only')

function Get-AmountFromFilename {
    param([string]$Name)
    # Match amount patterns in filenames: "82.95 - ReInvestWealth" or "2025-10-09 - 335.99 - Amazon"
    if ($Name -match '(\d+\.\d{2})') { return $Matches[1] }
    if ($Name -match '(\d+\.\d{1})') { return $Matches[1] }
    return $null
}

function Get-VendorTextFromFilename {
    param([string]$Name)
    # Extract vendor name from filename: strip leading date + amount
    $parts = $Name -split ' - '
    if ($parts.Count -ge 3) { return $parts[2] }
    if ($parts.Count -eq 2) { return $parts[1] }
    return $null
}

$csvFiles = Get-ChildItem -Path $receiptDir -Recurse -Include "*.csv" -File | Where-Object {
    $_.Name -notmatch 'manifest' -and $_.Directory.Name -ne 'non-matching'
}
$descTextByAmount = @{}    # key = "amount" -> @{ descText, fileDate, vendor }
foreach ($f in $csvFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 | Where-Object { $_ -and $_[0] -ne '#' }
        if (-not $lines -or $lines.Count -lt 2) { continue }
        $h = ($lines[0] -split ',').Trim('"')
        $v = @{}; $cells = $lines[1] -split ',(?=(?:[^"]|"[^"]*")*$)'
        for ($i = 0; $i -lt [Math]::Min($h.Count, $cells.Count); $i++) { $v[$h[$i].Trim()] = ($cells[$i] -replace '^"|"$', '').Trim() }
    } catch { continue }

    $total = $v['total']
    $descCell = $v['description_short']
    $items = $v['items']
    $proc = $v['processor']
    $csvVendor = $v['vendor']

    # Extract description text
    $descText = ''
    if ($descCell) { $descText = $descCell.Trim() }
    elseif ($items -and $items -ne '[]') {
        try { $parsed = $items | ConvertFrom-Json; if ($parsed -and $parsed[0].description) { $descText = $parsed[0].description.Trim() } } catch {}
    }
    if (-not $descText -and $proc -and $knownProcessor -notcontains $proc) {
        $descText = $proc.Trim()
    }
    if (-not $descText) { continue }

    # Get amount: try CSV total, then filename
    $amt = if ($total -match '^\d+\.?\d*$') { $total } else { Get-AmountFromFilename -Name $f.BaseName }
    if (-not $amt) { continue }

    $fileDate = ''
    if ($f.BaseName -match '(\d{4}-\d{2}-\d{2})') { $fileDate = $Matches[1] }
    $csvDate = if ($v['date_issued']) { $v['date_issued'] } else { $fileDate }

    # Determine vendor key for duplicate resolution
    $vendorKey = if ($csvVendor) { $csvVendor.ToUpperInvariant() }
                 else { $null }

    if (-not $descTextByAmount.ContainsKey($amt)) { $descTextByAmount[$amt] = @() }
    $descTextByAmount[$amt] += @{ descText = $descText; date = $csvDate; vendor = $vendorKey }
}
Write-Host "  $($descTextByAmount.Count) amount keys in sidecar index" -ForegroundColor Green

# --- Process each expense ---
$updated = 0; $skipped = 0; $errors = 0

# Regex to strip trailing separator + amount + date from previous passes
$suffixRegex = '[—\-] \d+\.\d{2} [—\-] \d{4}-\d{2}-\d{2}$'

foreach ($exp in $allExpenses) {
    $expId = $exp.expense_id
    $currentDesc = if ($exp.description) { $exp.description.Trim() } else { '' }
    $amount = if ($exp.total) { "{0:F2}" -f [double]$exp.total } else { '' }
    $date = if ($exp.date) { (Get-Date $exp.date).ToString('yyyy-MM-dd') } else { '' }
    $vendorName = if ($exp.vendor_name) { $exp.vendor_name.Trim() } else { '' }
    $category = if ($exp.account_name) { $exp.account_name.Trim() } else { '' }
    $upperVendor = $vendorName.ToUpperInvariant()

    # Step 1: Strip the amount+date suffix from previous pass
    $baseDesc = $currentDesc -replace $suffixRegex, ''

    # Step 2: Check if we should skip enrichment for known-good vendors
    $upperDesc = $baseDesc.ToUpperInvariant()
    $isKnownGood = $false
    foreach ($kw in $knownGoodVendors) {
        if ($upperDesc -match [regex]::Escape($kw)) { $isKnownGood = $true; break }
    }

    # Step 3: Match sidecar by amount, then disambiguate by date + vendor
    $descText = $null
    if ($descTextByAmount.ContainsKey($amount)) {
        $candidates = $descTextByAmount[$amount]
        if ($candidates.Count -eq 1) {
            $descText = $candidates[0].descText
        } else {
            # Try to find best match by date proximity (±5 days)
            $expDate = Get-Date $date
            $best = $null; $bestDiff = 999
            foreach ($c in $candidates) {
                if (-not $c.date) { continue }
                $cDate = try { Get-Date $c.date } catch { $null }
                if (-not $cDate) { continue }
                $diff = [Math]::Abs(($cDate - $expDate).TotalDays)
                if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $c }
            }
            if ($best -and $bestDiff -le 5) { $descText = $best.descText }
            elseif ($upperDesc) {
                # Try vendor name match
                foreach ($c in $candidates) {
                    if ($c.vendor -and $upperDesc -match [regex]::Escape($c.vendor)) { $descText = $c.descText; break }
                }
                if (-not $descText) {
                    # Try matching filename vendor from description
                    $descWords = $upperDesc -split '\s+'
                    foreach ($c in $candidates) {
                        if (-not $c.vendor) {
                            # Extract vendor from the description text itself
                            $descFirstWord = if ($descWords.Count -gt 0) { $descWords[0] } else { '' }
                            if ($descFirstWord -and $c.descText.ToUpperInvariant() -match $descFirstWord) { $descText = $c.descText; break }
                        }
                    }
                }
            }
        }
    }

    # Step 4: Build new description
    $parts = @()
    if ($baseDesc) { $parts += $baseDesc }

    # Only append enrichment if we have meaningful sidecar data
    if ($descText -and -not $isKnownGood) {
        $descText = $descText -replace '[^\x20-\x7E]', ' ' -replace '\s+', ' '
        $parts += $descText
    }

    if ($category -and -not ($isKnownGood)) {
        $parts += $category
    }

    $newDesc = if ($parts.Count -gt 0) { $parts -join ' - ' } else { '' }

    # Compare: if nothing changed, skip
    if ($newDesc -eq $currentDesc) { $skipped++; continue }

    Write-Host "`n  $(if ($vendorName) { "$vendorName - $amount - $date" } else { "Expense $expId - $amount - $date" })"
    Write-Host "    Old: $currentDesc" -ForegroundColor Yellow
    Write-Host "    New: $newDesc" -ForegroundColor Green
    if ($descText) { Write-Host "    Sidecar: $descText" -ForegroundColor Cyan }
    if ($category) { Write-Host "    Category: $category" -ForegroundColor Cyan }

    if (-not $DryRun) {
        try {
            $body = @{ description = $newDesc } | ConvertTo-Json -Compress
            $updateUrl = "https://www.zohoapis.com/books/v3/expenses/$($exp.expense_id)?organization_id=$OrgId"
            $resp = Invoke-ApiCall -Uri $updateUrl -Method PUT -Headers $headers -Body $body -Domain "Bookkeeper" -Action "zoho:expenses:update" -TimeoutSec 30
            if ($resp.code -ne 0) { throw "code=$($resp.code) msg=$($resp.message)" }
            $updated++
            Start-Sleep -Milliseconds $SLEEP_MS
        } catch {
            Write-Host "    [FAIL] $_" -ForegroundColor Red
            $errors++
            if ($_.Exception.Message -match 'rate|limit|429|too many') { Write-Host "  Rate limited - stopping." -ForegroundColor Red; break }
        }
    } else {
        $updated++
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  To update: $updated" -ForegroundColor Green
Write-Host "  Skipped:   $skipped" -ForegroundColor Gray
Write-Host "  Errors:    $errors" -ForegroundColor $(if ($errors -eq 0) { "Green" } else { "Red" })
if ($DryRun) { Write-Host "`n[Dry run] No changes made." -ForegroundColor Magenta }
else { Write-Host "`nDone." -ForegroundColor Cyan }
