<#
.SYNOPSIS
    Create expenses for receipt images that have no matching Zoho expense, then upload receipts.
.PARAMETER Entity
    Entity name from cloud-books-entities.json.
.PARAMETER ManifestPath
    Path to the enriched manifest CSV file. Resolved from entity config if not provided.
.PARAMETER AwsProfile
    AWS CLI profile for SM lookup. Default: intersite.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [string]$ManifestPath,

    [string]$AwsProfile = "intersite"
)

$ErrorActionPreference = "Stop"

# Load entity config
$configPaths = @(
    Join-Path $PSScriptRoot ".." "cloud-books-entities.json"
    Join-Path (Resolve-Path "$PSScriptRoot\..") "cloud-books-entities.json"
)
$configPath = $null
foreach ($cp in $configPaths) { if (Test-Path $cp) { $configPath = (Resolve-Path $cp).Path; break } }
if (-not $configPath) { Write-Error "cloud-books-entities.json not found"; exit 1 }

$entitiesConfig = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
$ec = $entitiesConfig.entities[$Entity]
if (-not $ec) { Write-Error "Entity '$Entity' not found in config"; exit 1 }

$OrgId = $ec.org_id

$McAcct = $null
$RbcAcct = $null
foreach ($ccProp in $entitiesConfig.credit_cards.PSObject.Properties) {
    if ($ccProp.Value.entity -eq $Entity) { $McAcct = $ccProp.Value.account_id }
}
foreach ($baProp in $entitiesConfig.bank_accounts.PSObject.Properties) {
    if ($baProp.Value.entity -eq $Entity) { $RbcAcct = $baProp.Value.account_id }
}

$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"
$StateFile = Join-Path (Join-Path $ReceiptsBase $Entity) ".zoho-missing-expenses.json"

# Auth
$awsArgs = @(
    "secretsmanager", "get-secret-value",
    "--secret-id", "Interclaw/FRAD/Provisioning",
    "--profile", $AwsProfile,
    "--region", "ca-central-1",
    "--query", "SecretString",
    "--output", "text"
)
$secretStr = & aws @awsArgs 2>&1
$secret = $secretStr | ConvertFrom-Json
$tokenBody = @{ client_id = $secret.ZOHO_BOOKS_ID; client_secret = $secret.ZOHO_BOOKS_SECRET; refresh_token = $secret.ZOHO_BOOKS_REFRESH; grant_type = "refresh_token" }
$tokenResult = Invoke-ApiCall -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -Domain "Bookkeeper" -Action "zoho:token-exchange" -TimeoutSec 30
$accessToken = $tokenResult.access_token
$headers = @{ Authorization = "Zoho-oauthtoken $accessToken"; Accept = "application/json"; 'Content-Type' = 'application/json' }

