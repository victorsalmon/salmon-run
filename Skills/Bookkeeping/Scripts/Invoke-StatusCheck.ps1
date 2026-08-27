<#
.SYNOPSIS
    Checks org bookkeeping status.
#>

<#
.SYNOPSIS
    Checks organization bookkeeping status.
.PARAMETER Organization
    Organization name: intersite-consulting or room-rentals.
.PARAMETER Account
    Account slug for single-account scoping.
.PARAMETER Rebuild
    Switch to re-export Zoho, rebuild TAS, recompute status.
.EXAMPLE
    .\Invoke-StatusCheck.ps1 -Organization intersite-consulting
.EXAMPLE
    .\Invoke-StatusCheck.ps1 -Organization room-rentals -Rebuild
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Update')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Display')]
    [ValidateSet('intersite-consulting', 'room-rentals')]
    [string]$Organization,

    [Parameter(ParameterSetName = 'Update')]
    [string]$Account,

    [Parameter(ParameterSetName = 'Update')]
    [string]$SetReconciliationDate,

    [Parameter(ParameterSetName = 'Update')]
    [string]$SetLocalReconciliationDate,

    [Parameter(ParameterSetName = 'Update')]
    [string]$SetCloudReconciliationDate,

    [Parameter(ParameterSetName = 'Update')]
    [string]$SetReconciliationPeriod,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateSet('UserGenerated', 'AgentGenerated', 'Verified')]
    [string]$Source = 'AgentGenerated',

    [Parameter(ParameterSetName = 'Update')]
    [switch]$Rebuild,

    [switch]$PassThru,

    [Parameter(ParameterSetName = 'Display')]
    [switch]$Display
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path "$scriptDir\..\..\.."
$booksRoot = "C:\Repos\intersite-docs\Taxes and Bookkeeping\$Organization"
$statusPath = "$booksRoot\$Organization-status.json"

. (Join-Path $scriptDir "shared" "Get-EntityConfig.ps1")

function Build-OrgDef {
    param([string]$OrgSlug)
    $entityCfg = (Get-EntityConfig -Entity $OrgSlug).Entity
    $acctDefs = $entityCfg.bank_statement_accounts
    $booksBase = "C:\Repos\intersite-docs\Taxes and Bookkeeping\$OrgSlug"
    $fiscalYear = if ($entityCfg.fiscal_year) { $entityCfg.fiscal_year } else { Get-Date -Format 'yyyy' }
    $tasDir = if ($OrgSlug -eq 'room-rentals') { "$booksBase\$fiscalYear Bank Statements" } else { "$booksBase\$fiscalYear Filing\$fiscalYear Bank Statements" }
    $manifestPath = if ($OrgSlug -eq 'room-rentals') { "$booksBase\$fiscalYear Receipts\manifest-enriched.csv" } else { "$booksBase\$fiscalYear Filing\Receipts\_manifest.csv" }
    $tasPath = "$booksBase\TAS-$fiscalYear.csv"

    $accounts = $acctDefs | ForEach-Object {
        @{
            slug            = $_.slug
            zohoAccount     = $_.zoho_account
            label           = $_.label
            folder          = $_.folder
            raw             = $_.raw_csv
            rawDateColumn   = $_.raw_date_column
            zohoGlob        = $_.zoho_glob
            tasLabel        = $_.tas_label
            manifestAccount = $_.manifest_account
        }
    }

    return @{
        org          = $OrgSlug
        tasDir       = $tasDir
        manifestPath = $manifestPath
        bankDir      = @{ }
        accounts     = $accounts
        tasPath      = $tasPath
    }
}

$orgDefs = @{
    'intersite-consulting' = Build-OrgDef 'intersite-consulting'
    'room-rentals'         = Build-OrgDef 'room-rentals'
}

$def = $orgDefs[$Organization]
$defaultExempt = Get-ExemptCategories -Entity $Organization

function Parse-DateFlexible {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'Parse-DateFlexible', Justification='Parse semantics not expressible with approved verbs')]
    param([string]$DateStr)
    if ([string]::IsNullOrWhiteSpace($DateStr)) { return $null }
    $d = $DateStr.Trim()
    $result = [datetime]::MinValue
    if ([datetime]::TryParseExact($d, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParseExact($d, 'M/d/yyyy', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParseExact($d, 'yyyy-M-d', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    if ([datetime]::TryParse($d, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$result)) { return $result }
    return $null
}

function Read-SourceDateRange {
    param([string]$FilePath, [string]$DateColumn, [string]$DateFormat)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $raw = Get-Content $FilePath -Raw -Encoding utf8
        $filteredLines = ($raw -split "`n" | Where-Object { $_ -notmatch '^\s*#' })
        if (-not $filteredLines -or $filteredLines.Count -eq 0) { return $null }
        $rows = ($filteredLines -join "`n") | ConvertFrom-Csv
        $dates = @()
        foreach ($r in $rows) {
            $raw = $r.$DateColumn
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $parsed = Parse-DateFlexible $raw
            if ($parsed) { $dates += $parsed }
        }
        if ($dates.Count -eq 0) { return $null }
        return @{
            min_date = ($dates | Sort-Object | Select-Object -First 1)
            max_date = ($dates | Sort-Object -Descending | Select-Object -First 1)
            count    = $dates.Count
        }
    } catch {
        Write-Warning "  Could not read $FilePath : $_"
        return $null
    }
}

function Compute-TransactionCompleteDate {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'Compute-TransactionCompleteDate', Justification='Compute semantics not expressible with approved verbs')]
    param([array]$AccountSources)
    $sources = @()
    foreach ($s in $AccountSources) {
        if ($s.range) {
            $sources += [PSCustomObject]@{
                min_date = $s.range.min_date
                max_date = $s.range.max_date
                label    = $s.label
            }
        }
    }
    if ($sources.Count -eq 0) { return $null }
    $sorted = $sources | Sort-Object min_date
    $lastComplete = $sorted[0].max_date
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $gapStart = $lastComplete.AddDays(1)
        if ($sorted[$i].min_date -gt $gapStart) {
            return $lastComplete.ToString('yyyy-MM-dd')
        }
        if ($sorted[$i].max_date -gt $lastComplete) {
            $lastComplete = $sorted[$i].max_date
        }
    }
    return $lastComplete.ToString('yyyy-MM-dd')
}

