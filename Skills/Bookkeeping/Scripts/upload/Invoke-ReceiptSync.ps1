<#
.SYNOPSIS
    Bidirectional receipt sync between Zoho Books and local receipt manifests.
.DESCRIPTION
    Compares Zoho expense attachments against local receipt manifest files,
    downloads missing Zoho receipts locally, and uploads missing local receipts to Zoho.
.PARAMETER Entity
    "intersite-consulting" or "room-rentals"
.PARAMETER Direction
    "All" (both directions), "Download" (Zoho→Local only), or "Upload" (Local→Zoho only)
.PARAMETER AwsProfile
    AWS CLI profile for SM lookup. Default: intersite.
.PARAMETER DryRun
    Print what would be done without making changes.
.PARAMETER Force
    Re-download or re-upload even if previously done.
.PARAMETER SkipTasRebuild
    Skip TAS rebuild and status check after sync.
.EXAMPLE
    .\Invoke-ReceiptSync.ps1 -Entity intersite-consulting -DryRun
    Discover what's missing without making changes.
.EXAMPLE
    .\Invoke-ReceiptSync.ps1 -Entity intersite-consulting -Direction Download
    Download all Zoho receipts not present locally.
.EXAMPLE
    .\Invoke-ReceiptSync.ps1 -Entity room-rentals -Direction Upload
    Upload all local receipts not yet attached to Zoho expenses.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [ValidateSet("All", "Download", "Upload")]
    [string]$Direction = "All",

    [string]$AwsProfile = "intersite",

    [switch]$DryRun,

    [switch]$Force,

    [switch]$SkipTasRebuild
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path "$scriptDir\..\..\..\.."
$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"

# Load entity config
$configPaths = @(
    Join-Path $repoRoot "Skills" "Bookkeeping" "cloud-books-entities.json"
    Join-Path (Resolve-Path "$PSScriptRoot\..\..") "cloud-books-entities.json"
)
$configPath = $null
foreach ($cp in $configPaths) { if (Test-Path $cp) { $configPath = (Resolve-Path $cp).Path; break } }
if (-not $configPath) { Write-Error "cloud-books-entities.json not found"; exit 1 }

$entitiesConfig = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
$ec = $entitiesConfig.entities[$Entity]
if (-not $ec) { Write-Error "Entity '$Entity' not found in config"; exit 1 }

$OrgId = $ec.org_id
$EntityDir = Join-Path $ReceiptsBase $Entity

# Determine receipt directory and manifest paths
if ($Entity -eq "intersite-consulting") {
    $ReceiptDir = Join-Path $EntityDir "2026 Filing" "Receipts"
    # Unified _manifest.csv replaces the 3 old manifests (rbc-intersite-manifest.csv,
    # rbc-intersite-manifest-enriched.csv, rbc-6258-manifest.csv). Each row's
    # `account` column indicates which per-account subdir the file belongs to.
    $Manifests = @(
        @{ Slug = "unified"; Path = Join-Path $ReceiptDir "_manifest.csv"; Subdir = "" }
    )
    $TasScript = Join-Path $scriptDir "..\reconciliation\Build-IntersiteTAS.ps1"
    $TasDir = $EntityDir
} else {
    $ReceiptDir = Join-Path $EntityDir "2026 Receipts"
    $Manifests = @(
        @{ Slug = "main"; Path = Join-Path $ReceiptDir "manifest.csv"; Subdir = "" }
    )
    $TasScript = Join-Path $scriptDir "..\reconciliation\Build-TAS.ps1"
    $TasDir = $EntityDir
}

# Resolve paid_through account IDs for this entity for download subdirectory routing
$BankAccts = @{}
foreach ($baProp in $entitiesConfig.bank_accounts.PSObject.Properties) {
    if ($baProp.Value.entity -eq $Entity) { $BankAccts[$baProp.Value.account_id] = $baProp.Name }
}
foreach ($ccProp in $entitiesConfig.credit_cards.PSObject.Properties) {
    if ($ccProp.Value.entity -eq $Entity) { $BankAccts[$ccProp.Value.account_id] = $ccProp.Name }
}

