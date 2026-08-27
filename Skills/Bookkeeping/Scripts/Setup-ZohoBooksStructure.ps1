<#
.SYNOPSIS
    One-time Zoho Books structure setup — chart of accounts sync + bank account creation
.DESCRIPTION
    Connects to Wave to extract chart-of-account usage across all 4 businesses,
    mirrors missing accounts into Zoho Books (both orgs), creates 4 bank account
    ledgers, and outputs account-mapping JSON files for use by the migration script.
    Idempotent — safe to re-run.
#>

[CmdletBinding()]
param(
    [string]$ApiProxyUrl = "http://is-bookkeeping:21008",
    [string]$IntersiteOrgId = $env:ZOHO_ORG_ID_INTERSITE,
    [string]$RoomRentalsOrgId = $env:ZOHO_ORG_ID_ROOM_RENTALS,
    [switch]$Force
)

function Invoke-ZohoProxy {
    param($Endpoint, $Body)
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    try {
        $r = Invoke-ApiCall -Uri "$ApiProxyUrl$Endpoint" -Method POST `
            -Body $json -Domain "Bookkeeper" -Action "proxy:chart-of-accounts" -TimeoutSec 60
        if (-not $r.success) {
            Write-Warning "Zoho API error: $($r.error) $($r.detail)"
            return $null
        }
        return $r
    } catch {
        Write-Error "Proxy call failed: $_"
        return $null
    }
}

function Invoke-WaveProxy {
    param($Endpoint, $Body)
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    try {
        $r = Invoke-ApiCall -Uri "$ApiProxyUrl$Endpoint" -Method POST `
            -Body $json -Domain "Bookkeeper" -Action "proxy:list-accounts" -TimeoutSec 60
        if (-not $r.success) {
            Write-Warning "Wave API error: $($r.error) $($r.detail)"
            return $null
        }
        return $r
    } catch {
        Write-Error "Proxy call failed: $_"
        return $null
    }
}

function Get-CadCurrencyId {
    param($OrgId)
    $orgDetail = Invoke-ZohoProxy -Endpoint "/zoho.organization.get" -Body @{ organization_id = $OrgId }
    if (-not $orgDetail -or -not $orgDetail.organization) { return $null }
    $cad = $orgDetail.organization.currencies | Where-Object { $_.currencyCode -eq "CAD" }
    if ($cad) { return $cad.currencyId }
    return $null
}

function Sync-ZohoChartOfAccounts {
    param($WaveAccounts, $ZohoExistingAccounts, $OrganizationId, $OrgLabel)

    $created = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $mapping = @{}
    $zohoAccountNames = $ZohoExistingAccounts.accounts | ForEach-Object { $_.accountName } | Sort-Object

    foreach ($waveAcct in $WaveAccounts) {
        if ($waveAcct.name -in $zohoAccountNames) {
            $skipped.Add("$($waveAcct.name) (already exists)")
            $existing = $ZohoExistingAccounts.accounts | Where-Object { $_.accountName -eq $waveAcct.name } | Select-Object -First 1
            if ($existing) { $mapping[$waveAcct.id] = $existing.accountId }
            continue
        }

        $zohoType = Switch ($waveAcct.type) {
            "INCOME"    { "Income" }
            "EXPENSE"   { "Expense" }
            "ASSET"     { "Asset" }
            "LIABILITY" { "Liability" }
            "EQUITY"    { "Equity" }
            default     { "Expense" }
        }

        if ($waveAcct.type -eq "BANK") {
            $skipped.Add("$($waveAcct.name) (bank account — created separately)")
            continue
        }

        $internalSkipPatterns = @("Tax", "Retained Earnings", "Opening Balance", "Historical Adjustment")
        $shouldSkip = $false
        foreach ($pattern in $internalSkipPatterns) {
            if ($waveAcct.name -match $pattern) { $shouldSkip = $true; break }
        }
        if ($shouldSkip) {
            $skipped.Add("$($waveAcct.name) (internal Zoho account — skipped)")
            continue
        }

        $result = Invoke-ZohoProxy -Endpoint "/zoho.chartofaccounts.create" -Body @{
            organization_id = $OrganizationId
            account_name    = $waveAcct.name
            account_type    = $zohoType
            description     = "Migrated from Wave — $($waveAcct.name)"
        }
        if ($result -and $result.account) {
            $created.Add("$($waveAcct.name) → $zohoType")
            $mapping[$waveAcct.id] = $result.account.accountId
            Write-Host "  [CREATED] $($OrgLabel): $($waveAcct.name) ($zohoType)" -ForegroundColor Green
            Start-Sleep -Milliseconds 200
        } else {
            Write-Warning "  [FAILED] $($OrgLabel): $($waveAcct.name)"
        }
    }

    return $created, $skipped, $mapping
}

