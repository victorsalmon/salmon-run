<#
.SYNOPSIS
    Verify the bookkeeping state snapshot against live Zoho API and report discrepancies.

.DESCRIPTION
    Reads the state snapshot (mem-intersite-consulting-bookkeeping-state.md), queries
    Zoho for actual current attachment counts, and flags any difference. Exits with
    code 0 if match, 1 if mismatch (stale).

    Run this at session start before trusting any state data.

.PARAMETER SnapshotPath
    Path to the state snapshot markdown file.

.PARAMETER AwsProfile
    AWS SSO profile for secrets access.

.EXAMPLE
    .\Skills\Bookkeeper\Scripts\_snapshot-staleness-check.ps1
#>

param(
    [string]$SnapshotPath = "$env:USERPROFILE\intersite-docs\Documentation\Memory\mem-intersite-consulting-bookkeeping-state.md",
    [string]$AwsProfile = "intersite"
)

$ErrorActionPreference = "Stop"

# --- Extract expected count from snapshot ---
if (-not (Test-Path $SnapshotPath)) {
    Write-Warning "Snapshot not found at $SnapshotPath"
    exit 1
}

$snapshot = Get-Content $SnapshotPath -Raw
$expectedTotal = 0; $expectedAttached = 0; $expectedWithout = 0

if ($snapshot -match '\|\s*\*\*(\d+)\*\*\s*\|' -and $snapshot -match '\|\s*\*\*(\d+) \((\d+)%\)\*\*\s*\|') {
    # Parse from Current Counts table
    $lines = $snapshot -split "`n"
    $inTable = $false
    foreach ($line in $lines) {
        if ($line -match '^\| Metric \| Value \|$') { $inTable = $true; continue }
        if ($inTable -and $line -match '^\|--------\|-------\|$') { continue }
        if ($inTable -and $line -match '^\| Total .+? \| \*\*(\d+)\*\* \|$') { $expectedTotal = [int]$Matches[1]; continue }
        if ($inTable -and $line -match '^\| With receipts attached \| \*\*(\d+) ') { $expectedAttached = [int]$Matches[1]; continue }
        if ($inTable -and $line -match '^\| Without receipts \| \*\*(\d+) ') { $expectedWithout = [int]$Matches[1]; continue }
    }
}

if ($expectedTotal -eq 0) {
    Write-Warning "Could not parse counts from snapshot (expected format: | **N** |)"
    exit 1
}

Write-Host "Snapshot expects: $expectedTotal total, $expectedAttached attached, $expectedWithout unattached"

# --- Get live counts from Zoho ---
Write-Host "Fetching live counts from Zoho..."
$full = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --profile $AwsProfile --query SecretString --output text 2>$null | ConvertFrom-Json
$zoho = @{ ZOHO_BOOKS_ID = $full.ZOHO_BOOKS_ID; ZOHO_BOOKS_SECRET = $full.ZOHO_BOOKS_SECRET; ZOHO_BOOKS_REFRESH = $full.ZOHO_BOOKS_REFRESH }
$env:ZOHO_SECRETS = ($zoho | ConvertTo-Json -Compress)

$scriptPath = "$PSScriptRoot\_count-total.mjs"
if (-not (Test-Path $scriptPath)) {
    # Write the inline count script
    @"
import { ZohoAuth } from 'file:///$($PSScriptRoot.Replace('\','/'))/../zoho/zoho-auth.js';
const ORG_ID = '925048093';
const MC_ACCT = '93310000000100013';
async function main() {
  const s = JSON.parse(process.env.ZOHO_SECRETS);
  const a = new ZohoAuth({ clientId: s.ZOHO_BOOKS_ID, clientSecret: s.ZOHO_BOOKS_SECRET, refreshToken: s.ZOHO_BOOKS_REFRESH, stateDir: process.cwd() });
  let p = 1, t = [], at = 0, na = 0;
  while (true) {
    const u = 'https://www.zohoapis.com/books/v3/expenses?organization_id=925048093&paid_through_account_id=93310000000100013&page='+p+'&per_page=200';
    const r = await fetch(u, { headers: { Authorization: 'Zoho-oauthtoken '+(await a.getToken()) } });
    const d = await r.json();
    t = t.concat(d.expenses || []);
    if (!d.page_context || !d.page_context.has_more_page) break;
    p++;
  }
  for (const e of t) { if (e.has_attachment) at++; else na++; }
  console.log('TOTAL:'+t.length+' ATTACHED:'+at+' UNATTACHED:'+na);
}
main().catch(e => { console.error(e.message); process.exit(1); });
"@ | Set-Content $scriptPath -Encoding utf8
}

$liveOutput = & node $scriptPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Zoho API call failed: $liveOutput"
    exit 1
}

$liveTotal = 0; $liveAttached = 0; $liveWithout = 0
if ($liveOutput -match 'TOTAL:(\d+)') { $liveTotal = [int]$Matches[1] }
if ($liveOutput -match 'ATTACHED:(\d+)') { $liveAttached = [int]$Matches[1] }
if ($liveOutput -match 'UNATTACHED:(\d+)') { $liveWithout = [int]$Matches[1] }

Write-Host "Zoho live: $liveTotal total, $liveAttached attached, $liveWithout unattached"

# --- Compare ---
$stale = $false
if ($expectedTotal -ne $liveTotal) {
    Write-Warning "STALE: Total count differs (snapshot=$expectedTotal, live=$liveTotal)"
    $stale = $true
}
if ($expectedAttached -ne $liveAttached) {
    Write-Warning "STALE: Attached count differs (snapshot=$expectedAttached, live=$liveAttached)"
    $stale = $true
}
if ($expectedWithout -ne $liveWithout) {
    Write-Warning "STALE: Unattached count differs (snapshot=$expectedWithout, live=$liveWithout)"
    $stale = $true
}

if ($stale) {
    Write-Host "`nSnapshot is STALE. Run Invoke-SnapshotUpdate to correct it, then archive old handoffs." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "`nSnapshot is FRESH. Counts match Zoho live." -ForegroundColor Green
    exit 0
}
