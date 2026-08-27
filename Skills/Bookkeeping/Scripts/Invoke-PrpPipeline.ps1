<#
.SYNOPSIS
    PRP Master Orchestrator — runs the full Pre-Recon Pipeline with stop-on-fail.
.DESCRIPTION
    Calls each Invoke-PrpStep*.ps1 script in sequence, passing state (token,
    headers, org/account IDs) between steps. Stops on first failure unless
    -ContinueOnError is set. Generates a pass/fail summary and saves evidence.
.PARAMETER AccountName
    Account slug name (e.g. "RBC-INTERSITE", "TD-MLM").
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER ContinueOnError
    Continue pipeline even if a step fails (diagnostic mode).
.PARAMETER ResumeFrom
    Step number to resume from (skip earlier steps).
.PARAMETER WhatIf
    Dry-run: log all steps without executing.
.EXAMPLE
    .\Invoke-PrpPipeline.ps1 -AccountName "RBC-INTERSITE" -OrgName "intersite-consulting" -OrgId "925048093" -AccountId "12345"
.EXAMPLE
    .\Invoke-PrpPipeline.ps1 -AccountName "TD-MLM" -OrgName "room-rentals" -WhatIf
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

    [switch]$ContinueOnError,

    [string]$ResumeFrom,

    [Parameter()]
    [string]$FiscalYear,

    [Parameter()]
    [string]$PeriodEnd
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$stepResults = @()
$pipelineStart = Get-Date

# Load PRP config
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$tolDays = 2
$acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $AccountName
if ($acctCfg -and $acctCfg.date_tolerance_days) { $tolDays = $acctCfg.date_tolerance_days }

