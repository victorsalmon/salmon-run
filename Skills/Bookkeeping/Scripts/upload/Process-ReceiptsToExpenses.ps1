<#
.SYNOPSIS
    Process receipt manifests and upload them as Zoho Books expenses with receipt images.
.DESCRIPTION
    Reads Complete/manifest.csv from each entity's receipt processing output directory,
    maps each receipt to a Zoho expense category using vendor keyword mappings,
    creates the expense and uploads the receipt image via the api-proxy.
    Supports resumption, rate-limit-aware retry, and detailed reporting.
.PARAMETER ApiProxyUrl
    Base URL of the api-proxy service. Default: http://is-bookkeeping:21008
.PARAMETER ReceiptsRoot
    Root directory containing entity subdirectories with Complete/manifest.csv.
    Default: /data/receipts (proxy_audit mount)
.PARAMETER OrganizationId
    Zoho Books organization ID. If not set, uses ZOHO_ORG_ID_INTERSITE from env.
.PARAMETER Resume
    Resume a previous run (skips already-imported receipt hashes).
.PARAMETER Force
    Re-import receipts even if previously imported.
.PARAMETER DryRun
    Print what would be done without making API calls.
.PARAMETER VendorMappingPath
    Path to JSON file with vendor-to-account_id mappings.
    Default: looks for vendor-mappings.json in the same directory.
.EXAMPLE
    .\Process-ReceiptsToExpenses.ps1 -OrganizationId "123456789" -DryRun
    Preview which receipts would be imported.
.EXAMPLE
    .\Process-ReceiptsToExpenses.ps1 -Resume
    Resume a partially completed import.
#>
[CmdletBinding()]
param(
    [string]$ApiProxyUrl = "http://is-bookkeeping:21008",
    [string]$ReceiptsRoot = "/data/receipts",
    [string]$OrganizationId = $env:ZOHO_ORG_ID_INTERSITE,
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,
    [switch]$Resume,
    [switch]$Force,
    [switch]$DryRun,
    [string]$VendorMappingPath = (Join-Path $PSScriptRoot "vendor-mappings.json")
)

$ErrorActionPreference = "Stop"

$script:StateDir = "Process-ReceiptsState"
$script:MaxRetries = 5
$script:RetryDelayMs = 3000

# Load entity vendor mappings from cloud-books-entities.json
$script:EntityVendorMappings = @{}
$script:EntityCategories = @{}
if ($Entity) {
    $configPaths = @(
        Join-Path $PSScriptRoot ".." ".." "cloud-books-entities.json"
        Join-Path (Resolve-Path "$PSScriptRoot\..\..") "cloud-books-entities.json"
    )
    foreach ($cp in $configPaths) {
        if (Test-Path $cp) {
            try {
                $ec = Get-Content $cp -Raw | ConvertFrom-Json -AsHashtable
                $entityCfg = $ec.entities[$Entity]
                if ($entityCfg) {
                    if ($entityCfg.vendor_mappings) {
                        foreach ($kv in $entityCfg.vendor_mappings.GetEnumerator()) {
                            $script:EntityVendorMappings[$kv.Key] = @{ account_id = $null; category = $kv.Value }
                        }
                    }
                    if ($entityCfg.categories) {
                        $script:EntityCategories = $entityCfg.categories
                    }
                }
            } catch { Write-Warning "Could not load entity config from $cp" }
            break
        }
    }
}

function Get-VendorMappings {
    $mappings = $null
    if ($script:EntityVendorMappings.Count -gt 0) {
        $mappings = $script:EntityVendorMappings
    }
    if (-not $mappings -and (Test-Path $VendorMappingPath)) {
        Write-Host "Loading vendor mappings from $VendorMappingPath" -ForegroundColor Gray
        $mappings = Get-Content $VendorMappingPath | ConvertFrom-Json -AsHashtable
    }
    if (-not $mappings) {
        $mappings = @{}
    }
    return $mappings
}

