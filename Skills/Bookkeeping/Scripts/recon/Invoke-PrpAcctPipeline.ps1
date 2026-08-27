<#
.SYNOPSIS
    PRP Per-Account Pipeline — runs the full Pre-Recon Pipeline with stop-on-fail.
.DESCRIPTION
    Calls each Invoke-PrpStep*.ps1 script in sequence, passing state (token,
    headers, org/account IDs) between steps. Stops on first failure unless
    -ContinueOnError is set. Generates a pass/fail summary and saves evidence.
    Use -Phase to start at a named phase (e.g. "Reconciliation" skips DG/RC/TR).
.PARAMETER AccountName
    Account slug name (e.g. "RBC-INTERSITE", "TD-MLM").
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER Phase
    Named phase to start from. Maps to step order via $PhaseStepMap.
    Common values: "FullPipeline" (DG→RC→TR→0→…), "Reconciliation" (Step 6).
.PARAMETER ContinueOnError
    Continue pipeline even if a step fails (diagnostic mode).
.PARAMETER ResumeFrom
    Step number to resume from (skip earlier steps). Overridden by -Phase if both provided.
.PARAMETER WhatIf
    Dry-run: log all steps without executing.
.EXAMPLE
    .\Invoke-PrpAcctPipeline.ps1 -AccountName "RBC-INTERSITE" -OrgName "intersite-consulting" -OrgId "925048093" -AccountId "12345"
.EXAMPLE
    .\Invoke-PrpAcctPipeline.ps1 -AccountName "TD-MLM" -OrgName "room-rentals" -WhatIf
.EXAMPLE
    .\Invoke-PrpAcctPipeline.ps1 -AccountName "TD-MLM" -OrgName "room-rentals" -Phase Reconciliation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$AccountName,

    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId,

    [Parameter()]
    [string]$Phase,

    [switch]$ContinueOnError,

    [string]$ResumeFrom,

    [switch]$Remediate = $true,

    [switch]$DetectOnly,

    [ValidateSet('Host', 'Container')]
    [string]$Platform = 'Host'
)

if ($DetectOnly) { $Remediate = $false }
$script:inDetectPhase = $DetectOnly -or $Remediate

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
$script:platform = $Platform
$stepResults = @()
$pipelineStart = Get-Date

# Graceful fallback: if Platform=Container but container not ready, degrade to Host
if ($script:platform -eq 'Container' -and -not (Test-ContainerReady)) {
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
    Write-Warning "[PRP PIPELINE] -Platform Container was requested but $reason — falling back to Host mode"
    $script:platform = 'Host'
}

# Resolve remediation mode: DetectOnly overrides, default is remediate
if ($DetectOnly) { $doRemediate = $false } else { $doRemediate = $Remediate }
if (-not $PSBoundParameters.ContainsKey('Remediate') -and -not $PSBoundParameters.ContainsKey('DetectOnly')) { $doRemediate = $true }
Write-Information "[PRP PIPELINE] Mode: $(if ($doRemediate) { 'remediate (two-pass)' } else { 'detect-only' })" -Tags PRP

# In detect/remediate mode, force continue-on-error to collect all step results
if ($doRemediate -or $DetectOnly) {
    $ContinueOnError = $true
    Write-Information "[PRP PIPELINE] Forcing ContinueOnError for full detect coverage" -Tags PRP
}

# Module-level API call tracking for rate limiting and circuit breaker
$script:lastApiCallTime = [datetime]::MinValue
$script:apiErrorCount = 0
$script:circuitOpen = $false
$script:MaxConsecutiveErrors = 3
$script:stepErrorCount = @{}
$script:stepBatchCallCount = 0

# Load PRP config
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
$tolDays = 2
$acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $AccountName
if ($acctCfg -and $acctCfg.date_tolerance_days) { $tolDays = $acctCfg.date_tolerance_days }

function Invoke-PrpStep {
    param(
        [string]$ScriptName,
        [hashtable]$Params,
        $Order
    )

    $scriptPath = Join-Path $scriptDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [PSCustomObject]@{
            StepNumber = $Order
            Passed     = $false
            Details    = "Script not found: $ScriptName"
            NextSteps  = @("Ensure $ScriptName exists in $scriptDir")
        }
    }

    $pct = if ($Order -match '^[\d.]+$') { [double]$Order * 10 } else { 50 }
    Write-Progress -Activity "PRP Pipeline" -Status "Step $Order — $ScriptName" -PercentComplete $pct
    Write-Information "[PRP PIPELINE] Running Step ${Order}: ${ScriptName}" -Tags PRP

    $commonParams = @{}
    if ($Params.ContainsKey("Token")) { $commonParams["Token"] = $Params["Token"] }
    if ($Params.ContainsKey("Headers")) { $commonParams["Headers"] = $Params["Headers"] }
    if ($Params.ContainsKey("OrgId")) { $commonParams["OrgId"] = $Params["OrgId"] }
    if ($Params.ContainsKey("AccountId")) { $commonParams["AccountId"] = $Params["AccountId"] }

    $allParams = $Params.Clone()
    if (-not $allParams.ContainsKey("Platform") -and $Platform) { $allParams["Platform"] = $Platform }
    foreach ($kv in $commonParams.GetEnumerator()) {
        if (-not $allParams.ContainsKey($kv.Key)) {
            $allParams[$kv.Key] = $kv.Value
        }
    }

    if ($WhatIfPreference) {
        $allParams["WhatIf"] = $true
    }

    try {
        $result = & $scriptPath @allParams
        return $result
    } catch {
        return [PSCustomObject]@{
            StepNumber = $Order
            Passed     = $false
            Details    = "Script threw exception: $_"
            NextSteps  = @("Review error and re-run")
        }
    }
}

function Invoke-PrpNodeStep {
    param(
        [string]$ScriptName,
        [string]$StepOrder
    )

    $repoRoot = & git rev-parse --show-toplevel 2>$null
    if (-not $repoRoot -or $LASTEXITCODE -ne 0) {
        $repoRoot = Resolve-Path "$PSScriptRoot/../../.."
    }

    $scriptPathMap = @{
        "SyncTasReceiptStatus" = "Skills/Bookkeeping/Scripts/zoho/Sync-TasReceiptStatus.mjs"
        "UploadReceipts"       = "Skills/Bookkeeping/Scripts/upload/upload-tas-receipts.mjs"
        "SyncTasCategories"    = "Skills/Bookkeeping/Scripts/reconciliation/sync-tas-categories.mjs"
        "VerifyZohoBalance"    = "Skills/Bookkeeping/Scripts/zoho/verify-zoho-balance.mjs"
    }

    $containerScriptPathMap = @{
        "SyncTasReceiptStatus" = "/app/zoho/Sync-TasReceiptStatus.mjs"
        "UploadReceipts"       = "/app/upload/upload-tas-receipts.mjs"
        "SyncTasCategories"    = "/app/reconciliation/sync-tas-categories.mjs"
        "VerifyZohoBalance"    = "/app/zoho/verify-zoho-balance.mjs"
    }

    if (-not $scriptPathMap.ContainsKey($ScriptName)) {
        return [PSCustomObject]@{
            StepNumber = $StepOrder
            Passed     = $false
            Details    = "Unknown script key: $ScriptName"
            NextSteps  = @()
        }
    }

    $pct = if ($StepOrder -match '^[\d.]+$') { [double]$StepOrder * 10 } else { 50 }
    Write-Progress -Activity "PRP Pipeline" -Status "Step $StepOrder — $ScriptName" -PercentComplete $pct

    if ($script:platform -eq 'Container') {
        $containerScript = $containerScriptPathMap[$ScriptName]
        Write-Information "[PRP PIPELINE] Platform=Container — running ${ScriptName} via docker exec FRAD_is-bookkeeping node $containerScript" -Tags PRP
        try {
            $raw = docker exec FRAD_is-bookkeeping node $containerScript --entity $OrgName 2>&1
            $outputStr = $raw | Out-String
            $passed = $LASTEXITCODE -eq 0
            $details = if ($outputStr.Length -gt 500) { $outputStr.Substring(0, 500) } else { $outputStr }
            if ($details) { $details = $details.Trim() }
            if (-not $details) { $details = "Completed (no output)" }
            return [PSCustomObject]@{
                StepNumber = $StepOrder
                Passed     = $passed
                Details    = $details
                NextSteps  = @()
            }
        } catch {
            return [PSCustomObject]@{
                StepNumber = $StepOrder
                Passed     = $false
                Details    = "Container node script threw exception: $_"
                NextSteps  = @("Review error and re-run")
            }
        }
    }

    $scriptPath = Join-Path $repoRoot $scriptPathMap[$ScriptName]
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Warning "[PRP PIPELINE] Step $StepOrder — script not found: $scriptPath — skipping"
        return [PSCustomObject]@{
            StepNumber = $StepOrder
            Passed     = $true
            Details    = "Skipped — script not found: $ScriptName"
            NextSteps  = @()
        }
    }

    Write-Information "[PRP PIPELINE] Running Step ${StepOrder}: ${ScriptName} ($scriptPath)" -Tags PRP

    try {
        $output = & node $scriptPath --entity $OrgName 2>&1
        $outputStr = $output | Out-String
        $passed = $LASTEXITCODE -eq 0
        $details = if ($outputStr.Length -gt 500) { $outputStr.Substring(0, 500) } else { $outputStr }
        if ($details) { $details = $details.Trim() }
        if (-not $details) { $details = "Completed (no output)" }

        return [PSCustomObject]@{
            StepNumber = $StepOrder
            Passed     = $passed
            Details    = $details
            NextSteps  = @()
        }
    } catch {
        return [PSCustomObject]@{
            StepNumber = $StepOrder
            Passed     = $false
            Details    = "Node script threw exception: $_"
            NextSteps  = @("Review error and re-run")
        }
    }
}

function New-StepResult {
    param($StepResult, $Order, [string]$ScriptName)
    $passed = if ($StepResult -and $StepResult.Passed) { $true } else { $false }
    $details = if ($StepResult) { $StepResult.Details } else { "No result returned" }
    $nextSteps = if ($StepResult -and $StepResult.NextSteps) { $StepResult.NextSteps -join "; " } else { "" }

    return [PSCustomObject]@{
        Order      = $Order
        ScriptName = $ScriptName
        Passed     = $passed
        Details    = $details
        NextSteps  = $nextSteps
        Result     = $StepResult
    }
}

function Write-SummaryTable {
    param($Results)
    Write-Information "`n=== PRP Pipeline Summary ===" -Tags PRP
    foreach ($r in $Results) {
        $status = if ($r.Passed) { "PASS" } else { "FAIL" }
        Write-Information "  Step $($r.Order) | $status | $($r.ScriptName): $($r.Details)" -Tags PRP
    }
    Write-Information "=== End Summary ===" -Tags PRP
}