function Invoke-PrpStep {
    param(
        [string]$ScriptName,
        [hashtable]$Params,
        [int]$Order
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

    Write-Progress -Activity "PRP Pipeline" -Status "Step $Order — $ScriptName" -PercentComplete ($Order * 10)
    Write-Information "[PRP PIPELINE] Running Step ${Order}: ${ScriptName}" -Tags PRP

    $commonParams = @{}
    if ($Params.ContainsKey("Token")) { $commonParams["Token"] = $Params["Token"] }
    if ($Params.ContainsKey("Headers")) { $commonParams["Headers"] = $Params["Headers"] }
    if ($Params.ContainsKey("OrgId")) { $commonParams["OrgId"] = $Params["OrgId"] }
    if ($Params.ContainsKey("AccountId")) { $commonParams["AccountId"] = $Params["AccountId"] }

    $allParams = $Params.Clone()
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

function New-StepResult {
    param($StepResult, [int]$Order, [string]$ScriptName)
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
    param($Results, $AccountName, $OrgName)

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $logDir = Join-Path (Resolve-Path "$scriptDir\..\..\..") "Tasks\Logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force

    $evidence = @{
        pipeline       = "prp"
        account        = $AccountName
        org            = $OrgName
        run_timestamp  = (Get-Date).ToString('o')
        total_steps    = $Results.Count
        passed_steps   = ($Results | Where-Object Passed).Count
        failed_steps   = ($Results | Where-Object { -not $_.Passed }).Count
        overall_status = if (($Results | Where-Object { -not $_.Passed }).Count -eq 0) { "PASS" } else { "FAIL" }
        steps          = $Results | ForEach-Object {
            @{
                order       = $_.Order
                script      = $_.ScriptName
                passed      = $_.Passed
                details     = $_.Details
                next_steps  = $_.NextSteps
            }
        }
    }

    $evidencePath = Join-Path $logDir "prp-$OrgName-$ts.json"
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    Write-Information "[PRP PIPELINE] Evidence saved to $evidencePath" -Tags PRP

    $reportPath = Join-Path $logDir "$OrgName-reconciliation-report-$ts.md"
    $reportLines = @(
        "# Reconciliation Report: $OrgName — $AccountName",
        "",
        "**Run**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "**Overall**: $($evidence.overall_status)",
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
            $response = Invoke-RestMethod -Uri $uri -Headers $Headers
            $items = $response.$ResultKey
            if ($items -and $items.Count -gt 0) {
                $allResults += $items
            }
            $hasMore = if ($response.page_context) { $response.page_context.has_more_page } else { $false }
            $page++
        } catch {
            Write-Warning "[PRP PAGINATION] Page $page fetch failed: $_ — returning $($allResults.Count) collected items"
            break
        }
    } while ($hasMore -and $page -le $MaxPages)
    Write-Information "[PRP PAGINATION] Fetched $($allResults.Count) $ResultKey across $($page-1) page(s)" -Tags PRP
    return $allResults
}

function Invoke-ZohoApiWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$BaseDelayMs = 1000,
        [array]$RetryStatusCodes = @(429, 500, 502, 503, 504)
    )
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $lastError = $_
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($attempt -lt $MaxRetries -and $statusCode -in $RetryStatusCodes) {
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

function New-PrivateHeaders {
    param($Token)
    return @{ Authorization = "Zoho-oauthtoken $Token"; "Content-Type" = "application/json" }
}

# ===== PIPELINE EXECUTION =====

Write-Information "[PRP PIPELINE] Starting pipeline for $AccountName ($OrgName)" -Tags PRP
Write-Progress -Activity "PRP Pipeline" -Status "Initializing" -PercentComplete 0

$globalState = @{}

# WhatIf mode: generate placeholder results without calling step scripts
if ($WhatIfPreference) {
    Write-Information "[PRP PIPELINE] WhatIf mode — printing all steps without execution" -Tags PRP
    $allSteps = @(
        @{Order=0; Script="TokenAcquisition"; Detail="Would acquire OAuth token with caching"},
        @{Order="0.5"; Script="PlaidDetection"; Detail="Would analyze dataset for Plaid source detection"},
        @{Order=1; Script="SidecarVerify"; Detail="Would run reconcile-sidecars-vs-csv.py"},
        @{Order=2; Script="TasRebuild"; Detail="Would rebuild TAS as temporary working file from Zoho"},
        @{Order=3; Script="ZohoMatch"; Detail="Would compare counts across all periods"},
        @{Order=4; Script="DiscoverStatements"; Detail="Would scan filesystem for PDF bank statements"},
        @{Order=5; Script="SelectPeriod"; Detail="Would determine reconciliation scope (user/last-complete/partial)"},
        @{Order=6; Script="AuditWarnings"; Detail="Would scan 10 warning patterns"},
        @{Order=7; Script="BalanceForward"; Detail="Would run recon-troubleshoot balance forward check against statement PDFs"},
        @{Order=8; Script="Reconcile"; Detail="Would attempt API reconciliation with fallback"},
        @{Order=9; Script="CategorizationAudit"; Detail="Would scan for uncategorized/catch-all items (post-recon gate)"},
        @{Order=10; Script="CategoryChecks"; Detail="Would run 5 rubric checks (post-recon)"},
        @{Order=11; Script="ReceiptVerification"; Detail="Would verify receipts: Zoho↔local sync, manifest update"},
        @{Order=12; Script="PreReconSummary"; Detail="Would generate pre-reconciliation summary report"}
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
    Write-Information "[PRP PIPELINE] WhatIf complete — pass -WhatIf to see dry-run output" -Tags PRP
    exit 0
}

# --- Step 0: Token Acquisition ---
$step0Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep0-TokenAcquisition.ps1" -Params @{
    OrgId   = $OrgId
    OrgName = $OrgName
} -Order 0
$stepResults += New-StepResult -StepResult $step0Result -Order 0 -ScriptName "TokenAcquisition"

if (-not $step0Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 0 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

$token = if ($step0Result -and $step0Result.Token) { $step0Result.Token } else { $null }
$headers = if ($step0Result -and $step0Result.Headers) { $step0Result.Headers } else { $null }

# If token was pre-provided or acquired, build headers
if ($token -and -not $headers) {
    $headers = New-PrivateHeaders -Token $token
}

# --- Bulk fetch (inline) ---
if ($token -and $OrgId -and $AccountId) {
    Write-Information "[PRP PIPELINE] Fetching bulk Zoho data for $AccountName..." -Tags PRP
    $fyStart = "2025-04-01"
    $fyEnd = "2026-03-31"

    try {
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

        $zohoAll = @($allTxns) + @($uncatTxns) + @($allExpenses)
        $globalState["ZohoAll"] = $zohoAll
        $globalState["UncatTxns"] = $uncatTxns
        $globalState["AllExpenses"] = $allExpenses
        Write-Information "[PRP PIPELINE] Fetched $($zohoAll.Count) total records" -Tags PRP
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

# --- Step 0.5b: CR+DR Duplicate Sweep ---
# Every POST /expenses creates two bank transactions (CREDIT + DEBIT) for the same
# date + amount. Sweep DEBITs from the local analysis set so Step 2 counts aren't 2×.
# Only sweeps when a credit has statement_imported source (Plaid feed) and the paired
# debit has no source (API-created duplicate) — avoids sweeping genuine CC payments.
$sweptCount = 0
if ($globalState["ZohoAll"] -and $globalState["ZohoAll"].Count -gt 0) {
    $sweptZohoAll = @()
    $drPairs = @{}
    # First pass: identify CR+DR pairs by (date, Abs(amount))
    foreach ($txn in $globalState["ZohoAll"]) {
        $pairKey = "$($txn.date)|$([math]::Abs([decimal]$txn.amount))"
        if (-not $drPairs.ContainsKey($pairKey)) {
            $drPairs[$pairKey] = @{ credits = @(); debits = @() }
        }
        $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
        if ($txnType -eq "credit") {
            $drPairs[$pairKey].credits += $txn
        } else {
            $drPairs[$pairKey].debits += $txn
        }
    }
    # Second pass: keep credits and unmatched/unsourced debits only
    foreach ($txn in $globalState["ZohoAll"]) {
        $pairKey = "$($txn.date)|$([math]::Abs([decimal]$txn.amount))"
        $txnType = if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { "credit" } else { "debit" }
        if ($txnType -eq "credit") {
            $sweptZohoAll += $txn
            continue
        }
        # Only sweep debit if it has NO source (API-created duplicate)
        # and the matching credit IS sourced from Plaid/statement import.
        $debitSrc = if ($txn.source) { $txn.source.Trim() } else { "" }
        $hasPlaidCredit = ($drPairs[$pairKey].credits | Where-Object { $_.source -match "statement_imported|feed_imported" }).Count -gt 0
        if ($hasPlaidCredit -and [string]::IsNullOrWhiteSpace($debitSrc)) {
            $sweptCount++
        } else {
            $sweptZohoAll += $txn
        }
    }
    $globalState["ZohoAll"] = $sweptZohoAll
    Write-Information "[PRP CR+DR SWEEP] Swept $sweptCount duplicate API-created DEBIT entries — $($globalState['ZohoAll'].Count) remaining" -Tags PRP
}

# --- Step 0.5: Plaid Detection ---
$step05Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep05-PlaidDetection.ps1" -Params @{
    ZohoAll = $globalState["ZohoAll"]
    Token   = $token
    Headers = $headers
    OrgId   = $OrgId
    AccountId = $AccountId
} -Order "0.5"
$stepResults += New-StepResult -StepResult $step05Result -Order "0.5" -ScriptName "PlaidDetection"

$isPlaidImmutable = if ($step05Result -and $step05Result.IsPlaidImmutable) { $true } else { $false }

if (-not $step05Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 0.5 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 1: Sidecar Verification ---
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

# --- Step 2: TAS Rebuild from Zoho (Temporary Working File) ---
$step2Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep2-TasRebuild.ps1" -Params @{
    ZohoAll         = $globalState["ZohoAll"]
    UncatTxns       = $globalState["UncatTxns"]
    AllExpenses     = $globalState["AllExpenses"]
    OrgName         = $OrgName
    AccountName     = $AccountName
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
} -Order 2
$stepResults += New-StepResult -StepResult $step2Result -Order 2 -ScriptName "TasRebuild"

$tasWorkingPath = if ($step2Result -and $step2Result.TasWorkingPath) { $step2Result.TasWorkingPath } else { $null }

if (-not $step2Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 2 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 3: Zoho Transaction Match ---
$step3Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep3-ZohoMatch.ps1" -Params @{
    ZohoAll         = $globalState["ZohoAll"]
    SidecarData     = $sidecarData
    SidecarPeriods  = $sidecarPeriods
    TasWorkingPath  = $tasWorkingPath
    IsPlaidImmutable = $isPlaidImmutable
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
    ToleranceDays   = $tolDays
} -Order 3
$stepResults += New-StepResult -StepResult $step3Result -Order 3 -ScriptName "ZohoMatch"

if (-not $step3Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 3 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 4: Discover PDF Statements ---
$step4Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep4-DiscoverStatements.ps1" -Params @{
    OrgName        = $OrgName
    AccountName    = $AccountName
    SidecarPeriods = $sidecarPeriods
    Token          = $token
    Headers        = $headers
    OrgId          = $OrgId
    AccountId      = $AccountId
} -Order 4
$stepResults += New-StepResult -StepResult $step4Result -Order 4 -ScriptName "DiscoverStatements"

$discoveredPeriods = if ($step4Result -and $step4Result.DiscoveredPeriods) { $step4Result.DiscoveredPeriods } else { @() }
if ($discoveredPeriods.Count -eq 0 -and $sidecarPeriods.Count -gt 0) {
    Write-Warning "[PRP PIPELINE] Step 4 found no PDFs — falling back to sidecar-derived periods"
    $discoveredPeriods = $sidecarPeriods
}

if (-not $step4Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 4 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 5: Period / Fiscal Year Selection ---
$step5Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep5-SelectPeriod.ps1" -Params @{
    DiscoveredPeriods = $discoveredPeriods
    OrgName           = $OrgName
    AccountName       = $AccountName
    Token             = $token
    Headers           = $headers
    OrgId             = $OrgId
    AccountId         = $AccountId
    FiscalYear        = $FiscalYear
    PeriodEnd         = $PeriodEnd
} -Order 5
$stepResults += New-StepResult -StepResult $step5Result -Order 5 -ScriptName "SelectPeriod"

$selectedScope = if ($step5Result -and $step5Result.SelectedScope) { $step5Result.SelectedScope } else { $null }
$activePeriods = if ($selectedScope -and $selectedScope.periods) { $selectedScope.periods } else { $discoveredPeriods }

if (-not $step5Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 5 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 6: Audit Warning Scan ---
$step6Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep6-AuditWarnings.ps1" -Params @{
    ZohoAll         = $globalState["ZohoAll"]
    AllExpenses     = $globalState["AllExpenses"]
    IsPlaidImmutable = $isPlaidImmutable
    EntityName      = $OrgName
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
} -Order 6
$stepResults += New-StepResult -StepResult $step6Result -Order 6 -ScriptName "AuditWarnings"

if (-not $step6Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 6 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 7: Balance Forward Verification (recon-troubleshoot) ---
$step7Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep7-BalanceForward.ps1" -Params @{
    TasWorkingPath   = $tasWorkingPath
    ZohoAll          = $globalState["ZohoAll"]
    DiscoveredPeriods = $discoveredPeriods
    ActivePeriods    = $activePeriods
    Token            = $token
    Headers          = $headers
    OrgId            = $OrgId
    AccountId        = $AccountId
    AmountTolerance  = $tolDays
} -Order 7
$stepResults += New-StepResult -StepResult $step7Result -Order 7 -ScriptName "BalanceForward"

if (-not $step7Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 7 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 8: Hybrid Reconciliation ---
$latestPeriod = $activePeriods | Sort-Object end -Descending | Select-Object -First 1
$step8PeriodEnd = if ($latestPeriod) { $latestPeriod.end.ToString('yyyy-MM-dd') } else { $null }
$step8ClosingBalance = if ($latestPeriod) { $latestPeriod.closing_balance } else { $null }

$step8Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep8-Reconcile.ps1" -Params @{
    AccountId        = $AccountId
    AccountName      = $AccountName
    PeriodEnd        = $step8PeriodEnd
    ClosingBalance   = $step8ClosingBalance
    IsPlaidImmutable = $isPlaidImmutable
    Token            = $token
    Headers          = $headers
    OrgId            = $OrgId
    OrgName          = $OrgName
    ActivePeriods    = $activePeriods
} -Order 8
$stepResults += New-StepResult -StepResult $step8Result -Order 8 -ScriptName "Reconcile"

if (-not $step8Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 8 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 9: Categorization Audit (Post-Recon Quality Gate) ---
$step9Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep9-CategorizationAudit.ps1" -Params @{
    ZohoAll         = $globalState["ZohoAll"]
    UncatTxns       = $globalState["UncatTxns"]
    AllExpenses     = $globalState["AllExpenses"]
    IsPlaidImmutable = $isPlaidImmutable
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
} -Order 9
$stepResults += New-StepResult -StepResult $step9Result -Order 9 -ScriptName "CategorizationAudit"

if (-not $step9Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 9 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 10: Category Reasonableness Checks (Post-Recon) ---
$step10Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep10-CategoryChecks.ps1" -Params @{
    ZohoAll         = $globalState["ZohoAll"]
    AllExpenses     = $globalState["AllExpenses"]
    IsPlaidImmutable = $isPlaidImmutable
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
} -Order 10
$stepResults += New-StepResult -StepResult $step10Result -Order 10 -ScriptName "CategoryChecks"

if (-not $step10Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 10 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 11: Receipt Verification ---
$step11Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep11-ReceiptVerification.ps1" -Params @{
    OrgName         = $OrgName
    AccountName     = $AccountName
    AllExpenses     = $globalState["AllExpenses"]
    ZohoAll         = $globalState["ZohoAll"]
    Token           = $token
    Headers         = $headers
    OrgId           = $OrgId
    AccountId       = $AccountId
    IsPlaidImmutable = $isPlaidImmutable
} -Order 11
$stepResults += New-StepResult -StepResult $step11Result -Order 11 -ScriptName "ReceiptVerification"

if (-not $step11Result.Passed -and -not $ContinueOnError) {
    Write-Error "[PRP PIPELINE] Step 11 failed — aborting pipeline"
    Write-SummaryTable -Results $stepResults
    Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName
    exit 1
}

# --- Step 12: Pre-Reconciliation Summary (always runs) ---
$step12Result = Invoke-PrpStep -ScriptName "Invoke-PrpStep12-PreReconSummary.ps1" -Params @{
    DiscoveredPeriods     = $discoveredPeriods
    ActivePeriods         = $activePeriods
    SelectedScope         = $selectedScope
    BalanceForwardResult  = $step7Result
    ReconciliationResult  = $step8Result
    AuditWarningsResult   = $step6Result
    OrgName               = $OrgName
    AccountName           = $AccountName
    ZohoAll               = $globalState["ZohoAll"]
    Token                 = $token
    Headers               = $headers
    OrgId                 = $OrgId
    AccountId             = $AccountId
} -Order 12
$stepResults += New-StepResult -StepResult $step12Result -Order 12 -ScriptName "PreReconSummary"

# --- Post-step: Update status (non-fatal side effect) ---
$statusPeriodEnd = $step8PeriodEnd
try {
    & (Join-Path $scriptDir "Invoke-StatusCheck.ps1") -Organization $OrgName -SetReconciliationDate $statusPeriodEnd -Source AgentGenerated -ErrorAction Stop
    Write-Information "[PRP PIPELINE] Status updated to $statusPeriodEnd" -Tags PRP
} catch {
    Write-Warning "[PRP PIPELINE] Status update failed (non-fatal): $_"
}

$allPassed = ($stepResults | Where-Object { -not $_.Passed }).Count -eq 0

# --- Final output ---
Write-Progress -Activity "PRP Pipeline" -Status "Complete" -PercentComplete 100
Write-SummaryTable -Results $stepResults
Save-EvidenceFile -Results $stepResults -AccountName $AccountName -OrgName $OrgName | Out-Null

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