function Get-ResolvedAccountIds {
    param([string]$ApiProxyUrl, [string]$OrgId)

    Write-Host "Fetching expense accounts from Chart of Accounts..." -ForegroundColor Cyan
    try {
        $body = @{ organization_id = $OrgId; filter = "AccountType.Expenses" } | ConvertTo-Json
        $result = Invoke-ApiCall -Uri "$ApiProxyUrl/zoho.chartofaccounts.list" -Method POST `
            -Body $body -Domain "Bookkeeper" -Action "proxy:chart-of-accounts" -TimeoutSec 30
        if (-not $result.success) {
            Write-Warning "Failed to fetch chart of accounts: $($result | ConvertTo-Json)"
            return @{}
        }
        $accountMap = @{}
        foreach ($acct in $result.accounts) {
            $key = $acct.accountName.ToUpperInvariant()
            $accountMap[$key] = $acct.accountId
        }
        Write-Host "  Resolved $($accountMap.Count) expense accounts" -ForegroundColor Green
        return $accountMap
    }
    catch {
        Write-Warning "Error fetching chart of accounts: $_"
        return @{}
    }
}

function Convert-VendorToAccountId {
    param([string]$Vendor, [hashtable]$VendorMappings, [hashtable]$AccountNameToId)

    $vendorUpper = $Vendor.ToUpperInvariant().Trim()
    foreach ($keyword in $VendorMappings.Keys) {
        if ($vendorUpper -match [regex]::Escape($keyword)) {
            $mapping = $VendorMappings[$keyword]
            if ($mapping.account_id) { return $mapping.account_id }
            $categoryKey = $mapping.category
            # First: resolve from entity categories (local config)
            if ($script:EntityCategories.ContainsKey($categoryKey)) {
                return $script:EntityCategories[$categoryKey]
            }
            # Second: resolve from API-fetched chart of accounts
            $catUpper = $categoryKey.ToUpperInvariant()
            if ($AccountNameToId[$catUpper]) { return $AccountNameToId[$catUpper] }
            if ($AccountNameToId[$mapping.category.ToUpperInvariant()]) {
                return $AccountNameToId[$mapping.category.ToUpperInvariant()]
            }
            Write-Warning "  Category '$categoryKey' not found for vendor '$Vendor'"
            return $null
        }
    }

    foreach ($key in $AccountNameToId.Keys) {
        if ($vendorUpper -match [regex]::Escape($key)) {
            return $AccountNameToId[$key]
        }
    }

    return $null
}

function Find-EntityDirs {
    param([string]$Root, [string]$EntityFilter)
    $dirs = @()
    if (-not (Test-Path $Root)) {
        Write-Warning "Receipts root not found: $Root"
        return $dirs
    }
    $subdirs = Get-ChildItem -Path $Root -Directory
    foreach ($dir in $subdirs) {
        if ($EntityFilter -and $dir.Name -ne $EntityFilter) { continue }
        # Prefer enriched manifest, fall back to raw manifest
        $enrichedPath = Join-Path $dir.FullName "Complete/manifest-enriched.csv"
        $rawPath = Join-Path $dir.FullName "Complete/manifest.csv"
        $manifestPath = if (Test-Path $enrichedPath) { $enrichedPath } elseif (Test-Path $rawPath) { $rawPath } else { $null }
        if ($manifestPath) {
            $dirs += [pscustomobject]@{
                EntityName = $dir.Name
                ManifestPath = $manifestPath
                CompleteDir = Join-Path $dir.FullName "Complete"
            }
        }
    }
    return $dirs
}

function Read-Manifest {
    param([string]$ManifestPath)
    $receipts = @()
    if (-not (Test-Path $ManifestPath)) { return $receipts }
    try {
        $lines = Get-Content $ManifestPath
        if ($lines.Count -lt 2) { return $receipts }
        $headers = ($lines[0] -split ',').Trim().ToLowerInvariant()
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $values = ($lines[$i] -split ',').Trim()
            $entry = [ordered]@{}
            for ($j = 0; $j -lt $headers.Count -and $j -lt $values.Count; $j++) {
                $entry[$headers[$j]] = $values[$j]
            }
            if ($entry.filename -and $entry.amount -and -not [string]::IsNullOrWhiteSpace($entry.amount)) {
                $receipts += [pscustomobject]$entry
            }
        }
    }
    catch {
        Write-Warning "Error reading manifest $ManifestPath : $_"
    }
    return $receipts
}

function Import-ReceiptAsExpense {
    param(
        [string]$ApiProxyUrl,
        [string]$OrganizationId,
        [string]$AccountId,
        [string]$Vendor,
        [double]$Amount,
        [string]$Date,
        [string]$Description,
        [string]$ReceiptImagePath,
        [string]$ReceiptHash
    )

    $body = @{
        organization_id = $OrganizationId
        account_id      = $AccountId
        amount          = $Amount
        date            = $Date
        vendor          = $Vendor
        description     = $Description
    }

    if ($ReceiptImagePath -and (Test-Path $ReceiptImagePath)) {
        $imageBytes = [System.IO.File]::ReadAllBytes($ReceiptImagePath)
        $body.receipt_base64 = [System.Convert]::ToBase64String($imageBytes)
        $body.receipt_filename = [System.IO.Path]::GetFileName($ReceiptImagePath)
    }

    $attempt = 0
    do {
        $attempt++
        try {
            $json = $body | ConvertTo-Json -Depth 5 -Compress
            $result = Invoke-ApiCall -Uri "$ApiProxyUrl/zoho.expenses.create" -Method POST `
                -Body $json -Domain "Bookkeeper" -Action "proxy:expense-create" -TimeoutSec 120
            if ($result.success) {
                return [pscustomobject]@{ Success = $true; ExpenseId = $result.expenseId; ReceiptUploaded = $result.receiptUploaded }
            }
            if ($result.error -match 'rate limit|too many requests|429') {
                $delay = $script:RetryDelayMs * [math]::Pow(2, $attempt - 1) + (Get-Random -Minimum 0 -Maximum 2000)
                Write-Host "    Rate limited — waiting $($delay)ms (attempt $attempt/$($script:MaxRetries))" -ForegroundColor Yellow
                Start-Sleep -Milliseconds $delay
                continue
            }
            return [pscustomobject]@{ Success = $false; Error = $result.error }
        }
        catch {
            if ($attempt -ge $script:MaxRetries) {
                return [pscustomobject]@{ Success = $false; Error = "$_" }
            }
            $delay = $script:RetryDelayMs * [math]::Pow(2, $attempt - 1)
            Write-Host "    API error — retrying in $($delay)ms (attempt $attempt/$($script:MaxRetries))" -ForegroundColor Yellow
            Start-Sleep -Milliseconds $delay
        }
    } while ($attempt -lt $script:MaxRetries)

    return [pscustomobject]@{ Success = $false; Error = "Max retries exceeded" }
}