function Save-EvidenceFile {
    param($Results, $AccountName, $OrgName, $ZohoFetchDate, $PipelineStart)

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
    $prpReportsDir = Join-Path $booksRoot "PRP Reports"
    $null = New-Item -ItemType Directory -Path $prpReportsDir -Force

    $evidence = @{
        pipeline         = "prp"
        account          = $AccountName
        org              = $OrgName
        run_timestamp    = (Get-Date).ToString('o')
        zoho_data_fetched = if ($ZohoFetchDate) { $ZohoFetchDate.ToString('o') } else { $null }
        pipeline_started = if ($PipelineStart) { $PipelineStart.ToString('o') } else { (Get-Date).ToString('o') }
        total_steps      = $Results.Count
        passed_steps     = ($Results | Where-Object Passed).Count
        failed_steps     = ($Results | Where-Object { -not $_.Passed }).Count
        overall_status   = if (($Results | Where-Object { -not $_.Passed }).Count -eq 0) { "PASS" } else { "FAIL" }
        steps            = $Results | ForEach-Object {
            @{
                order       = $_.Order
                script      = $_.ScriptName
                passed      = $_.Passed
                details     = $_.Details
                next_steps  = $_.NextSteps
            }
        }
    }

    $evidencePath = Join-Path $prpReportsDir "prp-$OrgName-$AccountName-$ts.json"
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    Write-Information "[PRP PIPELINE] Evidence saved to $evidencePath" -Tags PRP

    $dataFreshness = if ($ZohoFetchDate) { $ZohoFetchDate.ToString('yyyy-MM-dd HH:mm:ss') } else { "Not fetched" }
    $reportPath = Join-Path $prpReportsDir "$OrgName-$AccountName-reconciliation-report-$ts.md"
    $runDate = if ($PipelineStart) { $PipelineStart.ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    $reportLines = @(
        "# Reconciliation Report: $OrgName — $AccountName",
        "",
        "## Metadata",
        "",
        "| Field | Value |",
        "|-------|-------|",
        "| Pipeline run | $runDate |",
        "| Zoho data freshness | $dataFreshness |",
        "| Org | $OrgName |",
        "| Account | $AccountName |",
        "| Overall status | $($evidence.overall_status) |",
        "| Steps passed | $($evidence.passed_steps) / $($evidence.total_steps) |",
        "",
        "## Step Results",
        "",
        "| Step | Status | Script | Details |",
        "|------|--------|--------|---------|"
    )
    foreach ($r in $Results) {
        $status = if ($r.Passed) { "PASS" } else { "FAIL" }
        $reportLines += "| $($r.Order) | $status | $($r.ScriptName) | $($r.Details) |"
    }
    $reportLines += ""
    $reportLines += "**Steps passed**: $($evidence.passed_steps) / $($evidence.total_steps)"
    $reportLines | Out-String | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Information "[PRP PIPELINE] Report saved to $reportPath" -Tags PRP

    return @{ EvidencePath = $evidencePath; ReportPath = $reportPath }
}

function Invoke-PaginatedZohoFetch {
    param(
        [string]$BaseUri,
        [hashtable]$Headers,
        [string]$ResultKey,
        [int]$PageSize = 200,
        [int]$MaxPages = 50
    )
    $allResults = @()
    $page = 1
    do {
        $uri = "$BaseUri&per_page=$PageSize&page=$page"
        try {
            $response = Invoke-ZohoApiWithThrottle -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers } -StepKey "PaginatedFetch"
            $items = $response.$ResultKey
            if ($items -and $items.Count -gt 0) {
                $allResults += $items
            }
            $hasMore = if ($response.page_context) { $response.page_context.has_more_page } else { $true }
            if ($hasMore -and $items -and $items.Count -lt $PageSize) { $hasMore = $false }
            if ($response.page_context -eq $null -and $items -and $items.Count -eq $PageSize) { $hasMore = $true }
            $page++
        } catch {
            Write-Warning "[PRP PAGINATION] Page $page fetch failed: $_ — returning $($allResults.Count) collected items"
            break
        }
    } while ($hasMore -and $page -le $MaxPages)
    Write-Information "[PRP PAGINATION] Fetched $($allResults.Count) $ResultKey across $($page-1) page(s)" -Tags PRP
    return $allResults
}

function Update-ZohoToken {
    param([ref]$HeadersRef)
    try {
        $stepDir = Split-Path -Parent $PSCommandPath
        . (Join-Path $stepDir "Invoke-PrpStep0-TokenAcquisition.ps1")
        $fresh = & (Join-Path $stepDir "Invoke-PrpStep0-TokenAcquisition.ps1") -OrgId $OrgId -OrgName $OrgName
        if ($fresh -and $fresh.Token) {
            $HeadersRef.Value = @{ Authorization = "Zoho-oauthtoken $($fresh.Token)"; "Content-Type" = "application/json" }
            Write-Warning "[PRP OAUTH] Token refreshed after 401 — continuing"
        }
    } catch {
        Write-Warning "[PRP OAUTH] Token refresh failed: $_"
    }
}

function Invoke-ZohoApiWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$BaseDelayMs = 1000,
        [array]$RetryStatusCodes = @(401, 429, 500, 502, 503, 504)
    )
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $lastError = $_
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($statusCode -eq 401 -and $attempt -eq 1) {
                Write-Warning "[PRP OAUTH] 401 detected — refreshing token and retrying"
                Update-ZohoToken -HeadersRef ([ref]$headers)
                $delay = $BaseDelayMs
                Start-Sleep -Milliseconds $delay
            } elseif ($attempt -lt $MaxRetries -and $statusCode -in $RetryStatusCodes) {
                $delay = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
                Write-Warning "[PRP RETRY] Attempt $attempt/$MaxRetries failed (code $statusCode) — retrying in ${delay}ms"
                Start-Sleep -Milliseconds $delay
            } elseif ($attempt -ge $MaxRetries) {
                Write-Warning "[PRP RETRY] All $MaxRetries attempts exhausted — giving up"
                throw $lastError
            } else {
                throw $lastError
            }
        }
    }
    throw $lastError
}

function Invoke-ZohoApiWithThrottle {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxConsecutiveErrors = 3,
        [string]$StepKey = "global"
    )
    if ($script:circuitOpen) {
        throw "[CIRCUIT BREAKER] Pipeline stopped after $($script:apiErrorCount) consecutive API errors. Check Zoho connectivity and re-run."
    }
    $now = Get-Date
    if ($script:lastApiCallTime -ne [datetime]::MinValue) {
        $elapsed = ($now - $script:lastApiCallTime).TotalMilliseconds
        $minGap = 350
        if ($elapsed -lt $minGap) {
            Start-Sleep -Milliseconds ($minGap - $elapsed)
        }
    }
    try {
        $result = Invoke-ZohoApiWithRetry -ScriptBlock $ScriptBlock
        $script:lastApiCallTime = Get-Date
        $script:apiErrorCount = 0
        $script:stepErrorCount[$StepKey] = 0
        return $result
    } catch {
        $script:lastApiCallTime = Get-Date
        $script:apiErrorCount++
        $script:stepErrorCount[$StepKey] = ($script:stepErrorCount[$StepKey] + 1)

        Write-Warning "[CIRCUIT BREAKER] API error #$($script:apiErrorCount) (step ${StepKey}: $($script:stepErrorCount[$StepKey])) — $_"

        if ($script:apiErrorCount -ge $MaxConsecutiveErrors) {
            $script:circuitOpen = $true
            Write-Error "[CIRCUIT BREAKER] $($script:apiErrorCount) consecutive API errors — circuit opened. Stopping pipeline."
        }
        if ($script:stepErrorCount[$StepKey] -ge 5) {
            Write-Warning "[CIRCUIT BREAKER] Step '$StepKey' failed $($script:stepErrorCount[$StepKey]) consecutive calls — step breaker tripped"
        }
        throw
    }
}

function Resume-Guard {
    param([string]$StepOrder)
    if (-not $ResumeFrom) { return $false }
    $phaseOrder = @("DG", "RC", "TR", "0", "0.1", "0.2", "0.5", "0.5b", "1", "2", "3", "3.5", "4", "5", "5.5", "6", "7", "7a", "7b", "7c", "7d", "7e", "7f")
    $stepIdx = $phaseOrder.IndexOf($StepOrder)
    $resumeIdx = $phaseOrder.IndexOf($ResumeFrom)
    if ($stepIdx -ge 0 -and $resumeIdx -ge 0) {
        return $stepIdx -lt $resumeIdx
    }
    $numeric = if ($StepOrder -match '^[\d.]+$') { [double]$StepOrder } else { 999 }
    $resumeVal = if ($ResumeFrom -match '^[\d.]+$') { [double]$ResumeFrom } else { 0 }
    if ($numeric -lt $resumeVal) { return $true }
    return $false
}

function Save-Checkpoint {
    param([string]$StepOrder, [string]$AccountName, [string]$OrgName)
    $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
    $prpReportsDir = Join-Path $booksRoot "PRP Reports"
    $null = New-Item -ItemType Directory -Path $prpReportsDir -Force
    $phaseOrder = @("DG", "RC", "TR", "0", "0.1", "0.2", "0.5", "0.5b", "1", "2", "3", "3.5", "4", "5", "5.5", "6", "7", "7a", "7b", "7c", "7d", "7e", "7f")
    $stepIdx = $phaseOrder.IndexOf($StepOrder)
    $nextStep = if ($stepIdx -ge 0 -and $stepIdx -lt $phaseOrder.Count - 1) { $phaseOrder[$stepIdx + 1] }
                 elseif ($StepOrder -match '^[\d.]+$') { ([double]$StepOrder + 1).ToString() }
                 else { "next" }
    $checkpoint = @{
        resume_from = $nextStep
        account = $AccountName
        org = $OrgName
        timestamp = (Get-Date).ToString('o')
    }
    $cpPath = Join-Path $prpReportsDir ".prp-checkpoint-$AccountName.json"
    $checkpoint | ConvertTo-Json | Set-Content -LiteralPath $cpPath -Encoding utf8
}

function New-PrivateHeaders {
    param($Token)
    return @{ Authorization = "Zoho-oauthtoken $Token"; "Content-Type" = "application/json" }
}

function Get-ContainerToken {
    try {
        $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
        if (-not $cid) { return $null }
        $fleetTok = (docker exec $cid cat /run/secrets/fleet_api_token 2>$null | ForEach-Object { $_.Trim() })
        $tokResponse = docker exec $cid curl -s -H "Authorization: Bearer $fleetTok" http://localhost:21008/zoho/token 2>$null
        if ($tokResponse) {
            $tokJson = $tokResponse | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($tokJson -and $tokJson.access_token) {
                return $tokJson.access_token
            }
        }
    } catch {
        Write-Warning "[PRP CONTAINER] Token fetch failed: $_"
    }
    return $null
}

$script:FleetApiToken = $null
function Get-FleetApiToken {
    if ($script:FleetApiToken) { return $script:FleetApiToken }
    try {
        $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
        if ($cid) {
            $script:FleetApiToken = docker exec $cid cat /run/secrets/fleet_api_token 2>$null
        }
    } catch {}
    return $script:FleetApiToken
}

