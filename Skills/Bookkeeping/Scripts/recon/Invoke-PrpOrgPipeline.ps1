<#
.SYNOPSIS
    PRP Org Pipeline Orchestrator — runs per-account pipeline for all accounts in an org.
.DESCRIPTION
    Loads the org's PRP config, iterates over all accounts (or a filtered subset),
    calls Invoke-PrpAcctPipeline.ps1 for each, collects results, runs cross-account
    transfer matching, and generates a consolidated org-level reconciliation report.
    Use -Phase to control which phases run (defaults to FullPipeline for monthly updates).
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER Accounts
    Optional subset of account keys to process (e.g. @("RBC-INTERSITE", "MC-6258")).
    Matches against section_header_prefix in config.
.PARAMETER Phase
    Named phase to pass to per-account pipeline. Defaults to "FullPipeline".
.PARAMETER ContinueOnError
    Continue processing remaining accounts even if one fails.
.PARAMETER ResumeFrom
    Account label/prefix to resume from (skip earlier accounts).
.PARAMETER WhatIf
    Dry-run: show what would be processed without executing.
.EXAMPLE
    .\Invoke-PrpOrgPipeline.ps1 -OrgName "room-rentals"
    .\Invoke-PrpOrgPipeline.ps1 -OrgName "intersite-consulting" -Accounts @("RBC-INTERSITE", "MC-6258")
    .\Invoke-PrpOrgPipeline.ps1 -OrgName "room-rentals" -Phase Reconciliation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [string[]]$Accounts,

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
$pipelineStart = Get-Date
$orgResults = @()

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
    Write-Warning "[PRP ORG] -Platform Container was requested but $reason — falling back to Host mode"
    $Platform = 'Host'
}

# Load PRP config
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
if (-not $prpCfg) {
    Write-Error "[PRP ORG] Failed to load config for org '$OrgName'"
    exit 1
}

$orgZohoId = $prpCfg.org.zoho_org_id
Write-Information "[PRP ORG] Org config loaded: $OrgName (zoho_org_id: $orgZohoId)" -Tags PRP

# Determine account list: get config keys, then filter by -Accounts if provided
$allConfigKeys = $prpCfg.accounts.PSObject.Properties.Name
$allAccountConfigs = $allConfigKeys | ForEach-Object { $cfg = $prpCfg.accounts.$_; $cfg | Add-Member -NotePropertyName "_configKey" -NotePropertyValue $_ -Force -PassThru }

$accountConfigs = $allAccountConfigs
if ($Accounts -and $Accounts.Count -gt 0) {
    $accountConfigs = $allAccountConfigs | Where-Object { $_.section_header_prefix -in $Accounts -or $_.label -in $Accounts -or $_.zoho_account_id -in $Accounts }
    if (-not $accountConfigs -or $accountConfigs.Count -eq 0) {
        Write-Error "[PRP ORG] No matching accounts found for filter: $($Accounts -join ', ')"
        exit 1
    }
}

Write-Information "[PRP ORG] Starting org pipeline for $OrgName — $($accountConfigs.Count) accounts" -Tags PRP

# Filter by ResumeFrom
if ($ResumeFrom) {
    $resumeFound = $false
    $accountConfigs = $accountConfigs | Where-Object {
        if ($resumeFound) { $true }
        elseif ($_.section_header_prefix -eq $ResumeFrom -or $_.label -eq $ResumeFrom) { $resumeFound = $true; $true }
        else { $false }
    }
    Write-Information "[PRP ORG] Resuming from '$ResumeFrom' — $($accountConfigs.Count) remaining accounts" -Tags PRP
}