function Read-TasByAccount {
    param([string]$TasPath, [int]$AccountIndex)
    if (-not (Test-Path $TasPath)) { return $null }
    try {
        $raw = Get-Content $TasPath -Raw -Encoding utf8
        $filteredLines = ($raw -split "`n" | Where-Object { $_ -notmatch '^\s*#' })
        if (-not $filteredLines -or $filteredLines.Count -eq 0) { return $null }
        $rows = ($filteredLines -join "`n") | ConvertFrom-Csv
        $byAccount = @{}
        foreach ($r in $rows) {
            $ba = $r.bank_account
            if ([string]::IsNullOrWhiteSpace($ba)) { continue }
            if (-not $byAccount.ContainsKey($ba)) { $byAccount[$ba] = @() }
            $byAccount[$ba] += $r
        }
        return $byAccount
    } catch {
        Write-Warning "  Could not read TAS: $_"
        return $null
    }
}

# 
# Pre-Period Exemption Rule — Receipt Complete Date
# 
# Transactions dated BEFORE active_period_start are automatically considered
# receipt-complete.  They belong to a prior accounting period whose receipt
# completeness is outside the scope of the current period's check.  The
# continuity chain starts cleanly at the period boundary — no pre-period
# transaction can break it.
# 
# This is a blanket exemption by date range, separate from the category-based
# exemptions in $exempt_categories.  Both cloud (Zoho-sourced) and local
# receipt calculations apply this rule.
# 
function Compute-ReceiptCompleteDate {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'Compute-ReceiptCompleteDate', Justification='Compute semantics not expressible with approved verbs')]
    param([array]$TasRows, [array]$ExemptCategories, [string]$SourceFilter, [string]$ActivePeriodStart)
    if (-not $TasRows -or $TasRows.Count -eq 0) { return $null }
    $filtered = if ($SourceFilter) {
        $TasRows | Where-Object { $_.source -match $SourceFilter }
    } else { $TasRows }
    if ($filtered.Count -eq 0) { return $null }
    $periodStart = if ($ActivePeriodStart) { Parse-DateFlexible $ActivePeriodStart } else { $null }
    $inPeriod = if ($periodStart) {
        $filtered | Where-Object { $periodStart -le (Parse-DateFlexible $_.date) }
    } else { $filtered }
    if ($inPeriod.Count -eq 0) { return $null }
    $sorted = $inPeriod | Sort-Object { Parse-DateFlexible $_.date }
    $lastClean = $null
    foreach ($r in $sorted) {
        $dt = Parse-DateFlexible $r.date
        if (-not $dt) { continue }
        $hasReceipt = -not [string]::IsNullOrWhiteSpace($r.receipt_filename)
        $hasCloudReceipt = -not [string]::IsNullOrWhiteSpace($r.zoho_has_receipt)
        $receiptOk = $hasReceipt -or $hasCloudReceipt
        $isTasExempt = -not [string]::IsNullOrWhiteSpace($r.receipt_exempt)
        $isExempt = $ExemptCategories -contains $r.category
        $parsedAmt = [decimal]0
        $amtOk = $null -ne $r.amount -and [decimal]::TryParse($r.amount, [ref]$parsedAmt)
        $isCredit = $amtOk -and $parsedAmt -gt 0
        if ($receiptOk -or $isTasExempt -or $isExempt -or $isCredit) {
            $lastClean = $dt
        } else {
            break
        }
    }
    if (-not $lastClean) { return $null }
    return $lastClean.ToString('yyyy-MM-dd')
}

function Read-ManifestCoveredDates {
    param(
        [string]$ManifestPath,
        [string]$AccountFilter
    )
    if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) { return $null }
    try {
        $rows = Import-Csv $ManifestPath
    } catch {
        Write-Warning "  Could not read manifest $ManifestPath : $_"
        return $null
    }
    if (-not $rows -or $rows.Count -eq 0) { return @{} }
    $covered = @{}
    foreach ($row in $rows) {
        if ($AccountFilter -and $row.account -ne $AccountFilter) { continue }
        if ([string]::IsNullOrWhiteSpace($row.date)) { continue }
        if ([string]::IsNullOrWhiteSpace($row.amount)) { continue }
        $dt = Parse-DateFlexible $row.date
        if ($dt) { $covered[$dt.ToString('yyyy-MM-dd')] = $true }
    }
    return $covered
}