# Read manifest
if (-not $ManifestPath) {
    $ManifestPath = Join-Path (Join-Path (Join-Path $ReceiptsBase $Entity) "2026 Receipts") "manifest-enriched.csv"
}
$raw = Get-Content $ManifestPath -Raw -Encoding UTF8
if ($raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
$allReceipts = $raw | ConvertFrom-Csv | Where-Object { $_.enrichment_status -eq 'enriched' -and [double]($_.amount -replace '[^0-9.-]', '') -gt 0 }

# Fetch all Zoho expenses to find which are missing
$allExpenses = @(); $p=1
do { $r = Invoke-ApiCall -Uri "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId&page=$p&per_page=200" -Headers $headers -Domain "Bookkeeper" -Action "zoho:expenses:list" -TimeoutSec 30; $allExpenses+=$r.expenses; $p++ } while($r.page_context.has_more_page)

# Find unmatched receipts
$unmatched = @()
foreach ($r in $allReceipts) {
    $amt = "{0:F2}" -f [double]($r.amount -replace '[^0-9.-]', '')
    $found = $false
    foreach ($exp in $allExpenses) {
        $eamt = "{0:F2}" -f [double]$exp.total
        if ($eamt -eq $amt) {
            $ed = try { (Get-Date $exp.date).ToString('yyyy-MM-dd') } catch { '' }
            $md = try { (Get-Date $r.date).ToString('yyyy-MM-dd') } catch { '' }
            if ($ed -eq $md -or [math]::Abs(((Get-Date $ed) - (Get-Date $md)).TotalDays) -le 1) { $found = $true; break }
        }
    }
    if (-not $found) { $unmatched += $r }
}

"=== $($unmatched.Count) unmatched receipts requiring expense creation ==="

# Load state
$created = @{}
if (Test-Path $StateFile) { $state = Get-Content $StateFile | ConvertFrom-Json; foreach ($h in $state.created_hashes) { $created[$h] = $true } }

$manifestDir = Split-Path $ManifestPath -Parent
$receiptDir = $manifestDir
$stats = @{ Created = 0; Receipts = 0; Skipped = 0; Failed = 0 }

foreach ($r in $unmatched) {
    $hash = if ($r.hash) { $r.hash } else { $r.filename }
    $amount = [double]($r.amount -replace '[^0-9.-]', '')
    $imagePath = Join-Path $receiptDir $r.filename
    if (-not (Test-Path $imagePath)) { Write-Host "  SKIP (no file): $($r.filename)" -ForegroundColor Yellow; $stats.Skipped++; continue }
    if ($created.ContainsKey($hash)) { Write-Host "  SKIP (done): $($r.filename)" -ForegroundColor Gray; $stats.Skipped++; continue }

    Write-Host "  Creating: $($r.filename) ($($r.vendor), $amount)" -ForegroundColor Gray

    $paidThrough = $McAcct

    $expBody = @{
        account_id = $r.suggested_account_id
        paid_through_account_id = $paidThrough
        amount = $amount
        date = $r.date
        description = if ($r.notes) { $r.notes } else { "$($r.vendor) - $amount" }
        is_billable = $false
    } | ConvertTo-Json -Compress

    try {
        $createResult = Invoke-ApiCall -Uri "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId" -Method POST -Headers $headers -Body $expBody -Domain "Bookkeeper" -Action "zoho:expenses:create" -TimeoutSec 30
        if ($createResult.code -ne 0) { throw $createResult.message }
        $expenseId = $createResult.expense.expense_id
        Write-Host "    Created expense: $expenseId" -ForegroundColor Green
        $stats.Created++
    } catch { Write-Host "    FAIL create: $_" -ForegroundColor Red; $stats.Failed++; continue }

    Start-Sleep -Milliseconds 600

    try {
        $uploadUrl = "https://www.zohoapis.com/books/v3/expenses/$expenseId/receipt?organization_id=$OrgId"
        $curlResult = curl.exe -s -X POST -H "Authorization: Zoho-oauthtoken $accessToken" -F "receipt=@$imagePath" $uploadUrl 2>&1
        $uploadOk = ($curlParsed -and $curlParsed.code -eq 0)
        if ($uploadOk) {
            Write-Host "    [OK] Receipt uploaded" -ForegroundColor Green
            $stats.Receipts++
        } else { Write-Host "    [WARN] Receipt upload: $curlResult" -ForegroundColor Yellow }
        $agentId = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
        Write-AuditEntry -Entry @{
            ts = (Get-Date -Format 'o')
            agent = $agentId
            domain = "Bookkeeper"
            action = "zoho:expense:upload-attachment"
            req = @{ method = "POST"; url = $uploadUrl }
            res = @{ status = if ($uploadOk) { 200 } else { 0 }; upload_ok = $uploadOk }
        } -Domain "Bookkeeper"
    } catch { Write-Host "    [FAIL] Upload: $_" -ForegroundColor Yellow }

    Start-Sleep -Milliseconds 600

    $created[$hash] = $true
    @{ created_count = $stats.Created; receipt_count = $stats.Receipts; created_hashes = @($created.Keys) } | ConvertTo-Json | Out-File $StateFile -Force
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "  Created:  $($stats.Created)" -ForegroundColor Green
Write-Host "  Receipts: $($stats.Receipts)" -ForegroundColor Green
Write-Host "  Skipped:  $($stats.Skipped)" -ForegroundColor Yellow
Write-Host "  Failed:   $($stats.Failed)" -ForegroundColor $(if ($stats.Failed -eq 0) { "Green" } else { "Red" })