# --- Inline paginated fetch helper for cross-account matching ---
function Invoke-OrgZohoFetch {
    param([string]$BaseUri, [hashtable]$Headers, [string]$ResultKey)
    $allResults = @(); $page = 1; $pageSize = 200
    do {
        $uri = "$BaseUri&per_page=$pageSize&page=$page"
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $Headers
            Start-Sleep -Milliseconds 350
            $items = $response.$ResultKey
            if ($items -and $items.Count -gt 0) { $allResults += $items }
            $hasMore = if ($response.page_context) { $response.page_context.has_more_page } else { ($items -and $items.Count -eq $pageSize) }
            $page++
        } catch {
            Write-Warning "[PRP ORG FETCH] Page $page fetch failed: $_"
            break
        }
    } while ($hasMore -and $page -le 50)
    Write-Information "[PRP ORG FETCH] Fetched $($allResults.Count) $ResultKey across $($page-1) page(s)" -Tags PRP
    return $allResults
}

# --- Per-account pipeline loop ---
$acctIndex = 0
foreach ($acctCfg in $accountConfigs) {
    $acctIndex++
    $acctKey = $acctCfg._configKey
    $acctName = $acctCfg.label
    $acctId = $acctCfg.zoho_account_id

    Write-Information "[PRP ORG] [$acctIndex/$($accountConfigs.Count)] Processing account: $acctName" -Tags PRP

    if ($WhatIfPreference) {
        $orgResults += [PSCustomObject]@{
            AccountName   = $acctName
            AccountKey    = $acctKey
            AccountId     = $acctId
            OverallStatus = "PASS"
            StepResults   = @()
            EvidencePath  = $null
            ReportPath    = $null
            Detail        = "WhatIf: would run pipeline for $acctName (account_id: $acctId)"
        }
        $phaseArg = if ($Phase) { " -Phase `"$Phase`"" } else { "" }
        $modeArg = if ($DetectOnly) { " -DetectOnly" } elseif (-not $Remediate) { " -Remediate:`$false" } else { "" }
        $platformArg = " -Platform $Platform"
        Write-Information "[PRP ORG]   WhatIf: Invoke-PrpAcctPipeline.ps1 -AccountName `"$acctKey`" -OrgName `"$OrgName`" -OrgId `"$orgZohoId`" -AccountId `"$acctId`"$phaseArg$modeArg$platformArg" -Tags PRP
        continue
    }

    $pipelinePath = Join-Path $scriptDir "Invoke-PrpAcctPipeline.ps1"
    if (-not (Test-Path $pipelinePath)) {
        Write-Warning "[PRP ORG] Pipeline script not found: $pipelinePath — skipping $acctName"
        $orgResults += [PSCustomObject]@{
            AccountName   = $acctName
            AccountKey    = $acctKey
            AccountId     = $acctId
            OverallStatus = "FAIL"
            Detail        = "Pipeline script not found"
        }
        continue
    }

    try {
        $acctPhase = if ($Phase) { $Phase } else { "FullPipeline" }
        $modeLabel = if ($DetectOnly) { "detect-only" } elseif ($Remediate) { "remediate (two-pass)" } else { "detect-only (no remediate)" }
        Write-Information "[PRP ORG]   Calling: Invoke-PrpAcctPipeline.ps1 -AccountName $acctKey -OrgName $OrgName -Phase $acctPhase ($modeLabel)" -Tags PRP
        $coerceFlag = if ($ContinueOnError) { @{ContinueOnError = $true} } else { @{} }
        $output = & $pipelinePath -AccountName $acctKey -OrgName $OrgName -OrgId $orgZohoId -AccountId $acctId -Phase $acctPhase -Remediate:$Remediate -DetectOnly:$DetectOnly -Platform $Platform @coerceFlag 2>&1
        $exitCode = $LASTEXITCODE
        $acctPassed = $exitCode -eq 0

        $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
        $prpReportsDir = Join-Path $booksRoot "PRP Reports"
        $evidencePath = $null; $reportPath = $null
        if (Test-Path $prpReportsDir) {
            $evidenceFile = Get-ChildItem -Path $prpReportsDir -Filter "prp-$OrgName-$acctKey-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($evidenceFile) { $evidencePath = $evidenceFile.FullName }
            $reportFile = Get-ChildItem -Path $prpReportsDir -Filter "$OrgName-$acctKey-reconciliation-report-*.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($reportFile) { $reportPath = $reportFile.FullName }
        }

        $orgResults += [PSCustomObject]@{
            AccountName   = $acctName
            AccountKey    = $acctKey
            AccountId     = $acctId
            OverallStatus = if ($acctPassed) { "PASS" } else { "FAIL" }
            StepResults   = $null
            EvidencePath  = $evidencePath
            ReportPath    = $reportPath
            Detail        = if ($acctPassed) { "All steps passed" } else { "Pipeline exited with code $exitCode" }
        }

        Write-Information "[PRP ORG]   Account $acctName — $(if ($acctPassed) { 'PASS' } else { 'FAIL' })" -Tags PRP

        if (-not $acctPassed -and -not $ContinueOnError) {
            Write-Error "[PRP ORG] Account $acctName failed and -ContinueOnError not set — aborting"
            break
        }
    } catch {
        Write-Warning "[PRP ORG] Exception processing ${acctName}: $_"
        $orgResults += [PSCustomObject]@{
            AccountName   = $acctName
            AccountKey    = $acctKey
            AccountId     = $acctId
            OverallStatus = "FAIL"
            Detail        = "Exception: $_"
        }
        if (-not $ContinueOnError) {
            Write-Error "[PRP ORG] Exception on $acctName and -ContinueOnError not set — aborting"
            break
        }
    }
}

# Load evidence for Step 2 period results
$step2Periods = @{}
$accountZohoData = @{}
foreach ($r in $orgResults) {
    if ($r.EvidencePath -and (Test-Path $r.EvidencePath)) {
        try {
            $ev = Get-Content $r.EvidencePath -Raw | ConvertFrom-Json
            foreach ($step in $ev.steps) {
                if ($step.script -eq "ZohoMatch" -and $step.result -and $step.result.PeriodResults) {
                    $step2Periods[$r.AccountKey] = @{
                        PeriodResults = $step.result.PeriodResults
                        Passed        = $step.passed
                    }
                }
            }
        } catch {
            Write-Warning "[PRP ORG] Could not load evidence for $($r.AccountKey): $_"
        }
    }
}

# --- Cross-account transfer matching ---
$crossAccountTransfers = @()
$completedAccounts = $orgResults | Where-Object { $_.OverallStatus -ne "FAIL" -or $ContinueOnError }
if ($completedAccounts.Count -ge 2) {
    $accountPairs = @()
    $keys = $completedAccounts | ForEach-Object { $_ }
    for ($i = 0; $i -lt $keys.Count; $i++) {
        for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            $accountPairs += @{ A = $keys[$i]; B = $keys[$j] }
        }
    }

    Write-Information "[PRP ORG] Cross-account transfer matching for $($accountPairs.Count) pairs..." -Tags PRP

    # Acquire Zoho token once for all pairs
    $token = $null; $headers = $null

    if ($Platform -eq 'Container') {
        try {
            $cid = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
            if (-not $cid) {
                Write-Warning "[PRP ORG] Container FRAD_is-bookkeeping not running"
            } else {
                $fleetTok = (docker exec $cid cat /run/secrets/fleet_api_token 2>$null | ForEach-Object { $_.Trim() })
                $tokResponse = docker exec $cid curl -s -H "Authorization: Bearer $fleetTok" http://localhost:21008/zoho/token 2>$null
                if ($tokResponse) {
                    $tokJson = $tokResponse | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($tokJson -and $tokJson.access_token) {
                        $token = $tokJson.access_token
                        $headers = @{ Authorization = "Zoho-oauthtoken $token"; "Content-Type" = "application/json" }
                        Write-Information "[PRP ORG] Container token acquired for cross-account matching" -Tags PRP
                    }
                }
                if (-not $token) {
                    Write-Warning "[PRP ORG] Container token endpoint returned no access_token"
                }
            }
        } catch {
            Write-Warning "[PRP ORG] Container token acquisition failed for cross-account matching: $_"
        }
    } else {
        $step0Script = Join-Path $scriptDir "Invoke-PrpStep0-TokenAcquisition.ps1"
        if (Test-Path $step0Script) {
            try {
                $tokResult = & $step0Script -OrgId $orgZohoId -OrgName $OrgName
                if ($tokResult -and $tokResult.Token) {
                    $token = $tokResult.Token
                    $headers = @{ Authorization = "Zoho-oauthtoken $token"; "Content-Type" = "application/json" }
                }
            } catch {
                Write-Warning "[PRP ORG] Token acquisition failed for cross-account matching: $_"
            }
        }
    }

    if ($token -and $headers) {
        # Load Find-CrossAccountTransfers from Step 2
        . (Join-Path $scriptDir "Invoke-PrpStep2-ZohoMatch.ps1")

        $fyStart = $prpCfg.org.fiscal_year_start
        $fyEnd = $prpCfg.org.fiscal_year_end

        foreach ($pair in $accountPairs) {
            $acctA = $pair.A
            $acctB = $pair.B

            # Fetch Zoho banktransactions for both accounts
            $baseUriA = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$($acctA.AccountId)&organization_id=$orgZohoId&date_range_start=$fyStart&date_range_end=$fyEnd"
            $baseUriB = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$($acctB.AccountId)&organization_id=$orgZohoId&date_range_start=$fyStart&date_range_end=$fyEnd"

            $txnsA = Invoke-OrgZohoFetch -BaseUri $baseUriA -Headers $headers -ResultKey "banktransactions"
            $txnsB = Invoke-OrgZohoFetch -BaseUri $baseUriB -Headers $headers -ResultKey "banktransactions"

            if ($txnsA.Count -eq 0 -or $txnsB.Count -eq 0) {
                Write-Information "[PRP ORG]   Skipping pair $($acctA.AccountName) ↔ $($acctB.AccountName): insufficient data" -Tags PRP
                continue
            }

            $matches = Find-CrossAccountTransfers -AccountATxns $txnsA -AccountBTxns $txnsB -AccountALabel $acctA.AccountName -AccountBLabel $acctB.AccountName -AmountTolerance 0.50 -DateToleranceDays 3
            $crossAccountTransfers += $matches
            Write-Information "[PRP ORG]   $($acctA.AccountName) ↔ $($acctB.AccountName): $($matches.Count) transfer pair(s) found" -Tags PRP
        }
    } else {
        Write-Warning "[PRP ORG] Cannot run cross-account matching: no valid Zoho token"
    }
} elseif ($WhatIfPreference) {
    Write-Information "[PRP ORG] WhatIf: would run cross-account transfer matching for account pairs" -Tags PRP
}

# --- Generate consolidated org report ---
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"
$prpReportsDir = Join-Path $booksRoot "PRP Reports"
$null = New-Item -ItemType Directory -Path $prpReportsDir -Force

$totalAccounts = $orgResults.Count
$passedAccounts = ($orgResults | Where-Object { $_.OverallStatus -eq "PASS" }).Count
$failedAccounts = ($orgResults | Where-Object { $_.OverallStatus -eq "FAIL" }).Count
$overallPass = $failedAccounts -eq 0

if ($WhatIfPreference) {
    Write-Information "[PRP ORG] WhatIf: would generate consolidated report at $prpReportsDir\$OrgName-org-reconciliation-report-$ts.md" -Tags PRP
    Write-Information "[PRP ORG] WhatIf: would generate JSON summary at $prpReportsDir\$OrgName-org-reconciliation-summary-$ts.json" -Tags PRP
} else {
    $reportPath = Join-Path $prpReportsDir "$OrgName-org-reconciliation-report-$ts.md"
    $reportLines = @(
        "# Org Reconciliation Report: $OrgName",
        "",
        "## Executive Summary",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        "| Overall Status | $(if ($overallPass) { 'PASS' } else { 'FAIL' }) |",
        "| Pipeline run | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |",
        "| Mode | $(if ($DetectOnly) { 'Detect-Only' } elseif ($Remediate) { 'Remediate (two-pass)' } else { 'Detect-Only' }) |",
        "| Accounts passed | $passedAccounts / $totalAccounts |",
        "",
        "## Per-Account Results",
        "",
        "| Account | Status | Detail |",
        "|---------|--------|--------|"
    )

    foreach ($r in $orgResults) {
        $reportLines += "| $($r.AccountName) ($($r.AccountKey)) | $($r.OverallStatus) | $($r.Detail) |"
    }

    $reportLines += ""
    $reportLines += "## Per-Period Detail"
    $reportLines += ""
    $reportLines += "| Account | Period | Sidecar | Zoho | Diff | Status |"
    $reportLines += "|---------|--------|---------|------|------|--------|"

    $hasPeriodData = $false
    foreach ($r in $orgResults) {
        if ($step2Periods.ContainsKey($r.AccountKey)) {
            $sp = $step2Periods[$r.AccountKey]
            if ($sp.PeriodResults) {
                foreach ($periodLabel in ($sp.PeriodResults.PSObject.Properties.Name | Sort-Object)) {
                    $pr = $sp.PeriodResults.$periodLabel
                    $pStatus = if ($pr.Passed) { "PASS" } else { "FAIL" }
                    $reportLines += "| $($r.AccountName) | $periodLabel | $($pr.SidecarCount) | $($pr.ZohoCount) | $($pr.Diff) | $pStatus |"
                    $hasPeriodData = $true
                }
            }
        }
    }
    if (-not $hasPeriodData) {
        $reportLines += "| - | - | - | - | - | No period-level data available |"
    }

    $reportLines += ""
    $reportLines += "## Cross-Account Transfers"
    $reportLines += ""

    if ($crossAccountTransfers.Count -gt 0) {
        $reportLines += "| Debit Account | Credit Account | Amount | Date Range | Confidence | Description |"
        $reportLines += "|---------------|----------------|--------|------------|------------|-------------|"
        foreach ($match in $crossAccountTransfers) {
            $desc = if ($match.Description) { $match.Description } else { "—" }
            $reportLines += "| $($match.DebitAccount) | $($match.CreditAccount) | `$$([math]::Round($match.Amount, 2)) | $($match.DateRange) | $($match.Confidence) | $desc |"
        }
    } else {
        $reportLines += "No cross-account transfer pairs detected."
    }

    $reportLines += ""
    $reportLines += "## Step Failures"
    $reportLines += ""
    $reportLines += "| Account | Failed Steps | Details |"
    $reportLines += "|---------|--------------|---------|"

    $hasFailures = $false
    foreach ($r in $orgResults) {
        if ($r.EvidencePath -and (Test-Path $r.EvidencePath)) {
            try {
                $ev = Get-Content $r.EvidencePath -Raw | ConvertFrom-Json
                $failedSteps = $ev.steps | Where-Object { -not $_.passed }
                if ($failedSteps.Count -gt 0) {
                    $hasFailures = $true
                    foreach ($fs in $failedSteps) {
                        $reportLines += "| $($r.AccountName) | Step $($fs.script) | $($fs.details) |"
                    }
                }
            } catch {}
        } elseif ($r.OverallStatus -eq "FAIL") {
            $hasFailures = $true
            $reportLines += "| $($r.AccountName) | — | $($r.Detail) |"
        }
    }
    if (-not $hasFailures) {
        $reportLines += "| — | — | No step failures across all accounts |"
    }

    $reportLines += ""
    $reportLines += "## Next Steps"
    $reportLines += ""

    if ($overallPass) {
        $reportLines += "All accounts reconciled successfully. Org is Recon Ready."
    } else {
        $reportLines += "The following accounts require attention:"
        $reportLines += ""
        foreach ($r in $orgResults | Where-Object { $_.OverallStatus -eq "FAIL" }) {
            $reportLines += "- **$($r.AccountName)**: $($r.Detail)"
            if ($r.EvidencePath) { $reportLines += "  - Evidence: $($r.EvidencePath)" }
        }
        $reportLines += ""
        $reportLines += "Re-run individual account pipelines with `-ContinueOnError` for detailed diagnostics."
    }

    $reportLines | Out-String | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Information "[PRP ORG] Consolidated report saved to $reportPath" -Tags PRP

    $jsonSummary = @{
        pipeline              = "prp-org"
        org                   = $OrgName
        org_zoho_id           = $orgZohoId
        run_timestamp         = (Get-Date).ToString('o')
        total_accounts        = $totalAccounts
        passed_accounts       = $passedAccounts
        failed_accounts       = $failedAccounts
        overall_status        = if ($overallPass) { "PASS" } else { "FAIL" }
        cross_account_transfer_pairs = $crossAccountTransfers.Count
        cross_account_transfers = $crossAccountTransfers | ForEach-Object {
            @{
                debit_account  = $_.DebitAccount
                credit_account = $_.CreditAccount
                amount         = [math]::Round($_.Amount, 2)
                debit_date     = if ($_.DebitDate) { $_.DebitDate } else { $null }
                credit_date    = if ($_.CreditDate) { $_.CreditDate } else { $null }
                date_range     = $_.DateRange
                confidence     = $_.Confidence
            }
        }
        accounts = $orgResults | ForEach-Object {
            @{
                name      = $_.AccountName
                key       = $_.AccountKey
                account_id = $_.AccountId
                status    = $_.OverallStatus
                detail    = $_.Detail
                evidence  = $_.EvidencePath
                report    = $_.ReportPath
            }
        }
    }

    $jsonPath = Join-Path $prpReportsDir "$OrgName-org-reconciliation-summary-$ts.json"
    $jsonSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    Write-Information "[PRP ORG] JSON summary saved to $jsonPath" -Tags PRP
}