# 
# Pre-Period Exemption Rule — Receipt Complete Date (Manifest variant)
# See Compute-ReceiptCompleteDate for the full rule.  Same logic applies:
# transactions before active_period_start are automatically receipt-complete.
# 
function Compute-ReceiptCompleteDateFromManifest {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'Compute-ReceiptCompleteDateFromManifest', Justification='Compute semantics not expressible with approved verbs')]
    param(
        [string]$ManifestPath,
        [string]$AccountFilter,
        [array]$TasRows,
        [array]$ExemptCategories,
        [string]$ActivePeriodStart
    )
    if (-not $TasRows -or $TasRows.Count -eq 0) { return $null }
    $covered = Read-ManifestCoveredDates -ManifestPath $ManifestPath -AccountFilter $AccountFilter
    if (-not $covered -or $covered.Count -eq 0) { return $null }
    $periodStart = if ($ActivePeriodStart) { Parse-DateFlexible $ActivePeriodStart } else { $null }
    $inPeriod = if ($periodStart) {
        $TasRows | Where-Object { $periodStart -le (Parse-DateFlexible $_.date) }
    } else { $TasRows }
    if ($inPeriod.Count -eq 0) { return $null }
    $sorted = $inPeriod | Sort-Object { Parse-DateFlexible $_.date }
    $lastClean = $null
    foreach ($r in $sorted) {
        $dt = Parse-DateFlexible $r.date
        if (-not $dt) { continue }
        $dateStr = $dt.ToString('yyyy-MM-dd')
        $isTasExempt = -not [string]::IsNullOrWhiteSpace($r.receipt_exempt)
        $isExempt = $ExemptCategories -contains $r.category
        $inTas = -not [string]::IsNullOrWhiteSpace($r.receipt_filename)
        $inManifest = $covered.ContainsKey($dateStr)
        $hasCloudReceipt = -not [string]::IsNullOrWhiteSpace($r.zoho_has_receipt)
        $hasReceipt = $inTas -or $inManifest -or $hasCloudReceipt
        $parsedAmt = [decimal]0
        $amtOk = $null -ne $r.amount -and [decimal]::TryParse($r.amount, [ref]$parsedAmt)
        $isCredit = $amtOk -and $parsedAmt -gt 0
        if ($hasReceipt -or $isTasExempt -or $isExempt -or $isCredit) {
            $lastClean = $dt
        } else {
            break
        }
    }
    if (-not $lastClean) { return $null }
    return $lastClean.ToString('yyyy-MM-dd')
}

function Min-DateString {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'Min-DateString', Justification='Min semantics not expressible with approved verbs')]
    param($A, $B)
    if (-not $A) { return $B }
    if (-not $B) { return $A }
    $da = Parse-DateFlexible $A
    $db = Parse-DateFlexible $B
    if (-not $da) { return $B }
    if (-not $db) { return $A }
    if ($da -lt $db) { return $A } else { return $B }
}