function Invoke-ContainerZohoProxy {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        [object]$Body = $null
    )
    $encoded = [System.Web.HttpUtility]::UrlEncode($Url)
    $proxyUri = "http://localhost:21008/zoho/proxy?url=$encoded"
    $fleetToken = Get-FleetApiToken
    $headers = @{}
    if ($fleetToken) { $headers["Authorization"] = "Bearer $fleetToken" }
    try {
        if ($Method -eq 'GET') {
            $null = $headers.Remove("Content-Type")
            return Invoke-RestMethod -Uri $proxyUri -Method GET -Headers $headers -ErrorAction Stop
        } else {
            $jsonBody = $Body | ConvertTo-Json -Compress
            $headers["Content-Type"] = "application/json"
            return Invoke-RestMethod -Uri $proxyUri -Method $Method -Headers $headers -Body $jsonBody -ContentType "application/json" -ErrorAction Stop
        }
    } catch {
        Write-Warning "[PRP CONTAINER PROXY] $Method $Url failed: $_"
        throw
    }
}

function Invoke-ContainerPaginatedZohoFetch {
    param(
        [string]$BaseUri,
        [string]$ResultKey,
        [int]$PageSize = 200,
        [int]$MaxPages = 50
    )
    $allResults = @()
    $page = 1
    do {
        $fullUrl = "$BaseUri&per_page=$PageSize&page=$page"
        try {
            $response = Invoke-ContainerZohoProxy -Url $fullUrl -Method GET
            $items = $response.$ResultKey
            if ($items -and $items.Count -gt 0) {
                $allResults += $items
            }
            $hasMore = if ($response.page_context) { $response.page_context.has_more_page } else { $true }
            if ($hasMore -and $items -and $items.Count -lt $PageSize) { $hasMore = $false }
            if ($response.page_context -eq $null -and $items -and $items.Count -eq $PageSize) { $hasMore = $true }
            $page++
        } catch {
            Write-Warning "[PRP CONTAINER PAGINATION] Page $page fetch failed: $_ — returning $($allResults.Count) collected items"
            break
        }
    } while ($hasMore -and $page -le $MaxPages)
    Write-Information "[PRP CONTAINER PAGINATION] Fetched $($allResults.Count) $ResultKey across $($page-1) page(s)" -Tags PRP
    return $allResults
}

function Parse-TasData {
    param([string]$TasPath)
    if (-not (Test-Path $TasPath)) { Write-Warning "[PRP TAS] TAS file not found: $TasPath"; return @() }
    $lines = Get-Content $TasPath
    $dataStart = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -notmatch '^#') { $dataStart = $i; break } }
    $dataLines = $lines[($dataStart + 1)..($lines.Count - 1)]
    $txns = @()
    foreach ($line in $dataLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line -split ','
        if ($cols.Count -lt 4) { continue }
        $txns += [PSCustomObject]@{
            date    = $cols[0].Trim('"')
            account = $cols[1].Trim('"')
            amount  = [double]($cols[2].Trim('"'))
            desc    = $cols[3].Trim('"')
        }
    }
    Write-Information "[PRP TAS] Parsed $($txns.Count) transactions from TAS" -Tags PRP
    return $txns
}

function Get-FiscalYearDates {
    param($PrpCfg)
    $fyStart = "2025-04-01"
    $fyEnd = "2026-03-31"
    $source = "default"
    if ($PrpCfg -and $PrpCfg.org) {
        if ($PrpCfg.org.fiscal_year_start) { $fyStart = $PrpCfg.org.fiscal_year_start; $source = "config" }
        if ($PrpCfg.org.fiscal_year_end) { $fyEnd = $PrpCfg.org.fiscal_year_end; $source = "config" }
    }
    Write-Information "[FY DETECT] Using fiscal year $fyStart to $fyEnd (source: $source)" -Tags PRP
    return @{ fyStart = $fyStart; fyEnd = $fyEnd; source = $source }
}

