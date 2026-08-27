<#
.SYNOPSIS
    Consolidated Zoho Books operations — upload expenses, upload receipts, categorize, reconcile.
.DESCRIPTION
    Single flag-driven replacement for Invoke-ZohoUpload.ps1 and Invoke-ZohoReceiptUpload.ps1.
    Handles rate limiting, token refresh, BOM stripping, resumability, and vendor-to-account mapping.
    Credentials resolved from AWS SM by default; can be passed explicitly.
.PARAMETER Action
    Operation to perform: Upload (expenses+receipts from enriched manifest) or ReceiptUpload (receipt-focused with vendor mapping).
.PARAMETER Entity
    "intersite-consulting" or "room-rentals"
.PARAMETER ClientId
    Zoho OAuth client ID. Default: resolved from AWS SM.
.PARAMETER ClientSecret
    Zoho OAuth client secret. Default: resolved from AWS SM.
.PARAMETER RefreshToken
    Zoho OAuth refresh token. Default: resolved from AWS SM.
.PARAMETER OrganizationId
    Zoho Books organization ID. Overrides entity default.
.PARAMETER ManifestPath
    Path to manifest CSV. Default: resolved from entity config.
.PARAMETER ReceiptsBase
    Base directory with entity-named folders. Default: ~/intersite-docs/Taxes and Bookkeeping.
.PARAMETER AwsProfile
    AWS CLI profile for SM lookup. Default: intersite.
.PARAMETER DryRun
    Print what would be done without making API calls.
.PARAMETER Resume
    Skip receipts already imported (uses hash state file; Upload only).
.PARAMETER Force
    Re-import even if previously imported (Upload only).
.EXAMPLE
    .\Invoke-Zoho.ps1 -Action Upload -Entity intersite-consulting
    Upload all intersite-consulting receipts from enriched manifest.
.EXAMPLE
    .\Invoke-Zoho.ps1 -Action ReceiptUpload -Entity room-rentals -DryRun
    Dry-run receipt upload for room-rentals with vendor mapping.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Upload", "ReceiptUpload", "GetTransfers", "NewTransfer")]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [string]$ClientId,
    [string]$ClientSecret,
    [string]$RefreshToken,
    [string]$OrganizationId,
    [string]$ManifestPath,
    [string]$AwsProfile = "intersite",
    [string]$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$Force,

    # Transfer action parameters
    [string]$FromAccount,
    [string]$ToAccount,
    [decimal]$Amount,
    [string]$Date,
    [string]$Description
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "shared" "Get-EntityConfig.ps1")

$script:tokenExpiry = [datetime]::MinValue

# --- Helper: Get valid access token with expiry check ---
function Get-ValidAccessToken {
    if ((Get-Date) -lt $script:tokenExpiry) {
        $timeToExpiry = ($script:tokenExpiry - (Get-Date)).TotalSeconds
        if ($timeToExpiry -gt 60) {
            return $script:headers
        }
        Write-Host "Token within 60 seconds of expiry — refreshing preemptively..." -ForegroundColor Yellow
    } else {
        Write-Host "Token expired or not yet obtained — refreshing..." -ForegroundColor Yellow
    }
    $newToken = Get-ZohoAccessToken
    $script:headers = @{ Authorization = "Zoho-oauthtoken $newToken"; Accept = "application/json" }
    return $script:headers
}