# Map entities-config account names to the new unified subdir names.
# Old layout: rbc-6258/ (CC receipts) and rbc-intersite/ (bank receipts).
# New layout: intersite-mc-6258/ (CC) and intersite-rbc-chequing/ (bank).
$AccountToSubdir = @{
    "rbc-chequing"   = "intersite-rbc-chequing"
    "6258"           = "intersite-mc-6258"
}

# Resolve OAuth credentials
Write-Host "Reading Zoho credentials from AWS SM..." -ForegroundColor Cyan
$awsArgs = @(
    "secretsmanager", "get-secret-value",
    "--secret-id", "Interclaw/FRAD/Provisioning",
    "--profile", $AwsProfile,
    "--region", "ca-central-1",
    "--query", "SecretString",
    "--output", "text"
)
$secretStr = & aws @awsArgs 2>&1
if (-not $secretStr) { Write-Error "Failed to read AWS SM secret 'Interclaw/FRAD/Provisioning'"; exit 1 }
$secret = $secretStr | ConvertFrom-Json

Write-Host "Getting Zoho access token..." -ForegroundColor Cyan
$tokenBody = @{
    client_id     = $secret.ZOHO_BOOKS_ID
    client_secret = $secret.ZOHO_BOOKS_SECRET
    refresh_token = $secret.ZOHO_BOOKS_REFRESH
    grant_type    = "refresh_token"
}
$tokenResult = Invoke-ApiCall -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -Domain "Bookkeeper" -Action "zoho:token-exchange" -TimeoutSec 30
$accessToken = $tokenResult.access_token
$tokenExpiry = (Get-Date).AddSeconds($tokenResult.expires_in - 60)
$headers = @{ Authorization = "Zoho-oauthtoken $accessToken"; Accept = "application/json" }
Write-Host "  Token OK — expires at $($tokenExpiry.ToString('HH:mm:ss'))" -ForegroundColor Green