function Detect-FiscalYear {
    param($PrpCfg, $ZohoAll)
    if ($PrpCfg -and $PrpCfg.org -and $PrpCfg.org.fiscal_year_start -and $PrpCfg.org.fiscal_year_end) {
        $fyStart = $PrpCfg.org.fiscal_year_start
        $fyEnd = $PrpCfg.org.fiscal_year_end
        Write-Information "[FY DETECT] Fiscal year from config: $fyStart to $fyEnd" -Tags PRP
        return @{ fyStart = $fyStart; fyEnd = $fyEnd; source = "config" }
    }
    if ($ZohoAll -and @($ZohoAll).Count -gt 0) {
        $dates = @($ZohoAll | Where-Object { $_.date -and $_.date -ne "" } | ForEach-Object {
            try { [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $null }
        } | Where-Object { $_ -ne $null })
        if ($dates.Count -gt 0) {
            $sortedDates = $dates | Sort-Object
            $earliestDate = $sortedDates[0]
            $latestDate = $sortedDates[-1]
            $orgType = if ($PrpCfg -and $PrpCfg.org -and $PrpCfg.org.name -eq "intersite-consulting") { "corporate" } else { "calendar" }
            if ($orgType -eq "corporate") {
                $fyYear = if ($latestDate.Month -ge 4) { $latestDate.Year } else { $latestDate.Year - 1 }
                $fyStart = "$fyYear-04-01"
                $fyEnd = "$($fyYear+1)-03-31"
            } else {
                $fyYear = $latestDate.Year
                $fyStart = "$fyYear-01-01"
                $fyEnd = "$fyYear-12-31"
            }
            Write-Information "[FY DETECT] Auto-detected fiscal year $fyStart to $fyEnd from Zoho data spanning $($earliestDate.ToString('yyyy-MM-dd')) to $($latestDate.ToString('yyyy-MM-dd'))" -Tags PRP
            return @{ fyStart = $fyStart; fyEnd = $fyEnd; source = "auto" }
        }
    }
    $fyStart = "2025-04-01"
    $fyEnd = "2026-03-31"
    Write-Warning "[FY DETECT] Could not detect fiscal year — using fallback $fyStart to $fyEnd"
    return @{ fyStart = $fyStart; fyEnd = $fyEnd; source = "default" }
}

function Invoke-CrDrSweep {
    param(
        [array]$Transactions,
        [switch]$ApplyDeletes
    )
    $sweptCount = 0
    $sweepMethod = "heuristic"
    if (-not $Transactions -or $Transactions.Count -eq 0) { return @() }
    $hasExpenseIds = ($Transactions | Where-Object { $_.expense_id -and $_.expense_id -ne "" }).Count -gt 0
    $sweptResult = @()
    if ($hasExpenseIds) {
        $sweepMethod = "expense_id"
        $expenseGroups = @{}
        foreach ($txn in $Transactions) {
            $eid = $txn.expense_id
            if (-not $expenseGroups.ContainsKey($eid)) { $expenseGroups[$eid] = @{ credits = @(); debits = @() } }
            $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
            if ($txnType -eq "credit") { $expenseGroups[$eid].credits += $txn } else { $expenseGroups[$eid].debits += $txn }
        }
        foreach ($txn in $Transactions) {
            $eid = $txn.expense_id
            $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
            if ($txnType -eq "credit") { $sweptResult += $txn }
            elseif ((-not $eid) -or ($expenseGroups[$eid].credits.Count -eq 0)) { $sweptResult += $txn }
            else { $sweptCount++ }
        }
    } else {
        $drPairs = @{}
        foreach ($txn in $Transactions) {
            $payee = if ($txn.payee) { $txn.payee } else { ($txn.description -replace ',.*') }
            $pairKey = "$($txn.date)|$([math]::Abs([decimal]$txn.amount))|$payee"
            if (-not $drPairs.ContainsKey($pairKey)) { $drPairs[$pairKey] = @{ credits = @(); debits = @() } }
            $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
            if ($txnType -eq "credit") { $drPairs[$pairKey].credits += $txn } else { $drPairs[$pairKey].debits += $txn }
        }
        foreach ($txn in $Transactions) {
            $payee = if ($txn.payee) { $txn.payee } else { ($txn.description -replace ',.*') }
            $pairKey = "$($txn.date)|$([math]::Abs([decimal]$txn.amount))|$payee"
            $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
            if ($txnType -eq "credit") { $sweptResult += $txn }
            elseif ($drPairs[$pairKey].credits.Count -eq 0) { $sweptResult += $txn }
            else { $sweptCount++ }
        }
    }
    Write-Information "[PRP CR+DR SWEEP] Swept $sweptCount duplicate DEBIT entries from analysis set (method: $sweepMethod) — $($sweptResult.Count) remaining" -Tags PRP
    return $sweptResult
}

# ===== PIPELINE EXECUTION =====

Write-Information "[PRP PIPELINE] Starting pipeline for $AccountName ($OrgName)" -Tags PRP
Write-Progress -Activity "PRP Pipeline" -Status "Initializing" -PercentComplete 0

# Phase step map — maps named phases to step order strings
$PhaseStepMap = @{
    "FullPipeline"    = "DG"
    "DataGathering"   = "DG"
    "ReceiptCheck"    = "RC"
    "TasRebuild"      = "TR"
    "TokenAcquisition" = "0"
    "PlaidDetection"  = "0.5"
    "SidecarVerify"   = "1"
    "ZohoMatch"       = "2"
    "Categorization"  = "3"
    "CategoryChecks"  = "3.5"
    "AuditWarnings"   = "4"
    "BalanceForward"  = "5"
    "DriftCorrection" = "5.5"
    "Reconcile"       = "6"
    "ReconTable"      = "7"
    "SyncReceiptStatus" = "7a"
    "UploadReceipts"  = "7b"
    "SyncCategories"  = "7c"
    "VerifyBalance"   = "7d"
    "UpdateStatus"    = "7e"
    "ReconReady"      = "7f"
}

# Resolve -Phase parameter to -ResumeFrom
if ($Phase) {
    if (-not $PhaseStepMap.ContainsKey($Phase)) {
        Write-Error "[PRP PIPELINE] Unknown phase '$Phase'. Valid phases: $($PhaseStepMap.Keys -join ', ')"
        exit 1
    }
    $resolvedStep = $PhaseStepMap[$Phase]
    if (-not $ResumeFrom) { $ResumeFrom = $resolvedStep }
    Write-Information "[PRP PIPELINE] Phase='$Phase' resolved to ResumeFrom='$ResumeFrom'" -Tags PRP
} elseif (-not $ResumeFrom) {
    $ResumeFrom = "0"
    Write-Information "[PRP PIPELINE] No -Phase or -ResumeFrom — defaulting to ResumeFrom='0' (legacy mode, skip DG/RC/TR)" -Tags PRP
}

$globalState = @{}
# Reset circuit breaker at pipeline start
$script:apiErrorCount = 0
$script:circuitOpen = $false
$script:stepErrorCount = @{}
$checkpointFile = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName\PRP Reports\.prp-checkpoint-$AccountName.json"
if ($ResumeFrom -and (Test-Path $checkpointFile)) {
    Write-Information "[PRP PIPELINE] ResumeFrom=$ResumeFrom — checkpoint loaded from $checkpointFile" -Tags PRP
}

# WhatIf mode: generate placeholder results without calling step scripts
if ($WhatIfPreference) {
    Write-Information "[PRP PIPELINE] WhatIf mode — printing all steps with actionable diff" -Tags PRP

    # --- Load local data for diffs (no API calls) ---
    $orgBooksRootLocal = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
    $tasFileNameLocal = if ($prpCfg.org.tas_file) { $prpCfg.org.tas_file } else { "TAS-2026.csv" }
    $tasPathLocal = Join-Path $orgBooksRootLocal $tasFileNameLocal

    $whatIfTasData = @()
    if (Test-Path $tasPathLocal) {
        $whatIfTasData = Parse-TasData -TasPath $tasPathLocal
        $acctLabelLocal = if ($acctCfg.label) { $acctCfg.label } else { $AccountName }
        $whatIfTasData = $whatIfTasData | Where-Object { $_.account -eq $acctLabelLocal }
    }

    # --- Categorization diff: scan TAS for uncategorized/missing categories ---
    $whatIfUncatFromTas = $whatIfTasData | Where-Object { -not $_.desc -or $_.desc -eq "" }
    Write-Information "`n### Categorization Diff" -Tags PRP
    if ($whatIfUncatFromTas.Count -gt 0) {
        Write-Information "| Date | Amount | Description |" -Tags PRP
        Write-Information "|------|--------|-------------|" -Tags PRP
        foreach ($ut in $whatIfUncatFromTas) {
            Write-Information "| $($ut.date) | `$$($ut.amount) | $($ut.desc) |" -Tags PRP
        }
        Write-Information "Would categorize $($whatIfUncatFromTas.Count) uncategorized transaction(s)" -Tags PRP
    } else {
        Write-Information "No uncategorized transactions found in TAS." -Tags PRP
    }

    # --- Drift diff: show which periods would be adjusted ---
    Write-Information "`n### Drift Diff" -Tags PRP
    if ($whatIfTasData.Count -gt 0) {
        Write-Information "Would analyze $($whatIfTasData.Count) TAS transactions for posting-date drift across periods." -Tags PRP
    } else {
        Write-Information "No TAS data loaded — drift analysis skipped." -Tags PRP
    }

    # --- Receipt upload diff: parse TAS for zoho_has_receipt rows ---
    Write-Information "`n### Receipt Upload Diff" -Tags PRP
    $whatIfNoReceiptCount = 0
    if (Test-Path $tasPathLocal) {
        $tasContentRaw = Get-Content $tasPathLocal -Raw
        $totalReceiptRows = [regex]::Matches($tasContentRaw, 'zoho_has_receipt').Count
        $noReceiptMatches = [regex]::Matches($tasContentRaw, 'zoho_has_receipt.*false')
        $whatIfNoReceiptCount = $noReceiptMatches.Count
        if ($whatIfNoReceiptCount -gt 0) {
            Write-Information "| Row | Vendor | Amount | Receipt File |" -Tags PRP
            Write-Information "|-----|--------|--------|-------------|" -Tags PRP
            $noReceiptLines = ($tasContentRaw -split "`n") | Where-Object { $_ -match 'zoho_has_receipt.*false' }
            $lineIdx = 0
            foreach ($rl in $noReceiptLines) {
                $rlCols = $rl -split ','
                $rlDate = if ($rlCols.Count -gt 0) { $rlCols[0].Trim('"') } else { "?" }
                $rlAmt = if ($rlCols.Count -gt 2) { $rlCols[2].Trim('"') } else { "?" }
                $rlDesc = if ($rlCols.Count -gt 3) { ($rlCols[3].Trim('"') -replace ',.*') } else { "?" }
                $lineIdx++
                if ($lineIdx -le 20) {
                    Write-Information "| $rlDate | $rlDesc | `$$rlAmt | (needs upload) |" -Tags PRP
                }
            }
            if ($whatIfNoReceiptCount -gt 20) {
                Write-Information "| ... and $($whatIfNoReceiptCount - 20) more |" -Tags PRP
            }
            Write-Information "Would upload $whatIfNoReceiptCount receipt(s) (out of $totalReceiptRows TAS rows)" -Tags PRP
        } else {
            Write-Information "All $totalReceiptRows TAS rows have receipts — nothing to upload." -Tags PRP
        }
    } else {
        Write-Information "TAS file not found at $tasPathLocal — receipt upload diff unavailable." -Tags PRP
    }

    # --- Reconciliation diff: sidecar periods ---
    Write-Information "`n### Reconciliation Diff" -Tags PRP
    $stmtFolderLocal = if ($acctCfg.bank_statement_folder) { $acctCfg.bank_statement_folder } else { $AccountName }
    $bsRootLocal = if ($prpCfg.org.bank_statements_root) { $prpCfg.org.bank_statements_root } else { "2026 Bank Statements" }
    $pfSidecarDirLocal = "$orgBooksRootLocal\$bsRootLocal\$stmtFolderLocal"
    if (Test-Path $pfSidecarDirLocal) {
        $sidecarFiles = Get-ChildItem "$pfSidecarDirLocal\*.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Zoho|Fiscal|zoho|dry-run' }
        Write-Information "Found $($sidecarFiles.Count) sidecar CSV file(s) in $pfSidecarDirLocal" -Tags PRP
        foreach ($sf in $sidecarFiles) {
            $sfContent = Get-Content $sf.FullName
            if ($sfContent.Count -ge 2) {
                $lastLine = $sfContent[-1]
                $lastCols = $lastLine -split ','
                $closingBal = if ($lastCols.Count -ge 5) { $lastCols[4].Trim('"') } else { "?" }
                Write-Information "  $($sf.Name) — closing balance: $closingBal" -Tags PRP
            }
        }
        Write-Information "Would reconcile $($sidecarFiles.Count) period(s) via sidecar CSVs" -Tags PRP
    } else {
        Write-Information "No sidecar directory found at $pfSidecarDirLocal — reconciliation diff unavailable." -Tags PRP
    }

    $allSteps = @(
        @{Order="DG"; Script="DataGathering"; Detail="Would run Zoho Plaid export + CSV copy"},
        @{Order="RC"; Script="ReceiptCheck"; Detail="Would check email for new receipts"},
        @{Order="TR"; Script="TasRebuild"; Detail="Would backup TAS, rebuild, detect manual edits"},
        @{Order="0"; Script="TokenAcquisition"; Detail="Would acquire OAuth token with caching"},
        @{Order="0.5"; Script="PlaidDetection"; Detail="Would analyze dataset for Plaid source detection"},
        @{Order=1; Script="SidecarVerify"; Detail="Would run reconcile-sidecars-vs-csv.py"},
        @{Order=2; Script="ZohoMatch"; Detail="Would compare counts across all periods"},
        @{Order=3; Script="CategorizationAudit"; Detail="Would categorize $($whatIfUncatFromTas.Count) uncategorized transaction(s)"},
        @{Order="3.5"; Script="CategoryChecks"; Detail="Would run 5 rubric checks"},
        @{Order=4; Script="AuditWarnings"; Detail="Would scan 10 warning patterns"},
        @{Order=5; Script="BalanceForward"; Detail="Would run three-way net flow comparison"},
        @{Order=6; Script="Reconcile"; Detail="Would attempt API reconciliation with fallback"},
        @{Order=7; Script="ReconTable"; Detail="Would generate Reconciliation Table and append to report"},
        @{Order="7a"; Script="SyncTasReceiptStatus"; Detail="Would run Sync-TasReceiptStatus.mjs"},
        @{Order="7b"; Script="UploadReceipts"; Detail="Would upload $whatIfNoReceiptCount receipt(s)"},
        @{Order="7c"; Script="SyncTasCategories"; Detail="Would run sync-tas-categories.mjs"},
        @{Order="7d"; Script="VerifyZohoBalance"; Detail="Would run verify-zoho-balance.mjs"},
        @{Order="7e"; Script="UpdateStatus"; Detail="Would run Invoke-StatusCheck.ps1 -SetReconciliationDate"},
        @{Order="7f"; Script="ReconReadyVerify"; Detail="Would run Invoke-PrpStep7f-ReconReadyVerify.ps1"}
    )
    $stepResults = $allSteps | ForEach-Object {
        [PSCustomObject]@{
            Order      = $_.Order
            ScriptName = $_.Script
            Passed     = $true
            Details    = $_.Detail
            NextSteps = ""
            Result     = $null
        }
    }
    Write-SummaryTable -Results $stepResults
    Write-Information "[PRP PIPELINE] WhatIf complete — above shows what would change" -Tags PRP
    exit 0
}

# --- Detect Phase: force ContinueOnError when running detect or remediate ---
if ($script:inDetectPhase -and -not $ContinueOnError) {
    Write-Information "[PRP DETECT] Detect phase active — forcing ContinueOnError for all steps" -Tags PRP
    $ContinueOnError = $true
}

# --- Step DG: Data Gathering ---
$stepDGResult = $null
if (-not (Resume-Guard -StepOrder "DG")) {
    $stepDGResult = Invoke-PrpStep -ScriptName "Invoke-PrpStepDG-DataGathering.ps1" -Params @{
        OrgName = $OrgName
        ContinueOnError = $ContinueOnError
        Platform = $script:platform
    } -Order "DG"
    $stepResults += New-StepResult -StepResult $stepDGResult -Order "DG" -ScriptName "DataGathering"

    if (-not $stepDGResult.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step DG failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }

    Save-Checkpoint -StepOrder "DG" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "DG"; ScriptName = "DataGathering"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step DG (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step RC: Receipt Check ---
$stepRCResult = $null
if (-not (Resume-Guard -StepOrder "RC")) {
    $stepRCResult = Invoke-PrpStep -ScriptName "Invoke-PrpStepRC-ReceiptCheck.ps1" -Params @{
        OrgName = $OrgName
        ContinueOnError = $ContinueOnError
    } -Order "RC"
    $stepResults += New-StepResult -StepResult $stepRCResult -Order "RC" -ScriptName "ReceiptCheck"

    if (-not $stepRCResult.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step RC failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }

    Save-Checkpoint -StepOrder "RC" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "RC"; ScriptName = "ReceiptCheck"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step RC (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step TR: TAS Rebuild ---
$stepTRResult = $null
if (-not (Resume-Guard -StepOrder "TR")) {
    $stepTRResult = Invoke-PrpStep -ScriptName "Invoke-PrpStepTR-TasRebuild.ps1" -Params @{
        OrgName = $OrgName
    } -Order "TR"
    $stepResults += New-StepResult -StepResult $stepTRResult -Order "TR" -ScriptName "TasRebuild"

    if (-not $stepTRResult.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step TR failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }

    Save-Checkpoint -StepOrder "TR" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "TR"; ScriptName = "TasRebuild"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step TR (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 0: Token Acquisition ---
$step0Result = $null

if ($script:platform -eq 'Container') {
    Write-Information "[PRP PIPELINE] Platform=Container — acquiring token from is-bookkeeping container" -Tags PRP
    $containerToken = Get-ContainerToken
    if ($containerToken) {
        $step0Result = [PSCustomObject]@{
            Passed  = $true
            Token   = $containerToken
            Headers = New-PrivateHeaders -Token $containerToken
            Details = "Token acquired from container endpoint"
        }
    } else {
        $step0Result = [PSCustomObject]@{
            Passed  = $false
            Token   = $null
            Headers = $null
            Details = "Container token acquisition failed — container may not be running"
        }
    }
    $stepResults += New-StepResult -StepResult $step0Result -Order "0" -ScriptName "TokenAcquisition"
    if (-not $step0Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 0 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }
    Save-Checkpoint -StepOrder "0" -AccountName $AccountName -OrgName $OrgName
} elseif (-not (Resume-Guard -StepOrder "0")) {
    $step0Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep0-TokenAcquisition.ps1" -Params @{
        OrgId   = $OrgId
        OrgName = $OrgName
    } -Order "0"
    $stepResults += New-StepResult -StepResult $step0Result -Order "0" -ScriptName "TokenAcquisition"

    if (-not $step0Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 0 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }

    Save-Checkpoint -StepOrder "0" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "0"; ScriptName = "TokenAcquisition"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 0 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

$token = if ($step0Result -and $step0Result.Token) { $step0Result.Token } else { $null }
$headers = if ($step0Result -and $step0Result.Headers) { $step0Result.Headers } else { $null }

# If token was pre-provided or acquired, build headers
if ($token -and -not $headers) {
    $headers = New-PrivateHeaders -Token $token
}

# --- Bulk fetch (inline) ---
$zohoFetchDate = $null
if ($token -and $OrgId -and $AccountId -and -not (Resume-Guard -StepOrder "0.9")) {
    Write-Information "[PRP PIPELINE] Fetching bulk Zoho data for $AccountName..." -Tags PRP
    $zohoFetchDate = Get-Date
    $fyDates = Get-FiscalYearDates -PrpCfg $prpCfg
    $fyStart = $fyDates.fyStart
    $fyEnd = $fyDates.fyEnd

    try {
        if ($script:platform -eq 'Container') {
            Write-Information "[PRP PIPELINE] Platform=Container — routing bulk fetch through container proxy" -Tags PRP
            $baseTxnUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$AccountId&organization_id=$OrgId&date_range_start=$fyStart&date_range_end=$fyEnd"
            $baseExpUri = "https://www.zohoapis.com/books/v3/expenses?account_id=$AccountId&organization_id=$OrgId&date_range_start=$fyStart&date_range_end=$fyEnd"
            $allTxns = Invoke-ContainerPaginatedZohoFetch -BaseUri $baseTxnUri -ResultKey "banktransactions"
            $uncatTxns = Invoke-ContainerPaginatedZohoFetch -BaseUri "${baseTxnUri}&status=uncategorized" -ResultKey "banktransactions"
            $allExpenses = Invoke-ContainerPaginatedZohoFetch -BaseUri $baseExpUri -ResultKey "expenses"
        } else {
            $baseTxnUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$AccountId&organization_id=$OrgId&date_range_start=$fyStart&date_range_end=$fyEnd"
            $baseExpUri = "https://www.zohoapis.com/books/v3/expenses?account_id=$AccountId&organization_id=$OrgId&date_range_start=$fyStart&date_range_end=$fyEnd"

            $allTxns = Invoke-ZohoApiWithRetry -ScriptBlock {
                Invoke-PaginatedZohoFetch -BaseUri $baseTxnUri -Headers $headers -ResultKey "banktransactions"
            }
            $uncatTxns = Invoke-ZohoApiWithRetry -ScriptBlock {
                Invoke-PaginatedZohoFetch -BaseUri "${baseTxnUri}&status=uncategorized" -Headers $headers -ResultKey "banktransactions"
            }
            $allExpenses = Invoke-ZohoApiWithRetry -ScriptBlock {
                Invoke-PaginatedZohoFetch -BaseUri $baseExpUri -Headers $headers -ResultKey "expenses"
            }
        }

        $zohoAll = @($allTxns) + @($uncatTxns) + @($allExpenses)
        $globalState["ZohoAll"] = $zohoAll
        $globalState["UncatTxns"] = $uncatTxns
        $globalState["AllExpenses"] = $allExpenses
        Write-Information "[PRP PIPELINE] Fetched $($zohoAll.Count) total records" -Tags PRP

        # Detect fiscal year from actual Zoho transaction data
        $detectedFy = Detect-FiscalYear -PrpCfg $prpCfg -ZohoAll $allTxns
        $fyStart = $detectedFy.fyStart
        $fyEnd = $detectedFy.fyEnd
        $globalState["FiscalYear"] = $detectedFy
    } catch {
        Write-Warning "[PRP PIPELINE] Bulk fetch failed: $_ — proceeding with empty dataset"
        $globalState["ZohoAll"] = @()
        $globalState["UncatTxns"] = @()
        $globalState["AllExpenses"] = @()
    }
} else {
    if ($WhatIf) {
        Write-Information "[PRP PIPELINE] WhatIf: would fetch bulk Zoho data" -Tags PRP
    }
    $globalState["ZohoAll"] = @()
    $globalState["UncatTxns"] = @()
    $globalState["AllExpenses"] = @()
}

# --- Stale Zoho data detection ---
if ($globalState["ZohoAll"] -and $globalState["ZohoAll"].Count -gt 0) {
    $createdTimes = @($globalState["ZohoAll"] | Where-Object { $_.created_time -and $_.created_time -ne "" } | ForEach-Object {
        try { [datetime]::ParseExact($_.created_time.Trim(), 'yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) } catch {
            try { [datetime]::ParseExact($_.created_time.Trim(), 'yyyy-MM-dd HH:mm:ss', $null) } catch { $null }
        }
    } | Where-Object { $_ -ne $null })
    if ($createdTimes.Count -gt 0) {
        $mostRecentCreated = ($createdTimes | Sort-Object -Descending)[0]
        $ageDays = ((Get-Date) - $mostRecentCreated).TotalDays
        if ($ageDays -gt 7) {
            Write-Warning "[DATA STALENESS] Zoho data is $([math]::Round($ageDays, 1)) days stale (most recent: $($mostRecentCreated.ToString('yyyy-MM-dd')))! Run monthly Zoho export (export-zoho-csv.mjs) or check Plaid connection."
        } elseif ($ageDays -gt 1) {
            Write-Warning "[DATA STALENESS] Zoho's most recent transaction is $([math]::Round($ageDays, 1)) days old ($($mostRecentCreated.ToString('yyyy-MM-dd'))). Plaid may not have synced recently."
        } else {
            Write-Information "[DATA STALENESS] Zoho data is current — most recent transaction from $($mostRecentCreated.ToString('yyyy-MM-dd'))" -Tags PRP
        }
    }
}

# Initialize state skip map — populated by Step 0.1 and refined after downstream steps
$globalState["SkipMap"] = @{
    skipCategorization  = $false
    skipReceiptUpload   = $false
    skipDriftCorrection = $false
    skipReconciliation  = @()
}

# --- Step 0.5b: CR+DR Duplicate Sweep ---
# Every POST /expenses creates two bank transactions (CREDIT + DEBIT) for the same
# date + amount. Sweep DEBITs from the local analysis set so Step 2 counts aren't 2×.
if ($globalState["ZohoAll"] -and $globalState["ZohoAll"].Count -gt 0) {
    $globalState["ZohoAll"] = Invoke-CrDrSweep -Transactions $globalState["ZohoAll"]
}

# --- Step 0.2: Pre-flight Data Source Detection ---
$orgBooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
$stmtFolder = if ($acctCfg.bank_statement_folder) { $acctCfg.bank_statement_folder } else { $AccountName }
$bsRoot = if ($prpCfg.org.bank_statements_root) { $prpCfg.org.bank_statements_root } else { "2026 Bank Statements" }
$pfSidecarDir = "$orgBooksRoot\$bsRoot\$stmtFolder"
$tasFileName = if ($prpCfg.org.tas_file) { $prpCfg.org.tas_file } else { "TAS-2026.csv" }
$pfTasPath = Join-Path $orgBooksRoot $tasFileName

$hasPlaidData = $false
$plaidTxnCount = 0
if ($globalState["ZohoAll"] -and $globalState["ZohoAll"].Count -gt 0) {
    $plaidTxns = $globalState["ZohoAll"] | Where-Object {
        $source = if ($_.source) { $_.source.ToString().ToLowerInvariant() } else { "" }
        $source -eq "plaid"
    }
    $plaidTxnCount = @($plaidTxns).Count
    if ($plaidTxnCount -gt 0) { $hasPlaidData = $true }
}

# Override Plaid detection if config explicitly disables it for this account
if ($acctCfg -and $acctCfg.plaid_enabled -eq $false) {
    $hasPlaidData = $false
    Write-Information "[PRP STEP 0.2] Plaid disabled by config — overriding classification to pdf_only" -Tags PRP
}

$hasSidecarCsv = $false
$hasPdf = $false
$pfDirExists = Test-Path -LiteralPath $pfSidecarDir
if ($pfDirExists) {
    $sidecarCsvs = Get-ChildItem "$pfSidecarDir\*.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Zoho|Fiscal|zoho|dry-run' }
    $hasSidecarCsv = @($sidecarCsvs).Count -gt 0
    $pdfs = Get-ChildItem "$pfSidecarDir\*.pdf" -ErrorAction SilentlyContinue
    $hasPdf = @($pdfs).Count -gt 0
}

$hasTas = Test-Path -LiteralPath $pfTasPath

$dataSourceClassification = if ($hasPlaidData -and ($hasSidecarCsv -or $hasPdf)) {
    "both"
} elseif ($hasPlaidData) {
    "plaid_only"
} elseif ($hasSidecarCsv -or $hasPdf) {
    "pdf_only"
} else {
    "neither"
}

$globalState["DataSourceClassification"] = $dataSourceClassification

Write-Information "[PRE-FLIGHT] Data sources for ${AccountName}: ${dataSourceClassification} (Plaid=${hasPlaidData}, SidecarCSV=${hasSidecarCsv}, PDF=${hasPdf}, TAS=${hasTas})" -Tags PRP

if ($dataSourceClassification -eq "neither") {
    Write-Error "[PRE-FLIGHT] No bank statement PDFs found in $pfSidecarDir and no Plaid-synced transactions in Zoho. Download statements before re-running."
    $stepResults += [PSCustomObject]@{
        Order = "0.2"
        ScriptName = "DataSourceDetection"
        Passed = $false
        Details = "No data sources found — neither Plaid nor PDF/sidecar data available"
        NextSteps = "Download bank statements or enable Plaid sync before re-running"
        Result = $null
    }
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
    exit 1
} else {
    $stepResults += [PSCustomObject]@{
        Order = "0.2"
        ScriptName = "DataSourceDetection"
        Passed = $true
        Details = "Data sources: $dataSourceClassification (Plaid=$hasPlaidData, SidecarCSV=$hasSidecarCsv, PDF=$hasPdf, TAS=$hasTas)"
        NextSteps = ""
        Result = $null
    }
}

# --- Step 0.1: State Assessment ---
if ($token -and $OrgId -and $AccountId) {
    Write-Information "[PRP PIPELINE] Step 0.1 — State Assessment" -Tags PRP
    $uncatCount = if ($globalState["UncatTxns"]) { $globalState["UncatTxns"].Count } else { 0 }
    Write-Information "[STATE ASSESSMENT] Uncategorized count: $uncatCount" -Tags PRP
    if ($uncatCount -eq 0) {
        $globalState["SkipMap"].skipCategorization = $true
        Write-Information "[STATE ASSESSMENT] Categorization: already complete (0 uncategorized transactions)" -Tags PRP
    }
    # Reconciliation state checked after Step 1 (needs sidecar periods)
    # Drift state checked after Step 5 (needs Balance Forward results)
    # Receipt state checked after Step 7a (needs SyncTasReceiptStatus)
} else {
    Write-Warning "[PRP PIPELINE] Step 0.1 — missing token/OrgId/AccountId — skipping state assessment"
}

# --- Step 0.5: Plaid Detection ---
$step05Result = $null
if (-not (Resume-Guard -StepOrder "0.5")) {
    $step05Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep05-PlaidDetection.ps1" -Params @{
        ZohoAll = $globalState["ZohoAll"]
        Token   = $token
        Headers = $headers
        OrgId   = $OrgId
        AccountId = $AccountId
    } -Order "0.5"
    $stepResults += New-StepResult -StepResult $step05Result -Order "0.5" -ScriptName "PlaidDetection"

    $isPlaidImmutable = if ($step05Result -and $step05Result.IsPlaidImmutable) { $true } else { $false }

    # Override Plaid immutability if config explicitly disables Plaid for this account
    if ($acctCfg -and $acctCfg.plaid_enabled -eq $false) {
        $isPlaidImmutable = $false
        Write-Information "[PRP STEP 0.5] Plaid disabled by config — running in API-mutable mode" -Tags PRP
    }

    # Store Plaid dedup info for evidence report
    if ($step05Result -and $step05Result.DedupedCount -gt 0) {
        $globalState["PlaidDedupedIds"] = $step05Result.DedupedIds
        Write-Information "[PRP PIPELINE] Plaid dedup removed $($step05Result.DedupedCount) duplicate transaction(s)" -Tags PRP
    }

    if (-not $step05Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 0.5 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "0.5" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "0.5"; ScriptName = "PlaidDetection"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 0.5 (ResumeFrom=$ResumeFrom)" -Tags PRP

    $isPlaidImmutable = $false
}

# --- Step 1: Sidecar Verification ---
$step1Result = $null
if (-not (Resume-Guard -StepOrder "1")) {
    $step1Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep1-SidecarVerify.ps1" -Params @{
        OrgName     = $OrgName
        AccountName = $AccountName
        Token       = $token
        Headers     = $headers
        OrgId       = $OrgId
        AccountId   = $AccountId
    } -Order 1
    $stepResults += New-StepResult -StepResult $step1Result -Order 1 -ScriptName "SidecarVerify"

    # Extract sidecar data from Step 1 for downstream steps
    $sidecarPeriods = if ($step1Result -and $step1Result.SidecarPeriods) { $step1Result.SidecarPeriods } else { @() }
    $sidecarData = if ($step1Result -and $step1Result.SidecarData) { $step1Result.SidecarData } else { @() }

    if (-not $step1Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 1 failed — aborting pipeline. Fix sidecar/TAS discrepancies first."
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
        exit 1
    }

    Save-Checkpoint -StepOrder "1" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 1; ScriptName = "SidecarVerify"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 1 (ResumeFrom=$ResumeFrom)" -Tags PRP

    $sidecarPeriods = @()
    $sidecarData = @()
}

# ---- Step 0.1b: Reconciliation State Update (now that sidecar periods are available) ----
if ($token -and $OrgId -and $AccountId -and $sidecarPeriods -and $sidecarPeriods.Count -gt 0) {
    Write-Information "[STATE ASSESSMENT] Checking reconciliation status for $($sidecarPeriods.Count) period(s)..." -Tags PRP
    $alreadyReconciled = @()
    $needsReconciled = @()
    try {
        $reconUri = "https://www.zohoapis.com/books/v3/bankaccounts/$AccountId/reconciliation?organization_id=$OrgId"
        $reconResp = Invoke-ZohoApiWithThrottle -ScriptBlock { Invoke-RestMethod -Uri $reconUri -Headers $headers } -StepKey "ReconCheck"
        $allReconStatuses = if ($reconResp -and $reconResp.reconciliation) { @($reconResp.reconciliation) } else { @() }
        foreach ($period in $sidecarPeriods) {
            $periodEndStr = $period.end.ToString('yyyy-MM-dd')
            $matched = $allReconStatuses | Where-Object { $_.reconciled_date -and $_.reconciled_date.Trim() -eq $periodEndStr }
            if ($matched -and $matched.status -eq "reconciled") {
                $alreadyReconciled += $periodEndStr
            } else {
                $needsReconciled += $periodEndStr
            }
        }
    } catch {
        $needsReconciled = @($sidecarPeriods | ForEach-Object { $_.end.ToString('yyyy-MM-dd') })
    }
    if ($alreadyReconciled.Count -gt 0) {
        Write-Information "[STATE ASSESSMENT] Reconciliation: $($alreadyReconciled.Count) period(s) already reconciled — $($alreadyReconciled -join ', ')" -Tags PRP
    }
    if ($needsReconciled.Count -gt 0) {
        Write-Information "[STATE ASSESSMENT] Reconciliation: $($needsReconciled.Count) period(s) need reconciliation — $($needsReconciled -join ', ')" -Tags PRP
    }
    $globalState["SkipMap"].skipReconciliation = $alreadyReconciled
    $globalState["ReconciledPeriods"] = $alreadyReconciled
    $globalState["UnreconciledPeriods"] = $needsReconciled
}

# ---- Cross-verify: if both sources, check for post-sidecar Zoho data ----
$hasPostSidecarData = $false
$postSidecarCount = 0
if ($globalState["DataSourceClassification"] -eq "both" -and $sidecarPeriods.Count -gt 0 -and $globalState["ZohoAll"] -and $globalState["ZohoAll"].Count -gt 0) {
    $sortedPeriods = $sidecarPeriods | Sort-Object end -Descending
    $sidecarMaxDate = $sortedPeriods[0].end
    $postSidecarTxns = $globalState["ZohoAll"] | Where-Object {
        $txnDate = if ($_.date -is [datetime]) { $_.date } else {
            try { [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue }
        }
        $txnDate -gt $sidecarMaxDate -and $txnDate -ne [datetime]::MinValue
    }
    $postSidecarCount = @($postSidecarTxns).Count
    if ($postSidecarCount -gt 0) {
        $hasPostSidecarData = $true
        Write-Information "[DATA NOTE] Zoho has $postSidecarCount transaction(s) after the latest sidecar period end ($($sidecarMaxDate.ToString('yyyy-MM-dd'))). These will be excluded from period matching." -Tags PRP
    }
}

# --- TAS Parsing (for downstream Steps 5 and 5.5) ---
$tasData = @()
$orgBooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
$tasFileName = if ($prpCfg.org.tas_file) { $prpCfg.org.tas_file } else { "TAS-2026.csv" }
$tasPath = Join-Path $orgBooksRoot $tasFileName
if (Test-Path $tasPath) {
    $tasData = Parse-TasData -TasPath $tasPath
    # Filter to this account's transactions
    $acctLabel = if ($acctCfg.label) { $acctCfg.label } else { $AccountName }
    $tasData = $tasData | Where-Object { $_.account -eq $acctLabel }
    Write-Information "[PRP PIPELINE] Loaded $($tasData.Count) TAS transactions for $AccountName" -Tags PRP
} else {
    Write-Warning "[PRP PIPELINE] TAS file not found at $tasPath — proceeding with empty TAS data"
}

# --- Step 2: Zoho Transaction Match ---
$step2Result = $null
if (-not (Resume-Guard -StepOrder "2")) {
    $step2Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep2-ZohoMatch.ps1" -Params @{
        ZohoAll            = $globalState["ZohoAll"]
        SidecarData        = $sidecarData
        SidecarPeriods     = $sidecarPeriods
        IsPlaidImmutable   = $isPlaidImmutable
        HasPostSidecarData = $hasPostSidecarData
        Token              = $token
        Headers            = $headers
        OrgId              = $OrgId
        AccountId          = $AccountId
        ToleranceDays      = $tolDays
        Platform           = $script:platform
    } -Order 2
    $stepResults += New-StepResult -StepResult $step2Result -Order 2 -ScriptName "ZohoMatch"

    if (-not $step2Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 2 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "2" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 2; ScriptName = "ZohoMatch"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 2 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 3: Categorization Audit ---
$step3Result = $null
if ($globalState["SkipMap"].skipCategorization) {
    $step3Result = [PSCustomObject]@{
        Passed = $true
        Details = "[SKIP] Categorization Audit — already completed (0 uncategorized in prior assessment)"
        NextSteps = @()
    }
    $stepResults += New-StepResult -StepResult $step3Result -Order 3 -ScriptName "CategorizationAudit"
    Write-Information "[PRP PIPELINE] [SKIP] Step 3 — categorization already complete" -Tags PRP
} elseif (-not (Resume-Guard -StepOrder "3")) {
    $step3Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep3-CategorizationAudit.ps1" -Params @{
        ZohoAll         = $globalState["ZohoAll"]
        UncatTxns       = $globalState["UncatTxns"]
        AllExpenses     = $globalState["AllExpenses"]
        IsPlaidImmutable = $isPlaidImmutable
        Token           = $token
        Headers         = $headers
        OrgId           = $OrgId
        AccountId       = $AccountId
        OrgName         = $OrgName
    } -Order 3
    $stepResults += New-StepResult -StepResult $step3Result -Order 3 -ScriptName "CategorizationAudit"

    if (-not $step3Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 3 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "3" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 3; ScriptName = "CategorizationAudit"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 3 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 3.5: Category Reasonableness Checks ---
$step35Result = $null
if ($globalState["SkipMap"].skipCategorization) {
    $step35Result = [PSCustomObject]@{
        Passed = $true
        Details = "[SKIP] Category Checks — categorization already complete"
        NextSteps = @()
    }
    $stepResults += New-StepResult -StepResult $step35Result -Order "3.5" -ScriptName "CategoryChecks"
    Write-Information "[PRP PIPELINE] [SKIP] Step 3.5 — categorization already complete" -Tags PRP
} elseif (-not (Resume-Guard -StepOrder "3.5")) {
    $step35Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep35-CategoryChecks.ps1" -Params @{
        ZohoAll         = $globalState["ZohoAll"]
        AllExpenses     = $globalState["AllExpenses"]
        IsPlaidImmutable = $isPlaidImmutable
        Token           = $token
        Headers         = $headers
        OrgId           = $OrgId
        AccountId       = $AccountId
    } -Order "3.5"
    $stepResults += New-StepResult -StepResult $step35Result -Order "3.5" -ScriptName "CategoryChecks"

    if (-not $step35Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 3.5 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "3.5" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "3.5"; ScriptName = "CategoryChecks"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 3.5 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 4: Audit Warning Scan ---
$step4Result = $null
if (-not (Resume-Guard -StepOrder "4")) {
    $step4Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep4-AuditWarnings.ps1" -Params @{
        ZohoAll         = $globalState["ZohoAll"]
        AllExpenses     = $globalState["AllExpenses"]
        IsPlaidImmutable = $isPlaidImmutable
        EntityName      = $OrgName
        Token           = $token
        Headers         = $headers
        OrgId           = $OrgId
        AccountId       = $AccountId
    } -Order 4
    $stepResults += New-StepResult -StepResult $step4Result -Order 4 -ScriptName "AuditWarnings"

    if (-not $step4Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 4 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "4" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 4; ScriptName = "AuditWarnings"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 4 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 5: Balance Forward Verification ---
$step5Result = $null
if (-not (Resume-Guard -StepOrder "5")) {
    $step5Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep5-BalanceForward.ps1" -Params @{
        SidecarData    = $sidecarData
        TasData        = $tasData
        ZohoAll        = $globalState["ZohoAll"]
        SidecarPeriods = $sidecarPeriods
        Token          = $token
        Headers        = $headers
        OrgId          = $OrgId
        AccountId      = $AccountId
        AmountTolerance = $tolDays
        Platform       = $script:platform
    } -Order 5
    $stepResults += New-StepResult -StepResult $step5Result -Order 5 -ScriptName "BalanceForward"

    if (-not $step5Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 5 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "5" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 5; ScriptName = "BalanceForward"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 5 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# ---- Drift State Check (Step 5 Balance Forward determines if drift correction needed) ----
if ($step5Result -and $step5Result.Passed -and -not $globalState["SkipMap"].skipDriftCorrection) {
    $globalState["SkipMap"].skipDriftCorrection = $true
    Write-Information "[STATE ASSESSMENT] Drift: all Balance Forward periods pass — drift correction already resolved" -Tags PRP
}

# --- Step 5.5: Drift Correction ---
$step55Result = $null
if ($globalState["SkipMap"].skipDriftCorrection) {
    $step55Result = [PSCustomObject]@{
        Passed = $true
        Details = "[SKIP] Drift Correction — all periods already balanced"
        DriftFixed = @()
        NextSteps = @()
    }
    $stepResults += New-StepResult -StepResult $step55Result -Order "5.5" -ScriptName "DriftCorrection"
    Write-Information "[PRP PIPELINE] [SKIP] Step 5.5 — drift already resolved" -Tags PRP
} elseif (-not (Resume-Guard -StepOrder "5.5")) {
    $step55Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep55-DriftCorrection.ps1" -Params @{
        BalanceForwardResults = $step5Result
        SidecarPeriods        = $sidecarPeriods
        ZohoAll               = $globalState["ZohoAll"]
        TasData               = $tasData
        IsPlaidImmutable      = $isPlaidImmutable
        Token                 = $token
        Headers               = $headers
        OrgId                 = $OrgId
        AccountId             = $AccountId
    } -Order "5.5"
    $stepResults += New-StepResult -StepResult $step55Result -Order "5.5" -ScriptName "DriftCorrection"

    if (-not $step55Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 5.5 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "5.5" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "5.5"; ScriptName = "DriftCorrection"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 5.5 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# Re-run Balance Forward after drift correction if corrections were attempted
if ($step55Result -and $step55Result.DriftFixed -and $step55Result.DriftFixed.Count -gt 0) {
    Write-Information "[PRP PIPELINE] Drift corrections applied — re-running Balance Forward" -Tags PRP
    $step5Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep5-BalanceForward.ps1" -Params @{
        SidecarData    = $sidecarData
        TasData        = $tasData
        ZohoAll        = $globalState["ZohoAll"]
        SidecarPeriods = $sidecarPeriods
        Token          = $token
        Headers        = $headers
        OrgId          = $OrgId
        AccountId      = $AccountId
        AmountTolerance = $tolDays
        Platform       = $script:platform
    } -Order 5
    $stepResults += New-StepResult -StepResult $step5Result -Order "5b" -ScriptName "BalanceForwardRecheck"
}

# --- Step 6: Hybrid Reconciliation (Multi-Period) ---
$step6Result = $null
if (-not (Resume-Guard -StepOrder "6")) {
    # Filter to unreconciled periods: compare reconciliation_date (from sidecar period) vs period_end
    $alreadyReconciledList = $globalState["SkipMap"].skipReconciliation
    $unreconciledPeriods = $sidecarPeriods | Where-Object {
        $periodEndStr = $_.end.ToString('yyyy-MM-dd')
        ($alreadyReconciledList -notcontains $periodEndStr) -and (-not $_.reconciliation_date -or $_.reconciliation_date -lt $_.end)
    } | Sort-Object end
    
    if ($alreadyReconciledList -and $alreadyReconciledList.Count -gt 0 -and $sidecarPeriods.Count -gt $unreconciledPeriods.Count) {
        Write-Information "[PRP PIPELINE] Step 6 — $($alreadyReconciledList.Count) period(s) already reconciled per state assessment, skipping: $($alreadyReconciledList -join ', ')" -Tags PRP
    }

    if ($unreconciledPeriods.Count -eq 0) {
        $step6Result = [PSCustomObject]@{
            Passed       = $true
            Details      = "All periods already reconciled — nothing to do"
            PerPeriod    = @()
            TotalPeriods = 0
            Reconciled   = 0
            Failed       = 0
        }
        $stepResults += New-StepResult -StepResult $step6Result -Order 6 -ScriptName "Reconcile"
    } else {
        $periodReconResults = @()
        $totalReconciled = 0; $totalFailed = 0

        foreach ($period in $unreconciledPeriods) {
            $periodEndStr = $period.end.ToString('yyyy-MM-dd')
            $closingBal = $period.closing_balance
            Write-Information "[PRP PIPELINE] Step 6 — Reconciling period ending $periodEndStr (closing balance: $closingBal)" -Tags PRP

            $reconAccountName = if ($acctCfg -and $acctCfg.label) { $acctCfg.label } else { $AccountName }
            $perPeriodResult = Invoke-PrpStep -ScriptName "Invoke-PrpStep6-Reconcile.ps1" -Params @{
                AccountId        = $AccountId
                AccountName      = $reconAccountName
                PeriodEnd        = $periodEndStr
                ClosingBalance   = $closingBal
                IsPlaidImmutable = $isPlaidImmutable
                Token            = $token
                Headers          = $headers
                OrgId            = $OrgId
                OrgName          = $OrgName
                Platform         = $script:platform
            } -Order "6-$($periodEndStr)"

            if ($perPeriodResult -and $perPeriodResult.Passed) {
                $totalReconciled++
                Write-Information "[PRP PIPELINE]   Period $periodEndStr — reconciled" -Tags PRP
            } else {
                $totalFailed++
                $failDetail = if ($perPeriodResult) { $perPeriodResult.Details } else { "No result" }
                Write-Warning "[PRP PIPELINE]   Period $periodEndStr — failed: $failDetail"
            }
            $periodReconResults += $perPeriodResult
        }

        $step6Passed = $totalFailed -eq 0
        $step6Result = [PSCustomObject]@{
            Passed       = $step6Passed
            Details      = "Reconciled $totalReconciled/$($unreconciledPeriods.Count) periods (failed: $totalFailed)"
            PerPeriod    = $periodReconResults
            TotalPeriods = $unreconciledPeriods.Count
            Reconciled   = $totalReconciled
            Failed       = $totalFailed
        }
        $stepResults += New-StepResult -StepResult $step6Result -Order 6 -ScriptName "Reconcile"
    }

    if (-not $step6Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 6 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "6" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 6; ScriptName = "Reconcile"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 6 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7: Reconciliation Table Generation ---
$step7Result = $null
if (-not (Resume-Guard -StepOrder "7")) {
    $step7Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep7-ReconTable.ps1" -Params @{
        SidecarPeriods    = $sidecarPeriods
        SidecarData       = $sidecarData
        TasData           = $tasData
        ZohoAll           = $globalState["ZohoAll"]
        BalanceForwardResults = $step5Result
        ZohoMatchResults      = $step2Result
        AccountName       = $AccountName
        OrgName           = $OrgName
        IsCreditCard      = $(if ($acctCfg.is_credit_card) { $true } else { $false })
        ReportPath        = $(if ($paths) { $paths.ReportPath } else { $null })
    } -Order 7
    $stepResults += New-StepResult -StepResult $step7Result -Order 7 -ScriptName "ReconTable"

    if (-not $step7Result.Passed -and -not $ContinueOnError) {
        Write-Error "[PRP PIPELINE] Step 7 failed — aborting pipeline"
        Write-SummaryTable -Results $stepResults
        Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart
        exit 1
    }

    Save-Checkpoint -StepOrder "7" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = 7; ScriptName = "ReconTable"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7 (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7a: Sync TAS Receipt Status ---
$step7aResult = $null
if (-not (Resume-Guard -StepOrder "7a")) {
    $step7aResult = Invoke-PrpNodeStep -ScriptName "SyncTasReceiptStatus" -StepOrder "7a"
    $stepResults += New-StepResult -StepResult $step7aResult -Order "7a" -ScriptName "SyncTasReceiptStatus"
    if (-not $step7aResult.Passed) {
        Write-Warning "[PRP PIPELINE] Step 7a (SyncTasReceiptStatus) failed — continuing pipeline"
    }
    Save-Checkpoint -StepOrder "7a" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7a"; ScriptName = "SyncTasReceiptStatus"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7a (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# ---- Receipt State Check (after SyncTasReceiptStatus, check if uploads needed) ----
if (-not $globalState["SkipMap"].skipReceiptUpload) {
    $orgBooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
    $tasFileName = if ($prpCfg.org.tas_file) { $prpCfg.org.tas_file } else { "TAS-2026.csv" }
    $tasCheckPath = Join-Path $orgBooksRoot $tasFileName
    if (Test-Path $tasCheckPath) {
        $tasContent = Get-Content $tasCheckPath -Raw
        $hasReceiptCount = [regex]::Matches($tasContent, 'zoho_has_receipt.*true').Count
        $noReceiptCount = [regex]::Matches($tasContent, 'zoho_has_receipt.*false').Count
        $totalRows = [regex]::Matches($tasContent, 'zoho_has_receipt').Count
        Write-Information "[STATE ASSESSMENT] Receipts: $hasReceiptCount uploaded, $noReceiptCount pending (out of $totalRows TAS rows with status)" -Tags PRP
        if ($noReceiptCount -eq 0 -and $totalRows -gt 0) {
            $globalState["SkipMap"].skipReceiptUpload = $true
            Write-Information "[STATE ASSESSMENT] Receipt upload: already complete (all TAS rows have receipts)" -Tags PRP
        }
    } else {
        Write-Information "[STATE ASSESSMENT] Receipts: TAS file not found at $tasCheckPath — cannot assess" -Tags PRP
    }
}

# --- Step 7b: Upload Receipts ---
$step7bResult = $null
if ($globalState["SkipMap"].skipReceiptUpload) {
    $step7bResult = [PSCustomObject]@{
        StepNumber = "7b"
        Passed     = $true
        Details    = "[SKIP] Receipt Upload — all receipts already uploaded"
        NextSteps  = @()
    }
    $stepResults += New-StepResult -StepResult $step7bResult -Order "7b" -ScriptName "UploadReceipts"
    Write-Information "[PRP PIPELINE] [SKIP] Step 7b — all receipts already uploaded" -Tags PRP
} elseif (-not (Resume-Guard -StepOrder "7b")) {
    $step7bResult = Invoke-PrpNodeStep -ScriptName "UploadReceipts" -StepOrder "7b"
    $stepResults += New-StepResult -StepResult $step7bResult -Order "7b" -ScriptName "UploadReceipts"
    if (-not $step7bResult.Passed) {
        Write-Warning "[PRP PIPELINE] Step 7b (UploadReceipts) failed — continuing pipeline"
    }
    Save-Checkpoint -StepOrder "7b" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7b"; ScriptName = "UploadReceipts"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7b (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7c: Sync TAS Categories ---
$step7cResult = $null
if (-not (Resume-Guard -StepOrder "7c")) {
    $step7cResult = Invoke-PrpNodeStep -ScriptName "SyncTasCategories" -StepOrder "7c"
    $stepResults += New-StepResult -StepResult $step7cResult -Order "7c" -ScriptName "SyncTasCategories"
    if (-not $step7cResult.Passed) {
        Write-Warning "[PRP PIPELINE] Step 7c (SyncTasCategories) failed — continuing pipeline"
    }
    Save-Checkpoint -StepOrder "7c" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7c"; ScriptName = "SyncTasCategories"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7c (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7d: Verify Zoho Balance ---
$step7dResult = $null
if (-not (Resume-Guard -StepOrder "7d")) {
    $step7dResult = Invoke-PrpNodeStep -ScriptName "VerifyZohoBalance" -StepOrder "7d"
    $stepResults += New-StepResult -StepResult $step7dResult -Order "7d" -ScriptName "VerifyZohoBalance"
    if (-not $step7dResult.Passed) {
        Write-Warning "[PRP PIPELINE] Step 7d (VerifyZohoBalance) failed — continuing pipeline"
    }
    Save-Checkpoint -StepOrder "7d" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7d"; ScriptName = "VerifyZohoBalance"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7d (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7e: Update Status via Invoke-StatusCheck ---
$step7eResult = $null
if (-not (Resume-Guard -StepOrder "7e")) {
    $repoRoot = & git rev-parse --show-toplevel 2>$null
    if (-not $repoRoot -or $LASTEXITCODE -ne 0) {
        $repoRoot = Resolve-Path "$PSScriptRoot/../../.."
    }
    $statusCheckPath = Join-Path $repoRoot "Skills/Bookkeeping/Scripts/Invoke-StatusCheck.ps1"

    $latestPeriodEnd = "2026-03-31"
    if ($sidecarPeriods -and $sidecarPeriods.Count -gt 0) {
        $sortedPeriods = $sidecarPeriods | Sort-Object end -Descending
        $latestPeriodEnd = $sortedPeriods[0].end.ToString('yyyy-MM-dd')
    }

    Write-Information "[PRP PIPELINE] Step 7e — Updating status for $OrgName with reconciliation date $latestPeriodEnd" -Tags PRP

    $step7ePassed = $false
    $step7eDetails = ""
    if (Test-Path $statusCheckPath) {
        try {
            $null = & $statusCheckPath -Organization $OrgName -SetReconciliationDate $latestPeriodEnd -Source AgentGenerated -Confirm:$false -ErrorAction SilentlyContinue 2>&1
            $step7ePassed = $LASTEXITCODE -eq 0
            $step7eDetails = if ($step7ePassed) { "Status updated — reconciliation_date set to $latestPeriodEnd" } else { "Status check script exited with code $LASTEXITCODE" }
        } catch {
            $step7eDetails = "Status check script threw: $_"
            $step7ePassed = $false
        }
    } else {
        $step7eDetails = "Script not found: $statusCheckPath"
    }

    if (-not $step7ePassed) {
        Write-Warning "[PRP PIPELINE] Step 7e — $step7eDetails — continuing pipeline"
    } else {
        Write-Information "[PRP PIPELINE] Step 7e — $step7eDetails" -Tags PRP
    }

    $step7eResult = [PSCustomObject]@{
        StepNumber = "7e"
        Passed     = $step7ePassed
        Details    = $step7eDetails
        NextSteps  = @()
    }
    $stepResults += New-StepResult -StepResult $step7eResult -Order "7e" -ScriptName "UpdateStatus"

    Save-Checkpoint -StepOrder "7e" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7e"; ScriptName = "UpdateStatus"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7e (ResumeFrom=$ResumeFrom)" -Tags PRP
}

# --- Step 7f: Recon Ready Verification ---
$step7fResult = $null
if (-not (Resume-Guard -StepOrder "7f")) {
    $step7fResult = Invoke-PrpStep -ScriptName "Invoke-PrpStep7f-ReconReadyVerify.ps1" -Params @{
        OrgName          = $OrgName
        AccountName      = $AccountName
        IsPlaidImmutable = $isPlaidImmutable
    } -Order "7f"
    $stepResults += New-StepResult -StepResult $step7fResult -Order "7f" -ScriptName "ReconReadyVerify"
    if (-not $step7fResult.Passed) {
        Write-Warning "[PRP PIPELINE] Step 7f — Recon Ready check failed: $($step7fResult.Details)"
    }
    Save-Checkpoint -StepOrder "7f" -AccountName $AccountName -OrgName $OrgName
} else {
    $stepResults += [PSCustomObject]@{ Order = "7f"; ScriptName = "ReconReadyVerify"; Passed = $true; Details = "Skipped (ResumeFrom=$ResumeFrom)"; NextSteps = ""; Result = $null }
    Write-Information "[PRP PIPELINE] Skipping Step 7f (ResumeFrom=$ResumeFrom)" -Tags PRP
}

$allPassed = ($stepResults | Where-Object { -not $_.Passed }).Count -eq 0

# --- Final output ---
Write-Progress -Activity "PRP Pipeline" -Status "Complete" -PercentComplete 100
Write-SummaryTable -Results $stepResults
$paths = Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName -ZohoFetchDate $zohoFetchDate -PipelineStart $pipelineStart

# --- Detect-only mode: exit after evidence ---
if ($DetectOnly) {
    Write-Information "[PRP PIPELINE] Detect-only mode — evidence saved. Exiting without remediation." -Tags PRP
    exit 0
}

# --- Pass 2: Remediation phase (only in remediate mode, when failures exist) ---
if ($Remediate -and -not $allPassed) {
    Write-Information "[PRP PIPELINE] Remediation phase — dispatching handlers for failed steps" -Tags PRP
    $remediationDispatch = @{
        "MissingExpenses"    = "Invoke-PrpRemediate-MissingExpenses.ps1"
        "UncategorizedTxns"  = "Invoke-PrpStep3-CategorizationAudit.ps1"
        "ReconciliationFail" = "Invoke-PrpStep6-Reconcile.ps1"
        "BalanceDrift"       = "Invoke-PrpStep55-DriftCorrection.ps1"
    }
    $evidence = Get-Content $paths.EvidencePath -Raw | ConvertFrom-Json
    foreach ($stepFailure in $evidence.steps | Where-Object { -not $_.passed }) {
        $failureType = "StepFailure"
        if ($stepFailure.script -eq "SidecarVerify" -and $stepFailure.details -match 'not in TAS|missing') { $failureType = "MissingExpenses" }
        elseif ($stepFailure.script -eq "CategorizationAudit") { $failureType = "UncategorizedTxns" }
        elseif ($stepFailure.script -eq "Reconcile") { $failureType = "ReconciliationFail" }
        elseif ($stepFailure.script -eq "DriftCorrection") { $failureType = "BalanceDrift" }
        $handler = $remediationDispatch[$failureType]
        if ($handler) {
            $handlerPath = Join-Path $scriptDir $handler
            if (Test-Path $handlerPath) {
                Write-Information "[PRP REMEDIATE] Dispatching $failureType → $handler" -Tags PRP
                try {
                    if ($failureType -eq "MissingExpenses") {
                        if ([string]::IsNullOrWhiteSpace($OrgName)) {
                            Write-Warning "[PRP REMEDIATE] Skipping MissingExpenses — OrgName is empty"
                            continue
                        }
                        $handlerParams = @{
                            OrgName     = $OrgName
                            OrgId       = $OrgId
                            AccountName = $AccountName
                            AccountId   = $AccountId
                        }
                        if ($stepFailure) { $handlerParams["Evidence"] = $stepFailure }
                    } else {
                        Write-Information "[PRP REMEDIATE] Skipping $failureType — no specialized handler available, use Step 7 outputs for manual action" -Tags PRP
                        continue
                    }
                    & $handlerPath @handlerParams 2>&1 | ForEach-Object { Write-Information "[PRP REMEDIATE]   $_" -Tags PRP }
                    Write-Information "[PRP REMEDIATE] $failureType — handler completed" -Tags PRP
                } catch {
                    Write-Warning "[PRP REMEDIATE] $failureType — handler threw: $_"
                }
            } else {
                Write-Warning "[PRP REMEDIATE] Handler not found: $handlerPath — skipping $failureType"
            }
        } else {
            Write-Information "[PRP REMEDIATE] No handler for failure type '$failureType' on step $($stepFailure.script) — skipping" -Tags PRP
        }
    }
    Write-Information "[PRP PIPELINE] Remediation phase complete" -Tags PRP
}

$stepsPassedCount = ($stepResults | Where-Object Passed).Count
$stepsTotalCount = $stepResults.Count
$reconciledPeriodsCount = if ($globalState["ReconciledPeriods"]) { $globalState["ReconciledPeriods"].Count } else { 0 }
$receiptsUploadedCount = 0

# --- Completion notification via workflow-events.log ---
$notificationEvent = @{
    type              = "pipeline_complete"
    timestamp         = (Get-Date).ToString('o')
    domain            = "Bookkeeper"
    org               = $OrgName
    account           = $AccountName
    overall_status    = if ($allPassed) { "PASS" } else { "FAIL" }
    steps_passed      = $stepsPassedCount
    steps_total       = $stepsTotalCount
    reconciled_periods = $reconciledPeriodsCount
    receipts_uploaded = $receiptsUploadedCount
    errors            = @(if (-not $allPassed) { ($stepResults | Where-Object { -not $_.Passed } | ForEach-Object { "$($_.Order) $($_.ScriptName): $($_.Details)" }) } else { @() })
}
$workflowEventsDir = Join-Path (Split-Path -Parent $PSCommandPath) "..\..\..\..\Tasks\Logs"
if (-not (Test-Path $workflowEventsDir)) { $null = New-Item -ItemType Directory -Path $workflowEventsDir -Force }
$notificationLine = $notificationEvent | ConvertTo-Json -Compress
Add-Content -LiteralPath (Join-Path $workflowEventsDir "workflow-events.log") -Value $notificationLine -Encoding utf8
Write-Information "[NOTIFICATION] Pipeline completion logged to workflow-events.log" -Tags PRP

$elapsed = [math]::Round(((Get-Date) - $pipelineStart).TotalSeconds, 0)
Write-Information "[PRP PIPELINE] Pipeline finished in ${elapsed}s — Overall: $(if ($allPassed) { 'PASS' } else { 'FAIL' })" -Tags PRP

if ($allPassed) {
    Write-Information "[PRP PIPELINE] All steps passed for $AccountName ($OrgName)" -Tags PRP
    exit 0
} else {
    $failedSteps = $stepResults | Where-Object { -not $_.Passed }
    foreach ($fs in $failedSteps) {
        Write-Error "[PRP FAIL] Step $($fs.Order) failed — $($fs.Details)"
        if ($fs.NextSteps) { Write-Information "  Next: $($fs.NextSteps)" -Tags PRP }
    }
    exit 1
}