# --- Helper: Zoho API call with token expiry check and 401 retry ---
function Invoke-ZohoApiCall {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$ContentType = "application/json",
        [string]$Domain = "Bookkeeper",
        [string]$Action = "zoho:api-call",
        [int]$TimeoutSec = 60,
        [int]$MaxRetries = 1
    )
    $retryCount = 0
    $rateLimitRetryCount = 0
    $maxRateRetries = 3
    do {
        $currentHeaders = Get-ValidAccessToken
        try {
            $params = @{
                Uri = $Uri
                Method = $Method
                Headers = $currentHeaders
                Domain = $Domain
                Action = $Action
                TimeoutSec = $TimeoutSec
            }
            if ($Body) { $params.Body = $Body }
            if ($ContentType) { $params.ContentType = $ContentType }
            $result = Invoke-ApiCall @params
            return $result
        } catch {
            $errMsg = $_.Exception.Message
            $handled = $false
            if ($errMsg -match '429|TooManyRequests|rate limit|too many requests' -and $rateLimitRetryCount -lt $maxRateRetries) {
                $delay = [math]::Pow(2, $rateLimitRetryCount) * 1000
                Write-Host "  Rate limited (429) — retry $($rateLimitRetryCount + 1)/$maxRateRetries after ${delay}ms" -ForegroundColor Yellow
                Start-Sleep -Milliseconds $delay
                $rateLimitRetryCount++
                $handled = $true
            }
            if ($errMsg -match '401|Unauthorized|invalid_token' -and $retryCount -lt $MaxRetries) {
                Write-Host "  401 detected — forcing token refresh (attempt $($retryCount + 1))" -ForegroundColor Yellow
                $script:tokenExpiry = [datetime]::MinValue
                $retryCount++
                $handled = $true
            }
            if (-not $handled) { throw }
        }
    } while ($retryCount -lt $MaxRetries -and $rateLimitRetryCount -lt $maxRateRetries)
}

# --- Helper: Get OAuth access token ---
function Get-ZohoAccessToken {
    Write-Host "Getting access token..." -ForegroundColor Cyan
    $body = @{
        client_id     = $script:ClientId
        client_secret = $script:ClientSecret
        refresh_token = $script:RefreshToken
        grant_type    = "refresh_token"
    }
    $tokenResult = Invoke-ApiCall -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $body -ContentType "application/x-www-form-urlencoded" -Domain "Bookkeeper" -Action "zoho:token-exchange" -TimeoutSec 30
    $accessToken = $tokenResult.access_token
    $expiresIn = if ($tokenResult.expires_in) { $tokenResult.expires_in } else { 3600 }
    $script:tokenExpiry = (Get-Date).AddSeconds([math]::Max($expiresIn - 300, 60))
    Write-Host "Token OK (expires $($script:tokenExpiry.ToString('HH:mm:ss')))" -ForegroundColor Green
    return $accessToken
}

$cfg = Get-EntityConfig -Entity $Entity
$entityCfg = $cfg.Entity
$entitiesConfig = $cfg.Config
$orgId = if ($OrganizationId) { $OrganizationId } else { $entityCfg.org_id }

if ($ClientId) { $script:ZohoClientId = $ClientId }
if ($ClientSecret) { $script:ZohoClientSecret = $ClientSecret }
if ($RefreshToken) { $script:ZohoRefreshToken = $RefreshToken }
Resolve-ZohoCredentials -AwsProfile $AwsProfile
$script:headers = $null
$accessToken = Get-ZohoAccessToken
$script:headers = @{ Authorization = "Zoho-oauthtoken $accessToken"; Accept = "application/json" }