function Read-EmailCheckFile {
    param([string]$OrgRoot)
    $ecf = Join-Path $OrgRoot "email-last-checked.json"
    if (-not (Test-Path $ecf)) { return $null }
    try {
        $raw = Get-Content $ecf -Raw -Encoding utf8
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Format-StatusDate {
    param([object]$DateValue)
    if (-not $DateValue) { return "- none -" }
    return [string]$DateValue
}

function Write-StatusTable {
    param([object]$Data)
    $orgSlug = $Data.organization
    $booksRootTmp = "C:\Repos\intersite-docs\Taxes and Bookkeeping\$orgSlug"
    $emailCheck = Read-EmailCheckFile $booksRootTmp

    Write-Host "=== $orgSlug ===  Updated: $($Data.updated_at)" -ForegroundColor Cyan

    $acctProps = $Data.accounts.PSObject.Properties

    # -- Table 1: Transactions & Receipts --
    Write-Host "`n  --- Transactions & Receipts ---" -ForegroundColor Gray
    $rows1 = @()
    foreach ($p in $acctProps) {
        $a = $p.Value
        $label = if ($a.label) { $a.label } else { $p.Name }
        $cTx = if ($a.cloud_transaction_complete_date) { $a.cloud_transaction_complete_date.date } else { "-" }
        $lTx = if ($a.local_transaction_complete_date) { $a.local_transaction_complete_date.date } else { "-" }
        $cRc = if ($a.cloud_receipt_complete_date) { $a.cloud_receipt_complete_date.date } else { "-" }
        $lRc = if ($a.local_receipt_complete_date) { $a.local_receipt_complete_date.date } else { "-" }
        $rows1 += [PSCustomObject]@{ Label = $label; TxCld = $cTx; TxLoc = $lTx; RcCld = $cRc; RcLoc = $lRc }
    }
    $padL = 34; $padD = 12
    $hdr1 = "  " + "Account".PadRight($padL) + "Tx-Cld".PadRight($padD) + "Tx-Loc".PadRight($padD) + "Rc-Cld".PadRight($padD) + "Rc-Loc".PadRight($padD)
    Write-Host $hdr1 -ForegroundColor DarkGray
    Write-Host ("  " + "-" * ($hdr1.Length - 2)) -ForegroundColor DarkGray
    foreach ($r in $rows1) {
        Write-Host ("  " + $r.Label.PadRight($padL) + $r.TxCld.PadRight($padD) + $r.TxLoc.PadRight($padD) + $r.RcCld.PadRight($padD) + $r.RcLoc.PadRight($padD)) -ForegroundColor White
    }
    Write-Host ("    Cloud txns: " + (Format-StatusDate $Data.cloud_transaction_complete_date) + "  Local txns: " + (Format-StatusDate $Data.local_transaction_complete_date)) -ForegroundColor Green
    Write-Host ("    Cloud receipts: " + (Format-StatusDate $Data.cloud_receipt_complete_date) + "  Local receipts: " + (Format-StatusDate $Data.local_receipt_complete_date)) -ForegroundColor Green
    Write-Host "    Period start: $($Data.active_period_start)" -ForegroundColor Gray

    # -- Table 2: Reconciliation --
    $reconTs = if ($Data.reconciliation_updated_at) { $Data.reconciliation_updated_at } else { "" }
    Write-Host ("`n  --- Reconciliation ---" + $(if ($reconTs) { " (updated: $reconTs)" } else { "" })) -ForegroundColor Gray
    $periods = if ($Data.reconciliation_periods) { @($Data.reconciliation_periods) } else { @() }
    if ($periods.Count -gt 0) {
        $padA = 34; $padP = 24; $padS = 14
        $hdr2 = "  " + "Account".PadRight($padA) + "Period".PadRight($padP) + "Local".PadRight($padS) + "Cloud".PadRight($padS)
        Write-Host $hdr2 -ForegroundColor DarkGray
        Write-Host ("  " + "-" * ($hdr2.Length - 2)) -ForegroundColor DarkGray
        foreach ($per in $periods) {
            $acctLabel = $per.account_label
            if (-not $acctLabel) {
                $acctDef = $orgDefs[$orgSlug].accounts | Where-Object { $_.slug -eq $per.account_slug }
                $acctLabel = if ($acctDef) { $acctDef.label } else { $per.account_slug }
            }
            $periodLabel = if ($per.period_label) { $per.period_label } else { "$($per.period_start) to $($per.period_end)" }
            $locColor = if ($per.local_status -eq "done") { "Green" } elseif ($per.local_status -eq "blocked") { "Red" } else { "Yellow" }
            $cldColor = if ($per.cloud_status -eq "done") { "Green" } elseif ($per.cloud_status -eq "blocked") { "Red" } else { "Yellow" }
            $locDisp = if ($per.local_status) { $per.local_status } else { "-" }
            $cldDisp = if ($per.cloud_status) { $per.cloud_status } else { "-" }
            Write-Host ("  " + $acctLabel.PadRight($padA) + $periodLabel.PadRight($padP)) -NoNewline -ForegroundColor White
            Write-Host $locDisp.PadRight($padS) -NoNewline -ForegroundColor $locColor
            Write-Host $cldDisp.PadRight($padS) -ForegroundColor $cldColor
        }
        $doneCount = ($periods | Where-Object { $_.local_status -eq "done" -and $_.cloud_status -eq "done" }).Count
        Write-Host ("    Periods: $($periods.Count) total, $doneCount fully reconciled") -ForegroundColor $(
            if ($periods.Count -eq $doneCount) { "Green" } else { "Yellow" }
        )
    } else {
        Write-Host "  (no reconciliation periods recorded)" -ForegroundColor Yellow
    }

    # -- Latest PRP report --
    $prpReportsDir = Join-Path $booksRootTmp "PRP Reports"
    if (Test-Path $prpReportsDir) {
        $latestReport = Get-ChildItem "$prpReportsDir\*reconciliation-report*.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestReport) {
            Write-Host "`n  --- Latest PRP Report ---" -ForegroundColor Gray
            $reportName = $latestReport.Name
            Write-Host "    $reportName" -ForegroundColor White
            Write-Host "    Last updated: $($latestReport.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor White
            Write-Host "    Path: $($latestReport.FullName)" -ForegroundColor DarkGray
        }
    }
    Write-Host "  Run the PRP pipeline per account to generate reconciliation reports: Invoke-PrpAcctPipeline.ps1" -ForegroundColor DarkGray

    # -- Email last check --
    if ($emailCheck) {
        Write-Host "`n  --- Email ---" -ForegroundColor Gray
        Write-Host ("    Checked: " + $emailCheck.checked_at + "  Mailbox: " + $emailCheck.mailbox) -ForegroundColor White
    }
}

function Test-AccountPreReconReady {
    param([PSCustomObject]$Account)
    $cloudTx = if ($Account.cloud_transaction_complete_date) { $Account.cloud_transaction_complete_date.date } else { $null }
    $localTx = if ($Account.local_transaction_complete_date) { $Account.local_transaction_complete_date.date } else { $null }
    $cloudRc = if ($Account.cloud_receipt_complete_date) { $Account.cloud_receipt_complete_date.date } else { $null }
    $localRc = if ($Account.local_receipt_complete_date) { $Account.local_receipt_complete_date.date } else { $null }
    $recon   = if ($Account.reconciliation_date) { $Account.reconciliation_date.date } else { $null }

    if (-not $recon) { return @{ready = $false; blocker = "no reconciliation date" } }

    $today = (Get-Date).Date
    $threshold = 30

    # 1. Categories/Transactions: both cloud and local must be current (within 30 days)
    [datetime]$cloudDt = $null; [datetime]$localDt = $null
    $cloudOk = $cloudTx -and [datetime]::TryParse($cloudTx, [ref]$cloudDt)
    $localOk = $localTx -and [datetime]::TryParse($localTx, [ref]$localDt)
    $txCurrent = $cloudOk -and $localOk -and ($today - $cloudDt).Days -le $threshold -and ($today - $localDt).Days -le $threshold
    if (-not $txCurrent) {
        $blocker = "transactions not current: cloud=$cloudTx local=$localTx"
        return @{ready = $false; blocker = $blocker }
    }

    # 2. Receipts: both cloud and local must be current (within 30 days)
    [datetime]$cloudRcDt = $null; [datetime]$localRcDt = $null
    $cloudRcOk = $cloudRc -and [datetime]::TryParse($cloudRc, [ref]$cloudRcDt)
    $localRcOk = $localRc -and [datetime]::TryParse($localRc, [ref]$localRcDt)
    $rcCurrent = $cloudRcOk -and $localRcOk -and ($today - $cloudRcDt).Days -le $threshold -and ($today - $localRcDt).Days -le $threshold
    if (-not $rcCurrent) {
        $blocker = "receipts not current: cloud=$cloudRc local=$localRc"
        return @{ready = $false; blocker = $blocker }
    }

    # 3. Reconciliation must be behind (at least 25 days) — meaning there's a period ready to reconcile
    [datetime]$reconDt = $null
    $reconBehind = $recon -and [datetime]::TryParse($recon, [ref]$reconDt) -and ($today - $reconDt).Days -ge 25
    if (-not $reconBehind) {
        return @{ready = $false; blocker = "reconciliation is up to date ($recon), no periods waiting" }
    }

    # All 6 dimensions pass
    return @{ready = $true; blocker = $null }
}

function Write-StatusFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Status)
    if (-not $PSCmdlet.ShouldProcess($statusPath, "Write status file")) { return }
    $json = $Status | ConvertTo-Json -Depth 10
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($statusPath, $json, $utf8NoBom)
    Write-Host "  Status written: $statusPath" -ForegroundColor Green
    try {
        $validated = Get-Content -Raw $statusPath -Encoding utf8 | ConvertFrom-Json
        if (-not $validated.transaction_complete_date -and -not $validated.cloud_transaction_complete_date) {
            Write-Warning "Status file validation: missing transaction_complete_date (may be OK for partial update)"
        }
        Write-Host "  Status validation: OK ($($validated.PSObject.Properties.Name.Count) properties)" -ForegroundColor Green
    } catch {
        Write-Error "Status file validation FAILED: $_"
        return $false
    }
}