# --- Org-level completion notification ---
$orgNotification = @{
    type              = "org_pipeline_complete"
    timestamp         = (Get-Date).ToString('o')
    domain            = "Bookkeeper"
    org               = $OrgName
    overall_status    = if ($overallPass) { "PASS" } else { "FAIL" }
    accounts_passed   = $passedAccounts
    accounts_total    = $totalAccounts
    accounts_failed   = $failedAccounts
    errors            = @(if (-not $overallPass) { ($orgResults | Where-Object { $_.OverallStatus -eq "FAIL" } | ForEach-Object { "$($_.AccountName): $($_.Detail)" }) } else { @() })
}
$workflowEventsDir = Join-Path (Split-Path -Parent $PSCommandPath) "..\..\..\..\Tasks\Logs"
if (-not (Test-Path $workflowEventsDir)) { $null = New-Item -ItemType Directory -Path $workflowEventsDir -Force }
$orgNotificationLine = $orgNotification | ConvertTo-Json -Compress
Add-Content -LiteralPath (Join-Path $workflowEventsDir "workflow-events.log") -Value $orgNotificationLine -Encoding utf8
Write-Information "[NOTIFICATION] Org pipeline completion logged to workflow-events.log" -Tags PRP

$elapsed = [math]::Round(((Get-Date) - $pipelineStart).TotalSeconds, 0)
Write-Information "[PRP ORG] Pipeline finished in ${elapsed}s — Overall: $(if ($overallPass) { 'PASS' } else { 'FAIL' })" -Tags PRP

if ($overallPass) { exit 0 } else { exit 1 }