switch ($Action) {
    "Upload" {
        # --- Upload action (formerly Invoke-ZohoUpload.ps1) ---
        $stateDir = Join-Path $ReceiptsBase $Entity
        $null = New-Item -ItemType Directory -Path $stateDir -Force

        $stateFile = Join-Path $stateDir "Process-ReceiptsState-$Entity.json"
        $importedHashes = @{}
        if ((Test-Path $stateFile) -and $Resume -and -not $Force) {
            $state = Get-Content $stateFile | ConvertFrom-Json
            foreach ($h in $state.imported_hashes) { $importedHashes[$h] = $true }
            Write-Host "[RESUME] $($importedHashes.Count) receipts already imported" -ForegroundColor Yellow
        }

        $receiptDir = Join-Path $ReceiptsBase $Entity $entityCfg.receipt_dir
        $candidates = @()
        $manifestPath = if ($ManifestPath) { $ManifestPath } else {
            $candidates = @(
                Join-Path $receiptDir "Complete" "manifest-enriched.csv"
                Join-Path $receiptDir "Complete" "manifest.csv"
                Join-Path $receiptDir "manifest-enriched.csv"
                Join-Path $receiptDir "manifest.csv"
            )
            ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
        }
        if (-not $manifestPath -or -not (Test-Path $manifestPath)) {
            $searched = if ($candidates.Count -gt 0) { $candidates -join '; ' } else { $ManifestPath }
            Write-Error "Manifest CSV not found. Searched: $searched"; exit 1
        }
        Write-Host "Reading: $manifestPath" -ForegroundColor Cyan
        $raw = Get-Content $manifestPath -Raw -Encoding UTF8
        $bom = [char]0xFEFF
        if ($raw[0] -eq $bom) { $raw = $raw.Substring(1) }
        $receipts = $raw | ConvertFrom-Csv
        Write-Host "Receipts: $($receipts.Count)" -ForegroundColor Gray

        $results = [System.Collections.Generic.List[object]]::new()
        $stats = @{ Total = 0; Skipped = 0; Uploaded = 0; Failed = 0 }
        $completeDir = Split-Path $manifestPath -Parent

        foreach ($r in $receipts) {
            $stats.Total++
            $hash = if ($r.hash) { $r.hash } else { $r.filename }

            if ($importedHashes.ContainsKey($hash) -and -not $Force) {
                Write-Host "  SKIP (imported): $($r.filename)" -ForegroundColor Gray
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "skipped"; Reason = "Already imported" })
                continue
            }

            if ($r.enrichment_status -eq "skipped") {
                $reason = if ($r.skip_reason) { $r.skip_reason } else { "enrichment skipped" }
                Write-Host "  SKIP ($reason): $($r.filename)" -ForegroundColor Gray
                $stats.Skipped++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "skipped"; Reason = $reason })
                continue
            }

            $amount = [double]::TryParse(($r.amount -replace '[^0-9.-]', ''), [ref]$null) ? [double]($r.amount -replace '[^0-9.-]', '') : 0
            if ($amount -le 0) {
                Write-Host "  SKIP (amount<=0): $($r.filename)" -ForegroundColor Gray
                $stats.Skipped++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "skipped"; Reason = "Amount <= 0" })
                continue
            }

            $vendor = if ($r.vendor) { $r.vendor } else { "Unknown Vendor" }
            if ($r.date -notmatch '^\d{4}-\d{2}-\d{2}$') {
                Write-Error "  SKIP (malformed date '$($r.date)'): $($r.filename)" -ErrorAction Continue
                $stats.Skipped++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "skipped"; Reason = "Malformed date: $($r.date)" })
                continue
            }
            $date = $r.date
            $description = if ($r.notes) { $r.notes } else { "$vendor — $amount" }
            $accountId = if ($r.suggested_account_id) { $r.suggested_account_id } else { "151803000000000460" }

            $imagePath = Join-Path $completeDir $r.filename
            if (-not (Test-Path $imagePath)) {
                Write-Host "  SKIP (file not found): $imagePath" -ForegroundColor Yellow
                $stats.Skipped++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "skipped"; Reason = "File not found" })
                continue
            }

            if ($DryRun) {
                Write-Host "  [DRY RUN] $($r.filename) → $vendor $amount account=$accountId" -ForegroundColor Magenta
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "dry-run" })
                continue
            }

            Write-Host "  Creating expense: $($r.filename) ($vendor, $amount)" -ForegroundColor Gray
            $expenseBody = @{
                account_id   = $accountId
                amount       = [double]$amount
                date         = $date
                description  = $description
                is_billable  = $false
            } | ConvertTo-Json -Compress

            try {
                $createResult = Invoke-ZohoApiCall -Uri "https://www.zohoapis.com/books/v3/expenses?organization_id=$orgId" `
                    -Method POST -Body $expenseBody -Domain "Bookkeeper" -Action "zoho:expenses:create" -TimeoutSec 30
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Host "    [Upload] FAIL (create expense): $errMsg" -ForegroundColor Red
                $stats.Failed++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "failed"; Reason = $errMsg })
                continue
            }

            if ($createResult.code -ne 0) {
                Write-Host "    FAIL (create): code=$($createResult.code) $($createResult.message)" -ForegroundColor Red
                $stats.Failed++
                $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "failed"; Reason = $createResult.message })
                continue
            }

            $expenseId = $createResult.expense.expense_id
            Write-Host "    Created expense: $expenseId" -ForegroundColor Green

            $uploadOk = $false
            try {
                $tempDir = "$env:TEMP\zoho_upload_$(Get-Random)"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                $uploadUrl = "https://www.zohoapis.com/books/v3/expenses/$expenseId/receipt?organization_id=$orgId"
                if (-not (Test-Path -LiteralPath $imagePath)) { throw "Receipt image not found: $imagePath" }
                $form = @{ receipt = Get-Item -LiteralPath $imagePath }

                $uploadRetries = 0
                $uploadRateRetries = 0
                $uploadEx = $null
                do {
                    try {
                        $currentHeaders = Get-ValidAccessToken
                        $uploadResult = Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $currentHeaders -Form $form
                        if ($uploadResult -and $uploadResult.code -eq 0) {
                            $uploadOk = $true
                        } else {
                            Write-Host "    WARN: Receipt upload may have failed" -ForegroundColor Yellow
                        }
                        $uploadEx = $null
                        break
                    } catch {
                        $uploadEx = $_.Exception.Message
                        if ($uploadEx -match '429|TooManyRequests|rate limit|too many requests' -and $uploadRateRetries -lt 3) {
                            $delay = [math]::Pow(2, $uploadRateRetries) * 1000
                            Write-Host "    Rate limited (429) — retry receipt upload $($uploadRateRetries + 1)/3 after ${delay}ms" -ForegroundColor Yellow
                            Start-Sleep -Milliseconds $delay
                            $uploadRateRetries++
                            continue
                        }
                        if ($uploadEx -match '401|Unauthorized|invalid_token' -and $uploadRetries -lt 1) {
                            Write-Host "    401 on receipt upload — forcing token refresh" -ForegroundColor Yellow
                            $script:tokenExpiry = [datetime]::MinValue
                            $uploadRetries++
                            continue
                        }
                        Write-Host "    Receipt upload error: $uploadEx" -ForegroundColor Yellow
                        break
                    }
                } while ($uploadRetries -le 1 -or $uploadRateRetries -le 3)
            }
            finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $agentId = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
            Write-AuditEntry -Entry @{
                ts = (Get-Date -Format 'o')
                agent = $agentId
                domain = "Bookkeeper"
                action = "zoho:expense:upload-attachment"
                req = @{ method = "POST"; url = $uploadUrl }
                res = @{ status = if ($uploadOk) { 200 } else { 0 }; upload_ok = $uploadOk }
            } -Domain "Bookkeeper"

            $statusMsg = if ($uploadOk) { "OK" } else { "created (receipt upload check needed)" }
            Write-Host "    $statusMsg — expenseId=$expenseId" -ForegroundColor $(if ($uploadOk) { "Green" } else { "Yellow" })
            $stats.Uploaded++
            $results.Add([pscustomobject]@{ Filename = $r.filename; Status = "uploaded"; ExpenseId = $expenseId; ReceiptUploaded = $uploadOk })

            $importedHashes[$hash] = $true
            $state = @{
                imported_count  = $stats.Uploaded
                imported_hashes = @($importedHashes.Keys)
                entity          = $Entity
                completed       = $false
            }
            $state | ConvertTo-Json | Out-File $stateFile -Force

            Start-Sleep -Milliseconds 500
        }

        $entityDisplay = if ($entityCfg.display_name) { $entityCfg.display_name } else { $Entity }
        Write-Host "`n=== Summary: $entityDisplay ===" -ForegroundColor Cyan
        Write-Host "  Total:    $($stats.Total)" -ForegroundColor White
        Write-Host "  Uploaded: $($stats.Uploaded)" -ForegroundColor Green
        Write-Host "  Skipped:  $($stats.Skipped)" -ForegroundColor Yellow
        Write-Host "  Failed:   $($stats.Failed)" -ForegroundColor $(if ($stats.Failed -eq 0) { "Green" } else { "Red" })

        if (-not $DryRun) {
            $state.completed = $stats.Failed -eq 0
            $state | ConvertTo-Json | Out-File $stateFile -Force
        }

        Write-Host "Done." -ForegroundColor Cyan
    }

    "ReceiptUpload" {
        # --- ReceiptUpload action (formerly Invoke-ZohoReceiptUpload.ps1) ---
        Write-Host "=== ReceiptUpload: $Entity ===" -ForegroundColor Cyan
        $AccountMap = if ($entityCfg.vendor_account_map) { $entityCfg.vendor_account_map } else { @{} }
        $RbcVendors = if ($entityCfg.rbc_vendors) { $entityCfg.rbc_vendors } else { @() }

        $McAccountId = $null
        $RbcAccountId = $null
        foreach ($ccProp in $entitiesConfig.credit_cards.PSObject.Properties) {
            if ($ccProp.Value.entity -eq $Entity) { $McAccountId = $ccProp.Value.account_id }
        }
        foreach ($baProp in $entitiesConfig.bank_accounts.PSObject.Properties) {
            if ($baProp.Value.entity -eq $Entity) { $RbcAccountId = $baProp.Value.account_id }
        }

        if (-not $McAccountId -or -not $RbcAccountId) {
            Write-Error "Could not resolve MC/RBC account IDs from cloud-books-entities.json for entity '$Entity'"
            exit 1
        }

        if (-not $ManifestPath) {
            $receiptDir = Join-Path $ReceiptsBase $Entity $entityCfg.receipt_dir
            $completeDir = Join-Path $receiptDir "Complete"
            $ManifestPath = Join-Path $completeDir "manifest.csv"
        }
        $receipts = Import-Csv $ManifestPath
        $completeDir = Split-Path $ManifestPath -Parent
        Write-Host "`n=== Uploading $($receipts.Count) receipts from $ManifestPath ===" -ForegroundColor Cyan

        $results = @()
        $uploaded = 0
        $errors = 0

        foreach ($receipt in $receipts) {
            $filename = $receipt.filename
            $vendor = $receipt.vendor
            $amount = $receipt.amount
            $date = $receipt.date
            $filepath = Join-Path $completeDir $filename

            if (-not (Test-Path $filepath)) {
                Write-Host "  SKIP (file not found): $filename" -ForegroundColor Yellow
                $results += @{filename=$filename; status='skip'; reason='file_not_found'}
                continue
            }

            $accountId = $null
            foreach ($key in $AccountMap.Keys) {
                if ($vendor -match [regex]::Escape($key) -or $key -match [regex]::Escape($vendor)) {
                    $accountId = $AccountMap[$key]
                    break
                }
            }
            if (-not $accountId) {
                Write-Host "  SKIP (no account mapping): $vendor - $filename" -ForegroundColor Yellow
                $results += @{filename=$filename; status='skip'; reason='no_account_mapping'; vendor=$vendor}
                continue
            }

            $paidThrough = $McAccountId
            foreach ($rbc in $RbcVendors) {
                if ($vendor -match $rbc) { $paidThrough = $RbcAccountId; break }
            }

            $notes = if ($receipt.notes) { $receipt.notes } else { "$vendor — $amount" }

            Write-Host "  Uploading: $filename" -ForegroundColor Gray
            Write-Host "    vendor=$vendor account=$accountId amount=$amount date=$date paid_through=$paidThrough"

            if ($DryRun) {
                Write-Host "    [DRY RUN] Would create expense" -ForegroundColor Magenta
                $results += @{filename=$filename; status='dry-run'}
                continue
            }

            try {
                $expenseBody = @{
                    account_id = $accountId
                    amount = [double]$amount
                    date = $date
                    description = $notes
                    paid_through_account_id = $paidThrough
                    is_billable = $false
                } | ConvertTo-Json -Compress

                $createUri = "https://www.zohoapis.com/books/v3/expenses?organization_id=$orgId"
                $createResp = Invoke-ZohoApiCall -Uri $createUri -Method POST -Body $expenseBody -Domain "Bookkeeper" -Action "zoho:expenses:create" -TimeoutSec 30

                if ($createResp.code -ne 0) {
                    throw "Create expense failed: code=$($createResp.code) msg=$($createResp.message)"
                }

                $expenseId = $createResp.expense.expense_id
                Write-Host "    Created expense $expenseId" -ForegroundColor Green

                if (-not (Test-Path -LiteralPath $filepath)) { throw "Receipt image not found: $filepath" }
                $form = @{ receipt = Get-Item -LiteralPath $filepath }
                $uploadUri = "https://www.zohoapis.com/books/v3/expenses/$expenseId/receipt?organization_id=$orgId"

                $uploadOk = $false
                $uploadRetries = 0
                $uploadRateRetries = 0
                do {
                    try {
                        $currentHeaders = Get-ValidAccessToken
                        $uploadResp = Invoke-RestMethod -Uri $uploadUri -Method POST -Headers $currentHeaders -Form $form
                        $uploadOk = ($uploadResp.code -eq 0)
                        break
                    } catch {
                        $uploadEx = $_.Exception.Message
                        if ($uploadEx -match '429|TooManyRequests|rate limit|too many requests' -and $uploadRateRetries -lt 3) {
                            $delay = [math]::Pow(2, $uploadRateRetries) * 1000
                            Write-Host "    Rate limited (429) — retry receipt upload $($uploadRateRetries + 1)/3 after ${delay}ms" -ForegroundColor Yellow
                            Start-Sleep -Milliseconds $delay
                            $uploadRateRetries++
                            continue
                        }
                        if ($uploadEx -match '401|Unauthorized|invalid_token' -and $uploadRetries -lt 1) {
                            Write-Host "    401 on receipt upload — forcing token refresh" -ForegroundColor Yellow
                            $script:tokenExpiry = [datetime]::MinValue
                            $uploadRetries++
                            continue
                        }
                        Write-Host "    Receipt upload error: $uploadEx" -ForegroundColor Yellow
                        break
                    }
                } while ($uploadRetries -le 1 -or $uploadRateRetries -le 3)
                if ($uploadOk) {
                    Write-Host "    [OK] Receipt uploaded" -ForegroundColor Green
                    $uploaded++
                    $results += @{filename=$filename; status='ok'; expense_id=$expenseId}
                } else {
                    Write-Host "    [WARN] Upload returned code=$($uploadResp.code)" -ForegroundColor Yellow
                    $results += @{filename=$filename; status='upload_warn'; expense_id=$expenseId; code=$uploadResp.code}
                }

                $agentId = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
                $auditHeaders = Get-ValidAccessToken
                Write-AuditEntry -Entry @{
                    ts = (Get-Date -Format 'o')
                    agent = $agentId
                    domain = "Bookkeeper"
                    action = "zoho:expense:upload-attachment"
                    req = @{ method = "POST"; url = $uploadUri }
                    res = @{ status = if ($uploadOk) { 200 } else { 0 }; code = $uploadResp.code }
                } -Domain "Bookkeeper"

                Start-Sleep -Milliseconds 500
            }
            catch {
                Write-Host "    [ReceiptUpload] FAIL: $_" -ForegroundColor Red
                $errors++
                $results += @{filename=$filename; status='error'; error=$_.Exception.Message}
            }
        }

        Write-Host "`n=== Upload Complete ===" -ForegroundColor Cyan
        Write-Host "Total receipts: $($receipts.Count)"
        Write-Host "Uploaded: $uploaded"
        Write-Host "Errors: $errors"
        Write-Host "Skipped: $($receipts.Count - $uploaded - $errors)"

        $reportPath = Join-Path $completeDir "upload-report.json"
        $results | ConvertTo-Json -Depth 3 | Set-Content $reportPath -Encoding UTF8
        Write-Host "Report saved: $reportPath"
    }

    "GetTransfers" {
        Write-Host "=== Getting transfers ===" -ForegroundColor Cyan
        $orgName = if ($Entity -eq 'room-rentals') { 'RoomRentals' } else { 'Intersite' }
        $result = Get-ZohoTransfers -OrgName $orgName
        if ($result.Success) {
            Write-Host "Found $($result.Transfers.Count) transfers" -ForegroundColor Green
            $result.Transfers | Format-Table -AutoSize
        } else {
            Write-Error "Failed to get transfers: $($result.Message)"
        }
    }

    "NewTransfer" {
        Write-Host "=== Creating transfer ===" -ForegroundColor Cyan
        $orgName = if ($Entity -eq 'room-rentals') { 'RoomRentals' } else { 'Intersite' }
        $result = New-ZohoTransfer -FromAccountId $FromAccount -ToAccountId $ToAccount -Amount $Amount -Date $Date -OrgName $orgName -Description $Description
        if ($result.Success) {
            Write-Host "Transfer created: $($result.TransferId)" -ForegroundColor Green
            $result | Format-List
        } else {
            Write-Error "Failed to create transfer: $($result.Message)"
        }
    }
}