# ─── Fetch all Zoho expenses ─────────────────────────────────────────────────
Write-Host "`nFetching all Zoho expenses..." -ForegroundColor Cyan
$allExpenses = @()
$page = 1
do {
    $resp = Invoke-ApiCall -Uri "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId&page=$page&per_page=200" `
        -Headers $headers -Domain "Bookkeeper" -Action "zoho:expenses:list" -TimeoutSec 30
    $batch = $resp.expenses
    if ($batch -and $batch.Count -gt 0) { $allExpenses += $batch }
    $hasMore = $resp.page_context -and $resp.page_context.has_more_page
    $page++
    Start-Sleep -Milliseconds 300
} while ($hasMore)
Write-Host "  $($allExpenses.Count) expenses total"

$attached = $allExpenses | Where-Object { $_.has_attachment -eq $true }
$unattached = $allExpenses | Where-Object { $_.has_attachment -ne $true }
Write-Host "  $($attached.Count) with attachments, $($unattached.Count) without" -ForegroundColor Gray

# Stats accumulators
$dlStats = @{ Downloaded = 0; Skipped = 0; Failed = 0; AlreadyPresent = 0 }
$ulStats = @{ Uploaded = 0; Skipped = 0; Failed = 0; AlreadyAttached = 0; NoExpense = 0 }

# ─── Load local manifests ────────────────────────────────────────────────────
Write-Host "`nLoading local receipt manifests..." -ForegroundColor Cyan
$localReceipts = @()  # Each: @{ slug, manifest_path, subdir, filename, date, amount, vendor, key }
$manifestPaths = @()

foreach ($m in $Manifests) {
    $manPath = $m.Path
    $manifestPaths += $manPath
    if (-not (Test-Path $manPath)) { Write-Host "  SKIP (not found): $manPath" -ForegroundColor Yellow; continue }

    $raw = Get-Content $manPath -Raw -Encoding UTF8
    $bom = [char]0xFEFF
    if ($raw[0] -eq $bom) { $raw = $raw.Substring(1) }
    $rows = $raw | ConvertFrom-Csv

    foreach ($r in $rows) {
        $dt = if ($r.date) { $r.date } elseif ($r.Date) { $r.Date } else { $null }
        $amt = if ($r.amount) { $r.amount } elseif ($r.Amount) { $r.Amount } else { $null }
        $fn = if ($r.filename) { $r.filename } elseif ($r.OriginalFilename) { $r.OriginalFilename } elseif ($r.RenamedFilename) { $r.RenamedFilename } else { $null }
        $vd = if ($r.vendor) { $r.vendor } elseif ($r.Vendor) { $r.Vendor } else { "" }
        $acct = if ($r.account) { $r.account } else { "" }
        $st = if ($r.status) { $r.status } else { "" }
        # In the unified manifest, the `account` column IS the subdir name
        # (intersite-mc-6258 / intersite-rbc-chequing). Orphans live in _orphans/.
        $subdir = $acct
        if ($st -eq "orphan" -or $st -eq "zoho_only") { $subdir = "_orphans" }
        if ($dt -and $amt) {
            $key = "$dt|$([math]::Round([math]::Abs([double]$amt), 2))"
            $localReceipts += @{
                Slug = $m.Slug
                ManifestPath = $manPath
                Subdir = $subdir
                Account = $acct
                Status = $st
                Filename = $fn
                Date = $dt
                Amount = [double]$amt
                Vendor = $vd
                Key = $key
            }
        }
    }
    Write-Host "  $($rows.Count) entries from $($m.Slug)" -ForegroundColor Gray
}
Write-Host "  $($localReceipts.Count) total local receipt entries" -ForegroundColor Gray

# Build lookup: key -> list of local receipt entries
$localLookup = @{}
foreach ($lr in $localReceipts) {
    if (-not $localLookup.ContainsKey($lr.Key)) { $localLookup[$lr.Key] = @() }
    $localLookup[$lr.Key] += $lr
}

# ─── Cross-reference discovery ───────────────────────────────────────────────
Write-Host "`nCross-referencing Zoho attachments vs local manifests..." -ForegroundColor Cyan

# Download candidates: Zoho attached expenses not matched to any local receipt
$downloadCandidates = @()
foreach ($exp in $attached) {
    $key = "$($exp.date)|$([math]::Round([math]::Abs([double]$exp.total), 2))"
    $matched = $localLookup.ContainsKey($key)
    if (-not $matched -and -not $Force) {
        # Try fuzzy match (±3 days, ±$0.10)
        foreach ($lk in $localLookup.Keys) {
            $parts = $lk -split '\|'
            $lDate = $parts[0]
            $lAmt = [double]$parts[1]
            $eAmt = [double]$exp.total
            if ([math]::Abs($eAmt - $lAmt) -le 0.10) {
                $dd = [math]::Abs(((Get-Date $exp.date) - (Get-Date $lDate)).TotalDays)
                if ($dd -le 3) { $matched = $true; break }
            }
        }
    }
    if (-not $matched) {
        $downloadCandidates += $exp
    }
}

# Upload candidates: local receipts not matched to any Zoho attached expense
# Exempt vendors: receipts for these vendors must not be uploaded to Zoho.
# They are typically refunds, credits, or expenses where the receipt already
# matches a different expense in the local filesystem. Vendor name match is
# case-insensitive substring against the `vendor` field.
$ExemptVendors = @("Pixella", "Roomies", "Anomaly", "Ozerty", "Cofoodbank")
$localUploadCandidates = @()
foreach ($lr in $localReceipts) {
    $key = $lr.Key
    $matched = $false
    foreach ($exp in $attached) {
        $eKey = "$($exp.date)|$([math]::Round([math]::Abs([double]$exp.total), 2))"
        if ($key -eq $eKey) { $matched = $true; break }
    }
    if (-not $matched) {
        # Check unattached too — if matching expense exists but unattached, include
        $foundExpense = $null
        foreach ($exp in $unattached) {
            $eAmt = [double]$exp.total
            if ([math]::Abs($lr.Amount - $eAmt) -le 0.10) {
                $dd = [math]::Abs(((Get-Date $lr.Date) - (Get-Date $exp.date)).TotalDays)
                if ($dd -le 3) { $foundExpense = $exp; break }
            }
        }
        if ($foundExpense) {
            # Skip exempt vendors — these have receipts that match a different
            # expense in the local filesystem (e.g., Anomaly's receipts match
            # their corresponding expense, not the bare amount on the bank txn).
            # Check both the vendor field AND the filename (the script adds new
            # manifest entries with empty vendor after upload, so filename is
            # the more reliable signal for re-runs).
            $vendorLower = "$($lr.Vendor)".ToLower()
            $filenameLower = "$($lr.Filename)".ToLower()
            $isExempt = $false
            foreach ($ev in $ExemptVendors) {
                $evLower = $ev.ToLower()
                if ($vendorLower -like "*$evLower*" -or $filenameLower -like "*$evLower*") {
                    $isExempt = $true; break
                }
            }
            if (-not $isExempt) {
                $localUploadCandidates += @{
                    Receipt = $lr
                    Expense = $foundExpense
                }
            }
        }
    }
}

Write-Host "  Download candidates: $($downloadCandidates.Count)" -ForegroundColor $(if ($downloadCandidates.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Upload candidates:   $($localUploadCandidates.Count)" -ForegroundColor $(if ($localUploadCandidates.Count -gt 0) { "Yellow" } else { "Green" })

$nothingToSync = $downloadCandidates.Count -eq 0 -and $localUploadCandidates.Count -eq 0 -and -not $Force

if ($nothingToSync) {
    Write-Host "`nNothing to sync — local and Zoho are already in sync." -ForegroundColor Green
    return
}

if ($DryRun) {
    Write-Host "`n=== DRY RUN — summary ===" -ForegroundColor Magenta
    if ($downloadCandidates.Count -gt 0) {
        Write-Host "`nWould download $($downloadCandidates.Count) receipts from Zoho:"
        foreach ($exp in $downloadCandidates | Select-Object -First 20) {
            $rName = if ($exp.expense_receipt_name) { $exp.expense_receipt_name } else { "no filename" }
            Write-Host "  $($exp.date) `$$([double]$exp.total) [$rName] expense=$($exp.expense_id)"
        }
        if ($downloadCandidates.Count -gt 20) { Write-Host "  ... and $($downloadCandidates.Count - 20) more" }
    }
    if ($localUploadCandidates.Count -gt 0) {
        Write-Host "`nWould upload $($localUploadCandidates.Count) receipts to Zoho:"
        foreach ($uc in $localUploadCandidates | Select-Object -First 20) {
            Write-Host "  $($uc.Receipt.Date) `$$($uc.Receipt.Amount) $($uc.Receipt.Filename) → expense $($uc.Expense.expense_id)"
        }
        if ($localUploadCandidates.Count -gt 20) { Write-Host "  ... and $($localUploadCandidates.Count - 20) more" }
    }
    return
}

# ─── Phase: Download (Zoho → Local) ─────────────────────────────────────────
if ($Direction -in @("All", "Download")) {
    Write-Host "`n=== Phase: Download Zoho receipts missing locally ===" -ForegroundColor Cyan
    $dlStats = @{ Downloaded = 0; Skipped = 0; Failed = 0; AlreadyPresent = 0 }

    foreach ($exp in $downloadCandidates) {
        $expenseId = $exp.expense_id
        $rName = $exp.expense_receipt_name
        if (-not $rName) { $rName = "receipt-$expenseId.pdf" }
        # Sanitize filename
        $rName = $rName -replace '[<>:"/\\|?*]', '_'

        # Determine target subdirectory from paid_through_account_id
        $targetSubdir = ""
        $pta = $exp.paid_through_account_id
        if ($pta -and $BankAccts.ContainsKey($pta)) {
            $accountName = $BankAccts[$pta]
            if ($AccountToSubdir.ContainsKey($accountName)) {
                $targetSubdir = $AccountToSubdir[$accountName]
            } else {
                $targetSubdir = $accountName
            }
        }
        # Fall back to per-account default for this entity
        if (-not $targetSubdir) {
            if ($Entity -eq "intersite-consulting") { $targetSubdir = "intersite-mc-6258" } else { $targetSubdir = $Manifests[0].Subdir }
        }

        if ($targetSubdir) {
            $targetDir = Join-Path $ReceiptDir $targetSubdir
        } else {
            $targetDir = $ReceiptDir
        }
        $null = New-Item -ItemType Directory -Path $targetDir -Force

        $savePath = Join-Path $targetDir $rName

        if ((Test-Path $savePath) -and -not $Force) {
            Write-Host "  SKIP (exists): $rName" -ForegroundColor Gray
            $dlStats.AlreadyPresent++
            continue
        }

        Write-Host "  Downloading: $rName (expense $expenseId) → $targetSubdir" -ForegroundColor Gray

        try {
            $dlUrl = "https://www.zohoapis.com/books/v3/expenses/$expenseId/receipt?organization_id=$OrgId"
            Invoke-RestMethod -Uri $dlUrl -Headers @{ Authorization = "Zoho-oauthtoken $accessToken" } -Method GET -OutFile $savePath -TimeoutSec 60
            if ((Get-Item $savePath -ErrorAction SilentlyContinue).Length -gt 0) {
                Write-Host "    [OK] $((Get-Item $savePath).Length) bytes" -ForegroundColor Green
                $dlStats.Downloaded++

                Write-AuditEntry -Entry @{
                    ts = (Get-Date -Format 'o')
                    agent = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
                    domain = "Bookkeeper"
                    action = "zoho:expense:download-receipt"
                    req = @{ method = "GET"; url = $dlUrl }
                    res = @{ status = 200; bytes = $webResp.Content.Length }
                } -Domain "Bookkeeper"
            } else {
                Write-Host "    [FAIL] Empty response or status $($webResp.StatusCode)" -ForegroundColor Red
                $dlStats.Failed++
            }
        } catch {
            Write-Host "    [FAIL] $_" -ForegroundColor Red
            $dlStats.Failed++
        }

        Start-Sleep -Milliseconds 500
    }

    Write-Host "`nDownload summary: $($dlStats.Downloaded) downloaded, $($dlStats.AlreadyPresent) already present, $($dlStats.Failed) failed" -ForegroundColor Cyan
}

# ─── Phase: Upload (Local → Zoho) ───────────────────────────────────────────
if ($Direction -in @("All", "Upload")) {
    Write-Host "`n=== Phase: Upload local receipts missing from Zoho ===" -ForegroundColor Cyan
$ulStats = @{ Uploaded = 0; Skipped = 0; Failed = 0; AlreadyAttached = 0; FileNotFound = 0 }

    foreach ($uc in $localUploadCandidates) {
        $receipt = $uc.Receipt
        $expense = $uc.Expense
        $expenseId = $expense.expense_id

        # Resolve actual file path on disk
        $searchPaths = @()
        if ($receipt.Filename) {
            if ($receipt.Subdir) {
                $searchPaths += Join-Path $ReceiptDir $receipt.Subdir (Split-Path $receipt.Filename -Leaf)
            }
            # Also check _orphans/ and the alternate per-account dir
            $searchPaths += Join-Path $ReceiptDir "_orphans" (Split-Path $receipt.Filename -Leaf)
            if ($receipt.Account -eq "intersite-mc-6258") {
                $searchPaths += Join-Path $ReceiptDir "intersite-rbc-chequing" (Split-Path $receipt.Filename -Leaf)
            } elseif ($receipt.Account -eq "intersite-rbc-chequing") {
                $searchPaths += Join-Path $ReceiptDir "intersite-mc-6258" (Split-Path $receipt.Filename -Leaf)
            }
            $searchPaths += Join-Path $ReceiptDir (Split-Path $receipt.Filename -Leaf)
            $searchPaths += $receipt.Filename
        }
        $filePath = $null
        foreach ($sp in $searchPaths) { if (Test-Path $sp) { $filePath = $sp; break } }
        if (-not $filePath) {
            Write-Host "  SKIP (file not found): $($receipt.Filename)" -ForegroundColor Yellow
            $ulStats.FileNotFound++
            continue
        }

        # Re-check has_attachment right before upload to avoid race conditions
        try {
            $checkResp = Invoke-ApiCall -Uri "https://www.zohoapis.com/books/v3/expenses/$expenseId?organization_id=$OrgId" `
                -Headers $headers -Domain "Bookkeeper" -Action "zoho:expenses:get" -TimeoutSec 30
            if ($checkResp.expense -and $checkResp.expense.has_attachment -eq $true) {
                Write-Host "  SKIP (already attached): expense $expenseId" -ForegroundColor Gray
                $ulStats.AlreadyAttached++
                continue
            }
        } catch {
            Write-Host "  [WARN] Could not verify has_attachment for ${expenseId}: $_" -ForegroundColor Yellow
        }

        Write-Host "  Uploading: $(Split-Path $filePath -Leaf) → expense $expenseId" -ForegroundColor Gray

        try {
            $uploadUrl = "https://www.zohoapis.com/books/v3/expenses/$expenseId/receipt?organization_id=$OrgId"
            $curlResult = & curl.exe -s -X POST -H "Authorization: Zoho-oauthtoken $accessToken" -F "receipt=@$filePath" $uploadUrl 2>&1
            $curlParsed = $curlResult | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($curlParsed -and $curlParsed.code -eq 0) {
                Write-Host "    [OK]" -ForegroundColor Green
                $ulStats.Uploaded++

                Write-AuditEntry -Entry @{
                    ts = (Get-Date -Format 'o')
                    agent = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
                    domain = "Bookkeeper"
                    action = "zoho:expense:upload-attachment"
                    req = @{ method = "POST"; url = $uploadUrl }
                    res = @{ status = 200; upload_ok = $true }
                } -Domain "Bookkeeper"
            } else {
                $errMsg = if ($curlParsed) { "code=$($curlParsed.code) $($curlParsed.message)" } else { $curlResult }
                Write-Host "    [FAIL] $errMsg" -ForegroundColor Red
                $ulStats.Failed++
            }
        } catch {
            Write-Host "    [FAIL] $_" -ForegroundColor Red
            $ulStats.Failed++
        }

        Start-Sleep -Milliseconds 500
    }

    Write-Host "`nUpload summary: $($ulStats.Uploaded) uploaded, $($ulStats.AlreadyAttached) already attached, $($ulStats.Failed) failed, $($ulStats.FileNotFound) file not found" -ForegroundColor Cyan
}

# ─── Post-sync: Rebuild TAS and status check ─────────────────────────────────
if (-not $SkipTasRebuild) {
    Write-Host "`n=== Post-sync: Rebuilding TAS and updating status ===" -ForegroundColor Cyan

    if (Test-Path $TasScript) {
        Write-Host "Running: & $TasScript -RootDir $TasDir" -ForegroundColor Gray
        & $TasScript -RootDir $TasDir
        Write-Host "  TAS rebuild complete" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] TAS script not found: $TasScript" -ForegroundColor Yellow
    }

    $statusScript = Join-Path $scriptDir "Invoke-StatusCheck.ps1"
    if (Test-Path $statusScript) {
        Write-Host "Running: & $statusScript -Organization $Entity -Rebuild" -ForegroundColor Gray
        & $statusScript -Organization $Entity -Rebuild
        Write-Host "  Status check complete" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] StatusCheck script not found: $statusScript" -ForegroundColor Yellow
    }
}

# ─── Final summary ───────────────────────────────────────────────────────────
Write-Host "`n$('='*60)" -ForegroundColor Cyan
Write-Host "Sync complete: $Entity" -ForegroundColor Cyan
if ($Direction -in @("All", "Download")) {
    Write-Host "  Downloaded: $($dlStats.Downloaded)" -ForegroundColor Green
    Write-Host "  Already local: $($dlStats.AlreadyPresent)" -ForegroundColor Gray
    Write-Host "  Download errors: $($dlStats.Failed)" -ForegroundColor $(if ($dlStats.Failed -gt 0) { "Red" } else { "Green" })
}
if ($Direction -in @("All", "Upload")) {
    Write-Host "  Uploaded: $($ulStats.Uploaded)" -ForegroundColor Green
    Write-Host "  Already attached: $($ulStats.AlreadyAttached)" -ForegroundColor Gray
    Write-Host "  File not found: $($ulStats.FileNotFound)" -ForegroundColor Yellow
    Write-Host "  Upload errors: $($ulStats.Failed)" -ForegroundColor $(if ($ulStats.Failed -gt 0) { "Red" } else { "Green" })
}
Write-Host "$('='*60)" -ForegroundColor Cyan