function Read-StatusFile {
    if (Test-Path $statusPath) {
        try {
            $raw = Get-Content $statusPath -Raw -Encoding utf8
            return ($raw | ConvertFrom-Json)
        } catch {
            Write-Warning "  Could not read existing status file: $_"
        }
    }
    return $null
}

# ── Rebuild mode ─────────────────────────────────────────────────
if ($Rebuild) {
    if (-not $PSCmdlet.ShouldProcess("$Organization", "Full rebuild (export + TAS regeneration)")) { return }
    Write-Host "=== Rebuild: Export Zoho transactions ===" -ForegroundColor Cyan
    $containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}"
    if (-not $containerId) {
        Write-Error "Bookkeeping container not running -- cannot rebuild"
        exit 1
    }
    $token = docker exec $containerId cat /run/secrets/fleet_api_token 2>$null
    if (-not $token) {
        Write-Error "Could not get Bookkeeper API token"
        exit 1
    }
    $body = @{dry_run = $false; entity = $Organization} | ConvertTo-Json
    $exportResult = Invoke-RestMethod -Uri "http://localhost:21008/zoho/transactions/export" -Method POST `
        -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
        -Body $body
    if (-not $exportResult.success) {
        Write-Error "Export failed: $($exportResult | ConvertTo-Json)"
        exit 1
    }
    Write-Host "  Exported $($exportResult.total_transactions) transactions across $($exportResult.total_accounts) accounts" -ForegroundColor Green

    foreach ($a in $exportResult.accounts) {
        $acctDef = $def.accounts | Where-Object { $_.zohoAccount -eq $a.account }
        if (-not $acctDef) {
            Write-Warning "  No mapping for account '$($a.label)' -- skipping copy"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($a.csvFile)) {
            Write-Host "  $($a.label): no CSV generated (0 transactions or dry run)" -ForegroundColor Yellow
            continue
        }
        $src = "${containerId}:/app/zoho-transactions/$Organization/$($a.csvFile)"
        $acctDir = "$($def.tasDir)\$($acctDef.folder)"
        if (-not (Test-Path $acctDir)) { New-Item -ItemType Directory -Path $acctDir -Force | Out-Null }
        $zohoPrefix = if ($Organization -eq 'intersite-consulting') { '2026.06.15-Present' } else { '2026.06.11-Present' }
        $dstName = "$zohoPrefix - $($acctDef.label) - Zoho.csv"
        $dst = "$acctDir\$dstName"
        docker cp $src $dst | Out-Null
        Write-Host "  Copied $($a.csvFile) -> $($acctDef.folder)\$dstName" -ForegroundColor Green
    }

    Write-Host "=== Rebuild: Regenerate TAS ===" -ForegroundColor Cyan
    if ($Organization -eq 'intersite-consulting') {
        & "$repoRoot\Skills\Bookkeeping\Scripts\reconciliation\Build-IntersiteTAS.ps1"
    } else {
        & "$repoRoot\Skills\Bookkeeping\Scripts\reconciliation\Build-TAS.ps1"
    }
}

# ── Load existing status ─────────────────────────────────────────
$existingStatus = Read-StatusFile
if ($existingStatus) {
    $exempt = if ($existingStatus.exempt_categories) { @($existingStatus.exempt_categories) } else { $defaultExempt }
    $existingAccounts = @{}
    if ($existingStatus.accounts) {
        $props = $existingStatus.accounts.PSObject.Properties
        foreach ($p in $props) { $existingAccounts[$p.Name] = $p.Value }
    }
} else {
    $exempt = $defaultExempt
    $existingAccounts = @{}
}

# ── Display mode ── (read and show existing status without recomputation)
if ($Display) {
    $orgsToShow = if ($Organization) { @($Organization) } else { @('intersite-consulting', 'room-rentals') }
    $allData = @()
    foreach ($org in $orgsToShow) {
        $booksRootTmp = "C:\Repos\intersite-docs\Taxes and Bookkeeping\$org"
        $sp = "$booksRootTmp\$org-status.json"
        if (Test-Path $sp) {
            $d = Get-Content $sp -Raw -Encoding utf8 | ConvertFrom-Json
            # Backward compat: migrate old merged transaction_complete_date to cloud+local
            if (-not $d.cloud_transaction_complete_date -and $d.transaction_complete_date) {
                $d | Add-Member -NotePropertyName 'cloud_transaction_complete_date' -NotePropertyValue $d.transaction_complete_date -Force
                $d | Add-Member -NotePropertyName 'local_transaction_complete_date' -NotePropertyValue $d.transaction_complete_date -Force
            }
            if ($d.accounts) {
                foreach ($acctProp in $d.accounts.PSObject.Properties) {
                    $a = $acctProp.Value
                    if (-not $a.cloud_transaction_complete_date -and $a.transaction_complete_date) {
                        $a | Add-Member -NotePropertyName 'cloud_transaction_complete_date' -NotePropertyValue $a.transaction_complete_date -Force
                        $a | Add-Member -NotePropertyName 'local_transaction_complete_date' -NotePropertyValue $a.transaction_complete_date -Force
                    }
                }
            }
            $allData += $d
        } else {
            Write-Host "=== $org ===" -ForegroundColor Cyan
            Write-Host "  (no status file)" -ForegroundColor Yellow
        }
    }
    if ($allData.Count -eq 0) {
        Write-Host "No status files found." -ForegroundColor Yellow
        if ($PassThru) { return $null }
        exit 0
    }
    foreach ($d in $allData) { Write-StatusTable $d; Write-Host "" }
    if ($PassThru) { return $allData }
    exit 0
}

$activeAccounts = if ($Account) { $def.accounts | Where-Object { $_.slug -eq $Account } } else { $def.accounts }
if (-not $activeAccounts -or $activeAccounts.Count -eq 0) {
    Write-Error "Account '$Account' not found in $Organization"
    exit 1
}

$activePeriodStart = if ($Organization -eq 'intersite-consulting') { '2025-04-01' } else { '2026-01-01' }

# ── Compute dates per account ────────────────────────────────────
$accountResults = @{}
foreach ($acct in $activeAccounts) {
    Write-Host "Processing $($acct.label)..." -ForegroundColor Cyan
    $acctDir = "$($def.tasDir)\$($acct.folder)"
    $acctSlug = $acct.slug

    # -- Transaction Complete Date --
    $sources = @()
    $rawPath = "$acctDir\$($acct.raw)"
    $rawDateCol = if ($acct.rawDateColumn) { $acct.rawDateColumn } else { 'Transaction Date' }
    $rawRange = Read-SourceDateRange -FilePath $rawPath -DateColumn $rawDateCol
    if ($rawRange) {
        $sources += @{ label = 'raw'; range = $rawRange }
        Write-Host "  Raw: $($rawRange.min_date.ToString('yyyy-MM-dd')) to $($rawRange.max_date.ToString('yyyy-MM-dd')) ($($rawRange.count) txns)" -ForegroundColor DarkGray
    }

    $zohoFiles = Get-ChildItem -Path $acctDir -Filter $acct.zohoGlob | Sort-Object LastWriteTime -Descending
    $zohoRange = $null
    if ($zohoFiles) {
        $zohoPath = $zohoFiles[0].FullName
        $zohoRange = Read-SourceDateRange -FilePath $zohoPath -DateColumn 'date' -DateFormat 'yyyy-MM-dd'
        if ($zohoRange) {
            $sources += @{ label = 'zoho'; range = $zohoRange }
            Write-Host "  Zoho: $($zohoRange.min_date.ToString('yyyy-MM-dd')) to $($zohoRange.max_date.ToString('yyyy-MM-dd')) ($($zohoRange.count) txns)" -ForegroundColor DarkGray
        }
    }

    $cloudSources = @($sources | Where-Object { $_.label -eq 'zoho' })
    $rawSources = @($sources | Where-Object { $_.label -eq 'raw' })
    $cloudTxDate = Compute-TransactionCompleteDate $cloudSources
    # Local: raw covers fiscal year (through Mar 31), Zoho covers current period.
    # These are NOT expected to be continuous — compute independently, take max.
    $rawTxDate = Compute-TransactionCompleteDate $rawSources
    $zohoTxDate = Compute-TransactionCompleteDate $cloudSources
    $localTxDate = if ($rawTxDate -and $zohoTxDate) {
        $d1 = [datetime]::Parse($rawTxDate); $d2 = [datetime]::Parse($zohoTxDate)
        if ($d1 -gt $d2) { $rawTxDate } else { $zohoTxDate }
    } elseif ($rawTxDate) { $rawTxDate } elseif ($zohoTxDate) { $zohoTxDate } else { $null }
    if ($cloudTxDate) {
        Write-Host "  Cloud (Zoho) Transaction Complete: $cloudTxDate" -ForegroundColor Green
    } else {
        Write-Host "  Cloud (Zoho) Transaction Complete: (no data)" -ForegroundColor Yellow
    }
    if ($localTxDate) {
        Write-Host "  Local Transaction Complete (raw+Zoho): $localTxDate" -ForegroundColor Green
    } else {
        Write-Host "  Local Transaction Complete: (no data)" -ForegroundColor Yellow
    }

    # -- Receipt Complete Date --
    $tasByAcct = if (Test-Path $def.tasPath) { Read-TasByAccount $def.tasPath } else { $null }
    $tasLabel = $acct.tasLabel
    $acctTasRows = if ($tasByAcct -and $tasByAcct.ContainsKey($tasLabel)) { $tasByAcct[$tasLabel] } else { $null }

    $cloudReceiptDateTas = Compute-ReceiptCompleteDate -TasRows $acctTasRows -ExemptCategories $exempt -ActivePeriodStart $activePeriodStart
    $localReceiptDateTas = Compute-ReceiptCompleteDate -TasRows $acctTasRows -ExemptCategories $exempt -ActivePeriodStart $activePeriodStart
    $manifestReceiptDate = Compute-ReceiptCompleteDateFromManifest -ManifestPath $def.manifestPath -AccountFilter $acct.manifestAccount -TasRows $acctTasRows -ExemptCategories $exempt -ActivePeriodStart $activePeriodStart
    $cloudReceiptDate = Min-DateString $cloudReceiptDateTas $manifestReceiptDate
    $localReceiptDate = Min-DateString $localReceiptDateTas $manifestReceiptDate
    $manifestUsed = $null -ne $manifestReceiptDate
    if ($cloudReceiptDate) {
        Write-Host "  Receipt Complete (cloud): $cloudReceiptDate" -ForegroundColor Green
    } else {
        Write-Host "  Receipt Complete (cloud): (no data or incomplete)" -ForegroundColor Yellow
    }
    if ($localReceiptDate) {
        Write-Host "  Receipt Complete (local): $localReceiptDate" -ForegroundColor Green
    } else {
        Write-Host "  Receipt Complete (local): (no data or incomplete)" -ForegroundColor Yellow
    }
    if ($manifestUsed) {
        Write-Host "    (manifest-derived receipt date: $manifestReceiptDate)" -ForegroundColor DarkGray
    }

    # -- Merge with existing account data --
    $existingAcct = $existingAccounts[$acctSlug]
    $existingRecon = if ($existingAcct -and $existingAcct.reconciliation_date) {
        if ($existingAcct.reconciliation_date.date) { $existingAcct.reconciliation_date.date } else { $existingAcct.reconciliation_date }
    } else { $null }
    $existingReconSrc = if ($existingAcct -and $existingAcct.reconciliation_date -and $existingAcct.reconciliation_date.source) {
        $existingAcct.reconciliation_date.source
    } else { $null }

    $reconDate = $existingRecon
    $reconSource = $existingReconSrc
    if ($SetReconciliationDate) {
        $reconDate = $SetReconciliationDate
        $reconSource = $Source
        Write-Host "  Reconciliation: $reconDate ($reconSource)" -ForegroundColor Green
    }

    $existingLocalRecon = if ($existingAcct -and $existingAcct.local_reconciliation_date) {
        if ($existingAcct.local_reconciliation_date.date) { $existingAcct.local_reconciliation_date.date } else { $existingAcct.local_reconciliation_date }
    } else { $null }
    $existingLocalReconSrc = if ($existingAcct -and $existingAcct.local_reconciliation_date -and $existingAcct.local_reconciliation_date.source) {
        $existingAcct.local_reconciliation_date.source
    } else { $null }

    $existingCloudRecon = if ($existingAcct -and $existingAcct.cloud_reconciliation_date) {
        if ($existingAcct.cloud_reconciliation_date.date) { $existingAcct.cloud_reconciliation_date.date } else { $existingAcct.cloud_reconciliation_date }
    } else { $null }
    $existingCloudReconSrc = if ($existingAcct -and $existingAcct.cloud_reconciliation_date -and $existingAcct.cloud_reconciliation_date.source) {
        $existingAcct.cloud_reconciliation_date.source
    } else { $null }

    $localReconDate = $existingLocalRecon
    $localReconSource = $existingLocalReconSrc
    $cloudReconDate = $existingCloudRecon
    $cloudReconSource = $existingCloudReconSrc

    if ($SetLocalReconciliationDate) {
        $localReconDate = $SetLocalReconciliationDate
        $localReconSource = $Source
        Write-Host "  Local Recon (PRP-to-PDF): $localReconDate ($localReconSource)" -ForegroundColor Green
    }
    if ($SetCloudReconciliationDate) {
        $cloudReconDate = $SetCloudReconciliationDate
        $cloudReconSource = $Source
        Write-Host "  Cloud Recon (Zoho): $cloudReconDate ($cloudReconSource)" -ForegroundColor Green
    }

    $acctResult = [ordered]@{
        label      = $acct.label
        updated_at = (Get-Date).ToString('o')
    }
    if ($cloudTxDate) {
        $acctResult['cloud_transaction_complete_date'] = [ordered]@{ date = $cloudTxDate; source = 'AgentGenerated' }
    }
    if ($localTxDate) {
        $acctResult['local_transaction_complete_date'] = [ordered]@{ date = $localTxDate; source = 'AgentGenerated' }
    }
    if ($cloudReceiptDate) {
        $rcSrc = if ($manifestUsed -and $cloudReceiptDate -eq $manifestReceiptDate -and $cloudReceiptDate -lt $cloudReceiptDateTas) { 'Manifest+TAS' } elseif ($manifestUsed -and $cloudReceiptDate -eq $manifestReceiptDate) { 'Manifest' } else { 'AgentGenerated' }
        $acctResult['cloud_receipt_complete_date'] = [ordered]@{ date = $cloudReceiptDate; source = $rcSrc }
    }
    if ($localReceiptDate) {
        $rcSrc2 = if ($manifestUsed -and $localReceiptDate -eq $manifestReceiptDate -and $localReceiptDate -lt $localReceiptDateTas) { 'Manifest+TAS' } elseif ($manifestUsed -and $localReceiptDate -eq $manifestReceiptDate) { 'Manifest' } else { 'AgentGenerated' }
        $acctResult['local_receipt_complete_date'] = [ordered]@{ date = $localReceiptDate; source = $rcSrc2 }
    }
    if ($reconDate) {
        $acctResult['reconciliation_date'] = [ordered]@{ date = $reconDate; source = $reconSource }
    }
    if ($localReconDate) {
        $acctResult['local_reconciliation_date'] = [ordered]@{ date = $localReconDate; source = $localReconSource }
    }
    if ($cloudReconDate) {
        $acctResult['cloud_reconciliation_date'] = [ordered]@{ date = $cloudReconDate; source = $cloudReconSource }
    }
    # Reconciliation date threshold rule: A date > same-day-of-month of the prior month
    # is considered current. Dates at/before that threshold flag as needing attention.
    # This is a display-policy rule, not enforced here — the consumer evaluates it.
    $accountResults[$acctSlug] = $acctResult
}

# ── Build full status object ─────────────────────────────────────
$status = [ordered]@{
    organization       = $Organization
    updated_at         = (Get-Date).ToString('o')
    updated_by         = 'Invoke-StatusCheck.ps1'
    active_period_start = $activePeriodStart
    exempt_categories  = @($exempt)
}

if ($existingStatus) {
    # Preserve org-level dates from existing if we're doing partial update
    if ($existingStatus.cloud_receipt_complete_date) { $status.cloud_receipt_complete_date = $existingStatus.cloud_receipt_complete_date }
    if ($existingStatus.local_receipt_complete_date) { $status.local_receipt_complete_date = $existingStatus.local_receipt_complete_date }
    if ($existingStatus.receipt_complete_date) { $status.receipt_complete_date = $existingStatus.receipt_complete_date }
    if ($existingStatus.cloud_transaction_complete_date) { $status.cloud_transaction_complete_date = $existingStatus.cloud_transaction_complete_date }
    if ($existingStatus.local_transaction_complete_date) { $status.local_transaction_complete_date = $existingStatus.local_transaction_complete_date }
    if ($existingStatus.reconciliation_date) { $status.reconciliation_date = $existingStatus.reconciliation_date }
    if ($existingStatus.local_reconciliation_date) { $status.local_reconciliation_date = $existingStatus.local_reconciliation_date }
    if ($existingStatus.cloud_reconciliation_date) { $status.cloud_reconciliation_date = $existingStatus.cloud_reconciliation_date }
}

# Merge with any accounts not processed (partial update)
$allAccounts = @{}
if ($existingStatus -and $existingStatus.accounts) {
    $props = $existingStatus.accounts.PSObject.Properties
    foreach ($p in $props) { $allAccounts[$p.Name] = $p.Value }
}
foreach ($kv in $accountResults.GetEnumerator()) {
    $allAccounts[$kv.Key] = $kv.Value
}
# Ensure accounts appear in slug order
$orderedAccounts = [ordered]@{}
foreach ($acct in $def.accounts) {
    if ($allAccounts.ContainsKey($acct.slug)) { $orderedAccounts[$acct.slug] = $allAccounts[$acct.slug] }
}

# Compute org-level rollup from all accounts
$cloudTxDates = @()
$localTxDates = @()
$cloudRcDates = @()
$localRcDates = @()
$rcDates = @()
$reconDates = @()
$localReconDates = @()
$cloudReconDates = @()
foreach ($kv in $orderedAccounts.GetEnumerator()) {
    $a = $kv.Value
    if ($a.cloud_transaction_complete_date -and $a.cloud_transaction_complete_date.date) { $cloudTxDates += [datetime]::Parse($a.cloud_transaction_complete_date.date) }
    if ($a.local_transaction_complete_date -and $a.local_transaction_complete_date.date) { $localTxDates += [datetime]::Parse($a.local_transaction_complete_date.date) }
    if ($a.cloud_receipt_complete_date -and $a.cloud_receipt_complete_date.date) { $cloudRcDates += [datetime]::Parse($a.cloud_receipt_complete_date.date) }
    if ($a.local_receipt_complete_date -and $a.local_receipt_complete_date.date) { $localRcDates += [datetime]::Parse($a.local_receipt_complete_date.date) }
    if ($a.receipt_complete_date -and $a.receipt_complete_date.date) { $rcDates += [datetime]::Parse($a.receipt_complete_date.date) }
    if ($a.reconciliation_date -and $a.reconciliation_date.date) { $reconDates += [datetime]::Parse($a.reconciliation_date.date) }
    if ($a.local_reconciliation_date -and $a.local_reconciliation_date.date) { $localReconDates += [datetime]::Parse($a.local_reconciliation_date.date) }
    if ($a.cloud_reconciliation_date -and $a.cloud_reconciliation_date.date) { $cloudReconDates += [datetime]::Parse($a.cloud_reconciliation_date.date) }
}
$status['accounts'] = $orderedAccounts
if ($cloudTxDates.Count -gt 0) { $status['cloud_transaction_complete_date'] = ($cloudTxDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($localTxDates.Count -gt 0) { $status['local_transaction_complete_date'] = ($localTxDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($cloudRcDates.Count -gt 0) { $status['cloud_receipt_complete_date'] = ($cloudRcDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($localRcDates.Count -gt 0) { $status['local_receipt_complete_date'] = ($localRcDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($rcDates.Count -gt 0) { $status['receipt_complete_date'] = ($rcDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($reconDates.Count -gt 0) { $status['reconciliation_date'] = ($reconDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($localReconDates.Count -gt 0) { $status['local_reconciliation_date'] = ($localReconDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }
if ($cloudReconDates.Count -gt 0) { $status['cloud_reconciliation_date'] = ($cloudReconDates | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd') }

# ── Read email-last-checked companion file ──────────────────────
$emailCheckData = Read-EmailCheckFile $booksRoot
if ($emailCheckData) {
    $status['email_last_check'] = [ordered]@{
        checked_at = $emailCheckData.checked_at
        mailbox    = if ($emailCheckData.mailbox) { $emailCheckData.mailbox } else { "" }
        checked_by = if ($emailCheckData.checked_by) { $emailCheckData.checked_by } else { "" }
    }
}

# ── Latest PRP report ─────────────────────────────────────────────
$prpReportsDir = Join-Path $booksRoot "PRP Reports"
$latestPrp = $null
if (Test-Path $prpReportsDir) {
    $latestPrpFile = Get-ChildItem "$prpReportsDir\*reconciliation-report*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestPrpFile) {
        $latestPrp = @{
            report_path = $latestPrpFile.FullName
            report_name = $latestPrpFile.Name
            updated_at  = $latestPrpFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        }
    }
}
if ($latestPrp) { $status['latest_prp_report'] = $latestPrp }

# ── Write status file ────────────────────────────────────────────
Write-StatusFile $status
Write-Host "=== Status: Step 1 (Opening)  Step 2 (Reconcile)  Step 3 (Categorize)  Step 4 (Upload Receipts) ===" -ForegroundColor Cyan
Write-Host "Opening Balances: set?=$($status.opening_balances_set)" -ForegroundColor Cyan
Write-Host "Reconciliation:  local=$($status.local_reconciliation_date)  cloud=$($status.cloud_reconciliation_date)  combined=$($status.reconciliation_date)" -ForegroundColor Cyan
Write-Host "PRP Reports:     $(if ($latestPrp) { $latestPrp.report_name + ' (' + $latestPrp.updated_at + ')' } else { 'none — run PRP pipeline' })" -ForegroundColor Cyan
Write-Host "Categorization:  cloud=$($status.cloud_transaction_complete_date)  local=$($status.local_transaction_complete_date)" -ForegroundColor Cyan
Write-Host "Receipt Upload:  cloud=$($status.cloud_receipt_complete_date)  local=$($status.local_receipt_complete_date)  email=$($emailCheckData.checked_at)" -ForegroundColor Cyan

if ($PassThru) { return $status }
