<#
.SYNOPSIS
    PRP Remediation: Create matched expenses for bank transactions missing them.
.DESCRIPTION
    Reads evidence from Step 1 (SidecarVerify) containing missing sidecar
    transactions. For each, finds the matching Zoho bank transaction, creates
    a categorized expense linked via transaction_id, and sweeps the CR+DR
    duplicate that Zoho creates as a side effect.
.PARAMETER Evidence
    Evidence fragment from the detect phase containing failure details.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Account slug name.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER Token
    Zoho OAuth access token (optional — acquired fresh if needed).
.PARAMETER Headers
    HTTP headers for API calls (optional).
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpRemediate-MissingExpenses.ps1 -Evidence $fragment -OrgName "room-rentals" -AccountName "RBC-FRA"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    $Evidence,

    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [string]$AccountName,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [ValidateSet('Host', 'Container')]
    [string]$Platform = 'Host'
)

function Test-ContainerReady {
    $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
    if (-not $cid) { Write-Verbose "Container FRAD_is-bookkeeping not running"; return $false }
    $status = docker inspect $cid --format "{{.State.Status}}" 2>$null
    if ($status -ne 'running') { Write-Verbose "Container status: $status"; return $false }
    $startedAt = docker inspect $cid --format "{{.State.StartedAt}}" 2>$null
    if (-not $startedAt) { return $false }
    try {
        $startTime = [datetime]::Parse($startedAt.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $uptime = [datetime]::UtcNow - $startTime
        if ($uptime.TotalMinutes -le 2) {
            Write-Verbose "Container uptime $([math]::Round($uptime.TotalMinutes,1)) min — need > 2 min"
            return $false
        }
        return $true
    } catch {
        Write-Verbose "Could not parse StartedAt: $startedAt"
        return $false
    }
}

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$handled = 0
$failed = 0
$skipped = 0

# Graceful fallback: if Platform=Container but container not ready, degrade to Host
if ($Platform -eq 'Container' -and -not (Test-ContainerReady)) {
    $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
    $reason = if (-not $cid) { "Container FRAD_is-bookkeeping is not running" } else {
        $startedAt = docker inspect $cid --format "{{.State.StartedAt}}" 2>$null
        if ($startedAt) {
            try {
                $startTime = [datetime]::Parse($startedAt.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
                $uptime = [datetime]::UtcNow - $startTime
                "Container uptime $([math]::Round($uptime.TotalMinutes,1)) min (need > 2 min)"
            } catch { "Container StartAt parse failed: $startedAt" }
        } else { "Container status could not be determined" }
    }
    Write-Warning "[PRP REMEDIATE-MISSING] -Platform Container was requested but $reason — falling back to Host mode"
    $Platform = 'Host'
}

$script:RemFleetApiToken = $null
function Get-RemFleetApiToken {
    if ($script:RemFleetApiToken) { return $script:RemFleetApiToken }
    try {
        $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
        if ($cid) { $script:RemFleetApiToken = docker exec $cid cat /run/secrets/fleet_api_token 2>$null }
    } catch {}
    return $script:RemFleetApiToken
}

function Invoke-ContainerRemediateProxy {
    param([string]$Url, [string]$Method = 'GET', [object]$Body = $null)
    $encoded = [System.Web.HttpUtility]::UrlEncode($Url)
    $proxyUri = "http://localhost:21008/zoho/proxy?url=$encoded"
    $fleetToken = Get-RemFleetApiToken
    $headers = @{}
    if ($fleetToken) { $headers["Authorization"] = "Bearer $fleetToken" }
    try {
        if ($Method -eq 'GET') {
            return Invoke-RestMethod -Uri $proxyUri -Method GET -Headers $headers -ErrorAction Stop
        } else {
            $jsonBody = $Body | ConvertTo-Json -Compress
            $headers["Content-Type"] = "application/json"
            return Invoke-RestMethod -Uri $proxyUri -Method $Method -Headers $headers -Body $jsonBody -ContentType "application/json" -ErrorAction Stop
        }
    } catch { throw }
}

function Invoke-ZohoRemediateApi {
    param([string]$Url, [string]$Method = 'GET', [object]$Body = $null)
    if ($Platform -eq 'Container') {
        return Invoke-ContainerRemediateProxy -Url $Url -Method $Method -Body $Body
    }
    if ($Method -eq 'GET') {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -ErrorAction Stop
    }
    $jsonBody = $Body | ConvertTo-Json -Compress
    return Invoke-RestMethod -Uri $Url -Method $Method -Headers $Headers -Body $jsonBody -ContentType "application/json" -ErrorAction Stop
}

Write-Information "[PRP REMEDIATE-MISSING] Starting missing expense remediation for $AccountName ($OrgName) — Platform=$Platform" -Tags PRP

# Acquire token if not provided
if (-not $Token) {
    if ($Platform -eq 'Container') {
        try {
            $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
            if (-not $cid) { throw "Container FRAD_is-bookkeeping not running" }
            $fleetTok = (docker exec $cid cat /run/secrets/fleet_api_token 2>$null | ForEach-Object { $_.Trim() })
            $tokResponse = docker exec $cid curl -s -H "Authorization: Bearer $fleetTok" http://localhost:21008/zoho/token 2>$null
            if ($tokResponse) {
                $tokJson = $tokResponse | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($tokJson -and $tokJson.access_token) {
                    $Token = $tokJson.access_token
                    $Headers = @{ Authorization = "Zoho-oauthtoken $Token"; "Content-Type" = "application/json" }
                }
            }
            if (-not $Token) {
                Write-Warning "[PRP REMEDIATE-MISSING] Container token endpoint returned no access_token"
            }
        } catch {
            Write-Warning "[PRP REMEDIATE-MISSING] Container token fetch failed: $_"
        }
    } else {
        . (Join-Path $scriptDir "Invoke-PrpStep0-TokenAcquisition.ps1")
        $tokResult = & (Join-Path $scriptDir "Invoke-PrpStep0-TokenAcquisition.ps1") -OrgId $OrgId -OrgName $OrgName
        if ($tokResult -and $tokResult.Token) {
            $Token = $tokResult.Token
            $Headers = @{ Authorization = "Zoho-oauthtoken $Token"; "Content-Type" = "application/json" }
        }
    }
}

if (-not $Token) {
    Write-Warning "[PRP REMEDIATE-MISSING] No Zoho token available — cannot proceed"
    return [PSCustomObject]@{ Passed = $false; Details = "No Zoho token"; Handled = 0; Failed = 0 }
}

# Load categorization rules
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
$catRulesPath = Join-Path (Split-Path -Parent $scriptDir) "..\..\..\Skills\Bookkeeping\tx-categorization\categorization-rules.json"
$catRules = @()
if (Test-Path $catRulesPath) {
    $catRules = Get-Content $catRulesPath -Raw | ConvertFrom-Json
}

# Extract missing transactions from evidence — check both data and detail
$missingTxns = @()
if ($Evidence.UnmatchedTxns) {
    $missingTxns = @($Evidence.UnmatchedTxns)
} elseif ($Evidence.details -and $Evidence.details -match '(\d+) transaction\(s\) not in TAS') {
    $matches = [regex]::Match($Evidence.details, '(\d+) transaction\(s\) not in TAS')
    $count = if ($matches.Success) { [int]$matches.Groups[1].Value } else { 0 }
    Write-Information "[PRP REMEDIATE-MISSING] Evidence indicates $count missing transaction(s) but no UnmatchedTxns array — attempting sidecar re-scan" -Tags PRP
}

Write-Information "[PRP REMEDIATE-MISSING] Found $($missingTxns.Count) missing transaction(s)" -Tags PRP

if ($WhatIfPreference) {
    foreach ($txn in $missingTxns) {
        $dateStr = if ($txn.date -is [datetime]) { $txn.date.ToString('yyyy-MM-dd') } else { $txn.date }
        Write-Information "[PRP REMEDIATE-MISSING] WhatIf: would create expense for $dateStr $($txn.amount) ($($txn.payee))" -Tags PRP
    }
    Write-Information "[PRP REMEDIATE-MISSING] WhatIf: $($missingTxns.Count) expense(s) would be created" -Tags PRP
    return [PSCustomObject]@{ Passed = $true; Details = "WhatIf: $($missingTxns.Count) expense(s) would be created"; Handled = 0; Failed = 0 }
}

# Process each missing transaction
foreach ($txn in $missingTxns) {
    $dateStr = if ($txn.date -is [datetime]) { $txn.date.ToString('yyyy-MM-dd') } else { $txn.date }
    $amount = [math]::Abs([double]($txn.amount))
    $payee = if ($txn.payee) { $txn.payee } else { $txn.description }

    try {
        # Step 1: Find matching Zoho bank transaction
        $searchUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$AccountId&organization_id=$OrgId&date=$dateStr"
        $searchResp = Invoke-ZohoRemediateApi -Url $searchUri
        $matchedTxns = @($searchResp.banktransactions | Where-Object {
            [math]::Abs([math]::Abs([double]$_.amount) - $amount) -lt 0.50 -and
            ($_.payee -eq $payee -or $_.description -eq $payee)
        })

        if ($matchedTxns.Count -eq 0) {
            Write-Warning "[PRP REMEDIATE-MISSING] No Zoho bank transaction found for $dateStr $amount $payee — skipping"
            $skipped++
            continue
        }

        $zohoTxn = $matchedTxns[0]
        $txnId = $zohoTxn.bank_transaction_id

        # Step 2: Determine expense category from categorization rules
        $categoryId = $null
        if ($catRules -and $catRules.rules) {
            $orgRules = $catRules.rules | Where-Object { $_.entities -contains $OrgName -or -not $_.entities }
            foreach ($rule in $orgRules) {
                $matched = $false
                if ($rule.vendor_keywords) {
                    foreach ($kw in $rule.vendor_keywords) {
                        if ($payee -match [regex]::Escape($kw)) { $matched = $true; break }
                    }
                }
                if ($matched -and $rule.account_id) {
                    $categoryId = $rule.account_id
                    Write-Information "[PRP REMEDIATE-MISSING] Rule match: $($rule.name) → account $categoryId" -Tags PRP
                    break
                }
            }
        }

        # Step 3: Create the matched expense
        $expenseBody = @{
            account_id          = if ($categoryId) { $categoryId } else { $AccountId }
            amount              = $amount
            date                = $dateStr
            description         = $payee
            paid_through_account_id = $AccountId
            transaction_id      = $txnId
        }

        Write-Information "[PRP REMEDIATE-MISSING] Creating expense for $dateStr $amount $payee (linked to bank txn $txnId)" -Tags PRP
        $expenseResp = Invoke-ZohoRemediateApi -Url "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId" -Method Post -Body $expenseBody

        if ($expenseResp.expense -and $expenseResp.expense.expense_id) {
            $newExpenseId = $expenseResp.expense.expense_id
            Write-Information "[PRP REMEDIATE-MISSING] Created expense $newExpenseId for $dateStr $amount" -Tags PRP

            # Step 4: Sweep CR+DR duplicate
            $sweepUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$AccountId&organization_id=$OrgId&date=$dateStr"
            $sweepResp = try { Invoke-ZohoRemediateApi -Url $sweepUri } catch { $null }
            if ($sweepResp -and $sweepResp.banktransactions) {
                $creditTxn = $sweepResp.banktransactions | Where-Object { $_.transaction_type -eq "credit" -and $_.expense_id -eq $newExpenseId }
                if (-not $creditTxn) { $creditTxn = $sweepResp.banktransactions | Where-Object { $_.expense_id -eq $newExpenseId -and $_.credit_amount -gt 0 } }
                $debitTxn = $sweepResp.banktransactions | Where-Object { $_.transaction_type -eq "debit" -and $_.expense_id -eq $newExpenseId }
                if (-not $debitTxn) { $debitTxn = $sweepResp.banktransactions | Where-Object { $_.expense_id -eq $newExpenseId -and ($_.debit_amount -gt 0 -or $_.amount -lt 0) } }

                foreach ($txnToDelete in @($debitTxn)) {
                    if ($txnToDelete -and $txnToDelete.bank_transaction_id) {
                        Write-Information "[PRP REMEDIATE-MISSING] Sweeping DEBIT duplicate: $($txnToDelete.bank_transaction_id)" -Tags PRP
                        try {
                            Invoke-ZohoRemediateApi -Url "https://www.zohoapis.com/books/v3/banktransactions/$($txnToDelete.bank_transaction_id)?organization_id=$OrgId" -Method Delete | Out-Null
                            Write-Information "[PRP REMEDIATE-MISSING]   Deleted DEBIT duplicate $($txnToDelete.bank_transaction_id)" -Tags PRP
                        } catch {
                            Write-Warning "[PRP REMEDIATE-MISSING]   Failed to delete DEBIT $($txnToDelete.bank_transaction_id): $_"
                        }
                    }
                }
            }

            $handled++
        } else {
            Write-Warning "[PRP REMEDIATE-MISSING] Expense creation returned no expense_id for $dateStr $amount"
            $failed++
        }
    } catch {
        Write-Warning ("[PRP REMEDIATE-MISSING] Failed to process {0} {1}: {2}" -f $dateStr, $amount, $_.Exception.Message)
        $failed++
    }

    # Rate limiting pause between transactions
    Start-Sleep -Milliseconds 350
}

$passed = $failed -eq 0
$detail = "Handled $handled, failed $failed, skipped $skipped"
Write-Information "[PRP REMEDIATE-MISSING] Complete — $detail" -Tags PRP

return [PSCustomObject]@{
    Passed   = $passed
    Details  = $detail
    Handled  = $handled
    Failed   = $failed
    Skipped  = $skipped
}