function Write-ProgressReport {
    param($Results, [string]$EntityName)
    $total = $Results.Count
    $imported = ($Results | Where-Object { $_.Success }).Count
    $failed = ($Results | Where-Object { -not $_.Success }).Count
    Write-Host "  [$EntityName] $imported/$total imported, $failed failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
    if ($failed -gt 0) {
        foreach ($r in $Results | Where-Object { -not $_.Success }) {
            Write-Host "    FAIL: $($r.Filename): $($r.Error)" -ForegroundColor Red
        }
    }
}

$null = New-Item -ItemType Directory -Path $script:StateDir -Force

$vendorMappings = Get-VendorMappings
$accountNameToId = Get-ResolvedAccountIds -ApiProxyUrl $ApiProxyUrl -OrgId $OrganizationId

$entityDirs = Find-EntityDirs -Root $ReceiptsRoot -EntityFilter $Entity
if ($entityDirs.Count -eq 0) {
    Write-Host "No receipt manifests found in $ReceiptsRoot" -ForegroundColor Yellow
    return
}

$allResults = @()

foreach ($entity in $entityDirs) {
    Write-Host "`n=== Entity: $($entity.EntityName) ===" -ForegroundColor Cyan
    $receipts = Read-Manifest -ManifestPath $entity.ManifestPath
    Write-Host "  Found $($receipts.Count) receipts in manifest" -ForegroundColor Gray

    $stateFile = Join-Path $script:StateDir "$($entity.EntityName -replace '[^a-zA-Z0-9]', '_').json"
    $importedHashes = @()
    if ((Test-Path $stateFile) -and $Resume -and -not $Force) {
        $state = Get-Content $stateFile | ConvertFrom-Json
        $importedHashes = @($state.imported_hashes)
        Write-Host "  [RESUME] $($importedHashes.Count) receipts already imported" -ForegroundColor Yellow
    }

    $entityResults = [System.Collections.Generic.List[object]]::new()

    foreach ($receipt in $receipts) {
        $hash = if ($receipt.hash) { $receipt.hash } else { $receipt.filename }

        if ($hash -in $importedHashes -and -not $Force) {
            Write-Host "  SKIP (already imported): $($receipt.filename)" -ForegroundColor Gray
            continue
        }

        # Check enrichment status from enriched manifest
        if ($receipt.enrichment_status -eq 'skipped') {
            $reason = if ($receipt.skip_reason) { $receipt.skip_reason } else { "marked skipped in enrichment" }
            Write-Host "  SKIP ($reason): $($receipt.filename)" -ForegroundColor Gray
            continue
        }

        $amount = [double]($receipt.amount -replace '[^0-9.]', '')
        if ($amount -le 0) {
            Write-Host "  SKIP (zero amount): $($receipt.filename)" -ForegroundColor Gray
            continue
        }

        $vendor = if ($receipt.vendor) { $receipt.vendor } else { "Unknown Vendor" }
        $date = if ($receipt.date) { $receipt.date } else { (Get-Date -Format "yyyy-MM-dd") }
        $notes = if ($receipt.notes) { $receipt.notes } else { "" }

        # Prefer suggested_account_id from enriched manifest, then fall back to keyword mapping
        $accountId = if ($receipt.suggested_account_id) { $receipt.suggested_account_id } else { Convert-VendorToAccountId -Vendor $vendor -VendorMappings $vendorMappings -AccountNameToId $accountNameToId }
        if (-not $accountId) {
            Write-Host "  SKIP (no account mapping): $($receipt.filename) vendor=$vendor" -ForegroundColor Yellow
            $entityResults.Add([pscustomobject]@{ Success = $false; Filename = $receipt.filename; Error = "No account mapping for vendor: $vendor" })
            continue
        }

        $imagePath = Join-Path $entity.CompleteDir $receipt.filename

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would import: $($receipt.filename) — vendor=$vendor amount=$amount account=$accountId" -ForegroundColor Magenta
            $entityResults.Add([pscustomobject]@{ Success = $true; Filename = $receipt.filename; ExpenseId = "dry-run" })
            continue
        }

        Write-Host "  Importing: $($receipt.filename) ($vendor, $amount)" -ForegroundColor Gray
        $result = Import-ReceiptAsExpense -ApiProxyUrl $ApiProxyUrl -OrganizationId $OrganizationId `
            -AccountId $accountId -Vendor $vendor -Amount $amount -Date $date `
            -Description $notes -ReceiptImagePath $imagePath -ReceiptHash $hash

        if ($result.Success) {
            Write-Host "    OK — expenseId=$($result.ExpenseId), receipt=$($result.ReceiptUploaded)" -ForegroundColor Green
            $entityResults.Add([pscustomobject]@{ Success = $true; Filename = $receipt.filename; ExpenseId = $result.ExpenseId; ReceiptUploaded = $result.ReceiptUploaded })
        }
        else {
            Write-Host "    FAIL — $($result.Error)" -ForegroundColor Red
            $entityResults.Add([pscustomobject]@{ Success = $false; Filename = $receipt.filename; Error = $result.Error })
        }

        $importedHashes += $hash
        $state = @{
            imported_count  = ($entityResults | Where-Object { $_.Success }).Count
            imported_hashes = @($importedHashes | Select-Object -Unique)
            entity          = $entity.EntityName
            completed       = $false
        }
        $state | ConvertTo-Json | Out-File $stateFile -Force

        Start-Sleep -Milliseconds 500
    }

    Write-ProgressReport -Results $entityResults -EntityName $entity.EntityName
    $allResults += $entityResults

    $state.completed = ($entityResults | Where-Object { -not $_.Success }).Count -eq 0
    $state | ConvertTo-Json | Out-File $stateFile -Force
}

Write-Host "`n=== OVERALL SUMMARY ===" -ForegroundColor Cyan
$totalReceipts = $allResults.Count
$totalImported = ($allResults | Where-Object { $_.Success }).Count
$totalFailed = ($allResults | Where-Object { -not $_.Success }).Count
Write-Host "Total receipts:   $totalReceipts" -ForegroundColor White
Write-Host "Imported:         $totalImported" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Yellow" })
Write-Host "Failed:           $totalFailed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })
