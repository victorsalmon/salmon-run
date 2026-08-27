# DEPRECATED — Superseded by Skills/Bookkeeping/Scripts/Invoke-StatusCheck.ps1
#
# Why: This script manually manages dates via -SetReceiptDate / -SetReconciliationDate
# parameters only. It has no auto-computation from source data (TAS CSVs), no
# transaction_complete_date, writes to a single combined status.json (not per-org),
# and uses different account slugs (e.g. 'rbc-corporate' vs 'RBC-INTERSITE').
#
# Replacement: Invoke-StatusCheck.ps1 auto-computes transaction_complete_date and
# receipt_complete_date from source CSVs and TAS, writes per-org {org}-status.json,
# supports -Rebuild mode, source tracking (AgentGenerated/UserGenerated/Verified),
# and per-account scoping. Both monthly update scripts call it as Step 4.
#
# https: //github.com/victorsalmon/intersite-orchestrator/blob/main/Skills/Bookkeeping/Scripts/Invoke-StatusCheck.ps1

<#
.SYNOPSIS
    [DEPRECATED] Manage and display bookkeeping status.
.DESCRIPTION
    DEPRECATED — Use Invoke-StatusCheck.ps1 instead.
    Old behavior: reads/writes status.json at ~/intersite-docs/Taxes and Bookkeeping/status.json.
    Tracks two date types per account:
      - receipt_complete_date:       last date all non-exempt receipts uploaded
      - reconciliation_complete_date: last date the account is reconciled
.PARAMETER Entity
    Organization to update: "intersite-consulting" or "room-rentals".
.PARAMETER Account
    Account ID within the entity. Valid values:
      intersite-consulting: rbc-corporate, mc-6258
      room-rentals:         td-mlm, scotia-tmh, rbc-fra
.PARAMETER SetReceiptDate
    Set receipt_complete_date for the given entity/account (ISO date string, e.g. "2026-05-31").
.PARAMETER SetReconciliationDate
    Set reconciliation_complete_date for the given entity/account (ISO date string).
.PARAMETER StatusFile
    Path to status.json. Default: ~/intersite-docs/Taxes and Bookkeeping/status.json
.EXAMPLE
    .\Invoke-BookkeepingStatusCheck.ps1
    Display current status for all organizations.
.EXAMPLE
    .\Invoke-BookkeepingStatusCheck.ps1 -Entity room-rentals -Account td-mlm -SetReceiptDate "2026-05-31"
    Set TD MLM receipt-complete to 2026-05-31 and recompute org aggregate.
#>
[CmdletBinding(DefaultParameterSetName = "Display")]
param(
    [Parameter(ParameterSetName = "Update")]
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity,

    [Parameter(ParameterSetName = "Update")]
    [string]$Account,

    [Parameter(ParameterSetName = "Update")]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$SetReceiptDate,

    [Parameter(ParameterSetName = "Update")]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$SetReconciliationDate,

    [string]$StatusFile = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\status.json"
)

$ErrorActionPreference = "Stop"

# Known account IDs per entity
$knownAccounts = @{
    "intersite-consulting" = @{
        "rbc-corporate" = "RBC Intersite Consulting Inc."
        "mc-6258"       = "MC 6258 (Credit Card)"
    }
    "room-rentals" = @{
        "td-mlm"    = "TD MLM (32870 George Ferguson Way, Abbotsford)"
        "scotia-tmh" = "Scotia TMH (31-3800 40th Avenue, Vernon)"
        "rbc-fra"   = "RBC FRA (Francis, Vernon)"
    }
}

function Get-StatusData {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "Status file not found at $Path -- initializing with default values"
        return $null
    }
    $raw = Get-Content $Path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json -AsHashtable
}

function Save-StatusData {
    param([hashtable]$Data, [string]$Path)
    $Data._metadata.last_updated = (Get-Date -Format "yyyy-MM-dd")
    $Data._metadata.updated_by = "Invoke-BookkeepingStatusCheck.ps1"
    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Write-StatusTable {
    param([hashtable]$Data)
    $orgs = $Data.organizations
    foreach ($orgKey in $orgs.Keys | Sort-Object) {
        $org = $orgs[$orgKey]
        Write-Host "`n=== $($org.display_name) ===" -ForegroundColor Cyan
        Write-Host ("  Receipt complete:       " + (Format-Date $org.receipt_complete_date)) -ForegroundColor $(if ($org.receipt_complete_date) { "Green" } else { "Yellow" })
        Write-Host ("  Reconciliation complete: " + (Format-Date $org.reconciliation_complete_date)) -ForegroundColor $(if ($org.reconciliation_complete_date) { "Green" } else { "Yellow" })

        Write-Host "  Accounts:" -ForegroundColor Gray
        foreach ($acctKey in $org.accounts.Keys | Sort-Object) {
            $acct = $org.accounts[$acctKey]
            Write-Host "    $acctKey ($($acct.display_name))" -ForegroundColor White
            Write-Host ("      Receipt complete:       " + (Format-Date $acct.receipt_complete_date)) -ForegroundColor $(if ($acct.receipt_complete_date) { "Green" } else { "Yellow" })
            Write-Host ("      Reconciliation complete: " + (Format-Date $acct.reconciliation_complete_date)) -ForegroundColor $(if ($acct.reconciliation_complete_date) { "Green" } else { "Yellow" })
        }
    }
}

function Format-Date {
    param([object]$DateValue)
    if (-not $DateValue) { return "- none -" }
    return [string]$DateValue
}

function Update-OrgAggregates {
    param([hashtable]$Org)
    $receiptDates = @()
    $reconDates = @()
    foreach ($acct in $Org.accounts.Values) {
        if ($acct.receipt_complete_date) { $receiptDates += [DateTime]$acct.receipt_complete_date }
        if ($acct.reconciliation_complete_date) { $reconDates += [DateTime]$acct.reconciliation_complete_date }
    }
    if ($receiptDates.Count -gt 0) {
        $Org.receipt_complete_date = ($receiptDates | Sort-Object | Select-Object -First 1).ToString("yyyy-MM-dd")
    } else {
        $Org.receipt_complete_date = $null
    }
    if ($reconDates.Count -gt 0) {
        $Org.reconciliation_complete_date = ($reconDates | Sort-Object | Select-Object -First 1).ToString("yyyy-MM-dd")
    } else {
        $Org.reconciliation_complete_date = $null
    }
}

# ----- Main -----

$data = Get-StatusData -Path $StatusFile

if ($PSCmdlet.ParameterSetName -eq "Display") {
    if (-not $data) {
        Write-Host "No status data available. Run with -Entity and -Account to set initial dates." -ForegroundColor Yellow
        exit
    }
    Write-StatusTable -Data $data
    exit
}

# Update mode
if (-not $data) {
    Write-Error "Status file not found. Run a bare display first to initialize."
    exit 1
}

if (-not $knownAccounts[$Entity]) {
    Write-Error "Unknown entity '$Entity'. Valid: intersite-consulting, room-rentals"
    exit 1
}

if (-not $knownAccounts[$Entity].ContainsKey($Account)) {
    $valid = ($knownAccounts[$Entity].Keys | ForEach-Object { "'$_'" }) -join ", "
    Write-Error "Unknown account '$Account' for entity '$Entity'. Valid: $valid"
    exit 1
}

if (-not $SetReceiptDate -and -not $SetReconciliationDate) {
    Write-Error "Specify -SetReceiptDate and/or -SetReconciliationDate with the date to set."
    exit 1
}

# Initialize entity if not present
if (-not $data.organizations[$Entity]) {
    $data.organizations[$Entity] = @{
        display_name = if ($Entity -eq "intersite-consulting") { "Intersite Consulting Inc." } else { "Victor Salmon - Room Rentals" }
        slug = $Entity
        accounts = @{}
        receipt_complete_date = $null
        reconciliation_complete_date = $null
    }
}

# Initialize account if not present
if (-not $data.organizations[$Entity].accounts[$Account]) {
    $data.organizations[$Entity].accounts[$Account] = @{
        display_name = $knownAccounts[$Entity][$Account]
        receipt_complete_date = $null
        reconciliation_complete_date = $null
    }
}

$acctRef = $data.organizations[$Entity].accounts[$Account]

if ($SetReceiptDate) {
    $acctRef.receipt_complete_date = $SetReceiptDate
    Write-Host "  [OK] $Entity / $Account : receipt_complete_date = $SetReceiptDate" -ForegroundColor Green
}

if ($SetReconciliationDate) {
    $acctRef.reconciliation_complete_date = $SetReconciliationDate
    Write-Host "  [OK] $Entity / $Account : reconciliation_complete_date = $SetReconciliationDate" -ForegroundColor Green
}

Update-OrgAggregates -Org $data.organizations[$Entity]
Write-Host "  [->] Org aggregate recomputed:" -ForegroundColor Gray
Write-Host "      receipt_complete_date:       $(Format-Date $data.organizations[$Entity].receipt_complete_date)" -ForegroundColor Cyan
Write-Host "      reconciliation_complete_date: $(Format-Date $data.organizations[$Entity].reconciliation_complete_date)" -ForegroundColor Cyan

Save-StatusData -Data $data -Path $StatusFile
Write-Host "  [OK] status.json saved to $StatusFile" -ForegroundColor Green