function Get-WaveAccountsForBusiness {
    param($BusinessId, $BusinessLabel)
    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $page = 1
    $pageSize = 100
    do {
        $resp = Invoke-WaveProxy -Endpoint "/wave.accounts.list" -Body @{
            businessId = $BusinessId
            page       = $page
            pageSize   = $pageSize
        }
        if (-not $resp -or -not $resp.accounts) { break }
        $allAccounts.AddRange($resp.accounts)
        $hasMore = ($resp.pageInfo.totalPages -gt $page)
        $page++
        if ($hasMore) { Start-Sleep -Milliseconds 300 }
    } while ($hasMore)
    Write-Host "  $BusinessLabel`: $($allAccounts.Count) accounts found" -ForegroundColor Gray
    return $allAccounts
}

function Get-BankAccountZohoMapping {
    param($WaveBusinessName)
    $mapping = @{
        "Intersite" = @{ bankName = "RBC Royal Bank"; accountName = "RBC Intersite Consulting Inc."; accountType = "Chequing" }
        "Francis"   = @{ bankName = "RBC Royal Bank"; accountName = "RBC Francis"; accountType = "Chequing" }
        "MLM"       = @{ bankName = "TD Canada Trust"; accountName = "TD MLM"; accountType = "Chequing" }
        "TMH"       = @{ bankName = "Scotiabank"; accountName = "Scotia TMH"; accountType = "Chequing" }
    }
    return $mapping[$WaveBusinessName]
}

function Ensure-BankAccount {
    param($OrgId, $AccountName, $BankName, $CadCurrencyId, $OrgLabel)

    $existing = Invoke-ZohoProxy -Endpoint "/zoho.bankaccounts.list" -Body @{ organization_id = $OrgId }
    $match = $existing.bankAccounts | Where-Object { $_.accountName -eq $AccountName } | Select-Object -First 1
    if ($match) {
        Write-Host "  [SKIP] Bank account '$AccountName' already exists (ID: $($match.accountId))" -ForegroundColor Yellow
        return $match.accountId
    }

    $result = Invoke-ZohoProxy -Endpoint "/zoho.bankaccounts.create" -Body @{
        organization_id = $OrgId
        account_name    = $AccountName
        account_type    = "Bank"
        bank_name       = $BankName
        currency_id     = $CadCurrencyId
    }
    if ($result -and $result.account) {
        Write-Host "  [CREATED] $OrgLabel`: $AccountName (ID: $($result.account.accountId))" -ForegroundColor Green
        return $result.account.accountId
    } else {
        Write-Warning "  [FAILED] $OrgLabel`: $AccountName"
        return $null
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Zoho Books Structure Setup Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $IntersiteOrgId -or -not $RoomRentalsOrgId) {
    Write-Error "ZOHO_ORG_ID_INTERSITE and ZOHO_ORG_ID_ROOM_RENTALS must be set."
    exit 1
}

# === PHASE 1: Verify org connectivity + resolve CAD currency IDs ===
Write-Host "=== Phase 1: Verify Zoho organizations ===" -ForegroundColor Cyan
$org1 = Invoke-ZohoProxy -Endpoint "/zoho.organization.get" -Body @{ organization_id = $IntersiteOrgId }
if (-not $org1) { throw "Cannot reach Zoho Org 1 (Intersite). Check org ID and credentials." }
Write-Host "  Org 1: $($org1.organization.name) — OK" -ForegroundColor Green

$org2 = Invoke-ZohoProxy -Endpoint "/zoho.organization.get" -Body @{ organization_id = $RoomRentalsOrgId }
if (-not $org2) { throw "Cannot reach Zoho Org 2 (Room Rentals). Check org ID and credentials." }
Write-Host "  Org 2: $($org2.organization.name) — OK" -ForegroundColor Green

$intersiteCurrencyId = Get-CadCurrencyId -OrgId $IntersiteOrgId
$roomRentalsCurrencyId = Get-CadCurrencyId -OrgId $RoomRentalsOrgId
Write-Host "  CAD currency ID (Intersite): $intersiteCurrencyId" -ForegroundColor Gray
Write-Host "  CAD currency ID (Room Rentals): $roomRentalsCurrencyId" -ForegroundColor Gray
Write-Host ""

# === PHASE 2: List existing Zoho chart of accounts ===
Write-Host "=== Phase 2: List existing Zoho chart of accounts ===" -ForegroundColor Cyan
$existingIntersite = Invoke-ZohoProxy -Endpoint "/zoho.chartofaccounts.list" -Body @{ organization_id = $IntersiteOrgId; per_page = 200 }
$existingRoomRentals = Invoke-ZohoProxy -Endpoint "/zoho.chartofaccounts.list" -Body @{ organization_id = $RoomRentalsOrgId; per_page = 200 }

$intersiteCoaCount = if ($existingIntersite -and $existingIntersite.accounts) { $existingIntersite.accounts.Count } else { 0 }
$roomRentalsCoaCount = if ($existingRoomRentals -and $existingRoomRentals.accounts) { $existingRoomRentals.accounts.Count } else { 0 }
Write-Host "  Org 1 (Intersite): $intersiteCoaCount existing accounts" -ForegroundColor Gray
Write-Host "  Org 2 (Room Rentals): $roomRentalsCoaCount existing accounts" -ForegroundColor Gray

if ($existingIntersite -and $existingIntersite.accounts) {
    $existingIntersite.accounts | ConvertTo-Json -Depth 5 | Out-File "$PSScriptRoot/../_zoho-intersite-existing-coa.json"
    Write-Host "  Exported to _zoho-intersite-existing-coa.json" -ForegroundColor Gray
}
if ($existingRoomRentals -and $existingRoomRentals.accounts) {
    $existingRoomRentals.accounts | ConvertTo-Json -Depth 5 | Out-File "$PSScriptRoot/../_zoho-room-rentals-existing-coa.json"
    Write-Host "  Exported to _zoho-room-rentals-existing-coa.json" -ForegroundColor Gray
}
Write-Host ""

# === PHASE 3: Discover Wave businesses and their chart of accounts ===
Write-Host "=== Phase 3: Extract Wave chart of accounts ===" -ForegroundColor Cyan
$waveBusinessesResp = Invoke-WaveProxy -Endpoint "/wave.businesses.list" -Body @{}
if (-not $waveBusinessesResp -or -not $waveBusinessesResp.businesses) {
    throw "Cannot list Wave businesses. Check Wave credentials."
}
Write-Host "  Found $($waveBusinessesResp.businesses.Count) Wave businesses" -ForegroundColor Gray

$waveBusinessMap = @{}
foreach ($wb in $waveBusinessesResp.businesses) {
    $name = $wb.name -replace ' ', ''
    if ($name -like "*Intersite*") { $waveBusinessMap["Intersite"] = $wb.businessId }
    elseif ($name -like "*Francis*" -or $name -like "*Rental*") { $waveBusinessMap["Francis"] = $wb.businessId }
    elseif ($name -like "*MLM*" -or $name -like "*Mile*") { $waveBusinessMap["MLM"] = $wb.businessId }
    elseif ($name -like "*TMH*" -or $name -like "*Three*") { $waveBusinessMap["TMH"] = $wb.businessId }
    else { Write-Warning "  Unmapped Wave business: $($wb.name) ($($wb.businessId))" }
}

$waveAccountsByBusiness = @{}
foreach ($key in $waveBusinessMap.Keys) {
    $bizId = $waveBusinessMap[$key]
    Write-Host "  Querying accounts for $key ($bizId)..." -ForegroundColor Gray
    $waveAccountsByBusiness[$key] = Get-WaveAccountsForBusiness -BusinessId $bizId -BusinessLabel $key
}

$allWaveAccounts = [System.Collections.Generic.List[object]]::new()
$waveAccountsByBusiness.Values | ForEach-Object { $allWaveAccounts.AddRange($_) }
Write-Host "  Total unique Wave accounts (all businesses): $(($allWaveAccounts | Select-Object -Property id -Unique).Count)" -ForegroundColor Gray
Write-Host ""

# === PHASE 4: Sync missing chart-of-accounts entries ===
Write-Host "=== Phase 4: Create missing chart of accounts entries ===" -ForegroundColor Cyan

$intersiteCreated = [System.Collections.Generic.List[string]]::new()
$intersiteSkipped = [System.Collections.Generic.List[string]]::new()
$intersiteMapping = @{}

$roomRentalsCreated = [System.Collections.Generic.List[string]]::new()
$roomRentalsSkipped = [System.Collections.Generic.List[string]]::new()
$roomRentalsMapping = @{}

foreach ($key in $waveAccountsByBusiness.Keys) {
    $orgId = if ($key -eq "Intersite") { $IntersiteOrgId } else { $RoomRentalsOrgId }
    $existingCoa = if ($key -eq "Intersite") { $existingIntersite } else { $existingRoomRentals }
    $orgLabel = if ($key -eq "Intersite") { "Intersite" } else { "Room Rentals" }

    $created, $skipped, $mapping = Sync-ZohoChartOfAccounts `
        -WaveAccounts $waveAccountsByBusiness[$key] `
        -ZohoExistingAccounts $existingCoa `
        -OrganizationId $orgId `
        -OrgLabel "$orgLabel ($key)"

    if ($key -eq "Intersite") {
        $intersiteCreated = $created
        $intersiteSkipped = $skipped
        $intersiteMapping = $mapping
    } else {
        $roomRentalsCreated.AddRange($created)
        $roomRentalsSkipped.AddRange($skipped)
        foreach ($k in $mapping.Keys) { $roomRentalsMapping[$k] = $mapping[$k] }
    }
}

# Remove duplicates from room rentals
$roomRentalsCreated = $roomRentalsCreated | Select-Object -Unique
$roomRentalsSkipped = $roomRentalsSkipped | Select-Object -Unique

Write-Host "  Intersite: $($intersiteCreated.Count) created, $($intersiteSkipped.Count) skipped" -ForegroundColor Gray
Write-Host "  Room Rentals: $($roomRentalsCreated.Count) created, $($roomRentalsSkipped.Count) skipped" -ForegroundColor Gray
Write-Host ""

# === PHASE 5: Create 4 bank accounts ===
Write-Host "=== Phase 5: Create bank accounts ===" -ForegroundColor Cyan

$bankResults = @{}

foreach ($key in $waveBusinessMap.Keys) {
    $orgId = if ($key -eq "Intersite") { $IntersiteOrgId } else { $RoomRentalsOrgId }
    $currencyId = if ($key -eq "Intersite") { $intersiteCurrencyId } else { $roomRentalsCurrencyId }
    $bankInfo = Get-BankAccountZohoMapping -WaveBusinessName $key
    if (-not $bankInfo) { continue }

    $orgLabel = if ($key -eq "Intersite") { "Intersite" } else { "Room Rentals" }
    $accountId = Ensure-BankAccount `
        -OrgId $orgId `
        -AccountName $bankInfo.accountName `
        -BankName $bankInfo.bankName `
        -CadCurrencyId $currencyId `
        -OrgLabel "$orgLabel ($key)"
    $bankResults[$key] = @{ accountId = $accountId; accountName = $bankInfo.accountName }
    Start-Sleep -Milliseconds 300
}
Write-Host ""

# === PHASE 6: Build account mapping JSON files ===
Write-Host "=== Phase 6: Generate account mapping files ===" -ForegroundColor Cyan

function Get-MergedMapping {
    param($OrgId, $WaveAccountMapping, $OrgLabel)
    $existing = Invoke-ZohoProxy -Endpoint "/zoho.chartofaccounts.list" -Body @{ organization_id = $OrgId; per_page = 200 }
    if (-not $existing -or -not $existing.accounts) { return @{} }

    $merged = @{}
    foreach ($zohoAcct in $existing.accounts) {
        $waveId = $null
        foreach ($wId in $WaveAccountMapping.Keys) {
            if ($WaveAccountMapping[$wId] -eq $zohoAcct.accountId) {
                $waveId = $wId
                break
            }
        }
        $merged[$zohoAcct.accountName] = @{
            zohoAccountId = $zohoAcct.accountId
            zohoType      = $zohoAcct.accountType
            waveAccountId = $waveId
        }
    }
    return $merged
}

$intersiteFinalMapping = Get-MergedMapping -OrgId $IntersiteOrgId -WaveAccountMapping $intersiteMapping -OrgLabel "Intersite"
$roomRentalsFinalMapping = Get-MergedMapping -OrgId $RoomRentalsOrgId -WaveAccountMapping $roomRentalsMapping -OrgLabel "Room Rentals"

$intersiteFinalMapping | ConvertTo-Json -Depth 3 | Out-File "$PSScriptRoot/../zoho-intersite-account-map.json"
$roomRentalsFinalMapping | ConvertTo-Json -Depth 3 | Out-File "$PSScriptRoot/../zoho-room-rentals-account-map.json"
Write-Host "  Account mapping saved to zoho-intersite-account-map.json" -ForegroundColor Green
Write-Host "  Account mapping saved to zoho-room-rentals-account-map.json" -ForegroundColor Green
Write-Host ""

# === SUMMARY ===
Write-Host "=== SETUP COMPLETE ===" -ForegroundColor Cyan
Write-Host "Org 1 (Intersite):" -ForegroundColor Yellow
$intersiteBank = $bankResults["Intersite"]
if ($intersiteBank) {
    Write-Host "  Bank account: $($intersiteBank.accountName) (ID: $($intersiteBank.accountId))" -ForegroundColor Gray
} else {
    Write-Host "  Bank account: (none created)" -ForegroundColor Yellow
}
Write-Host "  COA accounts: $($intersiteCreated.Count) created, $($intersiteSkipped.Count) skipped" -ForegroundColor Gray

Write-Host "Org 2 (Room Rentals):" -ForegroundColor Yellow
foreach ($key in @("Francis", "MLM", "TMH")) {
    $bk = $bankResults[$key]
    if ($bk) {
        Write-Host "  Bank account: $($bk.accountName) (ID: $($bk.accountId))" -ForegroundColor Gray
    } else {
        Write-Host "  Bank account: $key (not found in Wave)" -ForegroundColor Yellow
    }
}
Write-Host "  COA accounts: $($roomRentalsCreated.Count) created, $($roomRentalsSkipped.Count) skipped" -ForegroundColor Gray

$mappingFilesExist = (Test-Path "$PSScriptRoot/../zoho-intersite-account-map.json") -or (Test-Path "$PSScriptRoot/../zoho-room-rentals-account-map.json")
if ($mappingFilesExist) {
    Write-Host "`nAccount mapping files ready for migration script" -ForegroundColor Green
} else {
    Write-Host "`nNo mapping files generated" -ForegroundColor Yellow
}

Write-Host "`nDone. Run the migration script (Session 4) to import transactions." -ForegroundColor Cyan