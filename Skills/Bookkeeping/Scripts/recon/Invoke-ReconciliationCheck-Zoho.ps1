<#
.SYNOPSIS
    DEPRECATED — Use Invoke-PrpAcctPipeline.ps1 instead.
.DESCRIPTION
    This standalone check has been superseded by the PRP pipeline
    (Invoke-PrpAcctPipeline.ps1), which is idempotent, produces a timestamped
    per-org report with data freshness, and runs all validation steps
    including TAS balance forward, sidecar comparison, and Zoho completeness.
    
    Run the PRP instead:
      .\Invoke-PrpAcctPipeline.ps1 -AccountName "RBC-FRA" -OrgName "room-rentals" ...
    
    This script is kept for reference only and will be removed in a future update.
#>

param(
    [string]$Organization = "intersite-consulting",
    [string]$Account = "",
    [string]$ZohoToken = "",
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$Organization"
$reconPeriodsPath = "$booksRoot\reconciliation-periods.md"
$bankDir = if ($Organization -eq "room-rentals") { "$booksRoot\2026 Bank Statements" } else { "$booksRoot\2026 Filing\2026 Bank Statements" }

$orgIds = @{
    "intersite-consulting" = "925048093"
    "room-rentals" = "925004567"
}
$orgId = $orgIds[$Organization]
if (-not $orgId) { Write-Error "Unknown organization: $Organization"; exit 1 }

# Account definitions
$accountDefs = switch ($Organization) {
    "intersite-consulting" {
        @(
            @{ label = "RBC-INTERSITE"; folder = "RBC-INTERSITE"; zohoId = "93310000000100019"; isCreditCard = $false }
            @{ label = "MC-6258"; folder = "MC 6241 (6258)"; zohoId = "93310000000100013"; isCreditCard = $true }
        )
    }
    "room-rentals" {
        @(
            @{ label = "RBC-FRA"; folder = "RBC-FRA-5172549"; zohoId = "151803000000101245"; isCreditCard = $false }
            @{ label = "TD-MLM"; folder = "TD-MLM-6467010"; zohoId = "151803000000101006"; isCreditCard = $false }
            @{ label = "SCOTIA-TMH"; folder = "SCOTIA-TMH 406000697486"; zohoId = "151803000000101153"; isCreditCard = $false }
            @{ label = "RBC-VISA"; folder = "RBC-FRA-6679"; zohoId = "151803000000101251"; isCreditCard = $true }
        )
    }
}

function Parse-FlexibleDate {
    param([string]$DateStr, [string[]]$Formats)
    $clean = $DateStr.Trim() -replace ',', ''
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    foreach ($fmt in $Formats) {
        try { return [datetime]::ParseExact($clean, $fmt, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $null
}

function Get-AccountPeriods {
    param([string]$MdPath, [string]$AccountName)
    if (-not (Test-Path $MdPath)) { return @() }
    $periods = @()
    $lines = Get-Content $MdPath
    $inSection = $false
    $sectionHeaderPattern = "^##\s+$([Regex]::Escape($AccountName))"
    foreach ($line in $lines) {
        if ($line -match $sectionHeaderPattern) { $inSection = $true; continue }
        if ($inSection) {
            if ($line -match '^\|(.+)\|(.+)\|$') {
                $periodStr = $matches[1].Trim()
                $balanceStr = $matches[2].Trim()
                if ($periodStr -match '–\s*([A-Za-z]+\s*\d+,?\s*\d{4})') {
                    $endDateStr = $matches[1]
                    $endDate = Parse-FlexibleDate -DateStr $endDateStr -Formats @("MMM dd yyyy","MMMM dd yyyy","MMM d yyyy","MMMM d yyyy")
                    if (-not $endDate) { continue }
                    $balance = [decimal]($balanceStr -replace '[$,]', '')
                    $periodStartStr = ($periodStr -split '–')[0].Trim()
                    $hasYearInStart = $periodStartStr -match '\d{4}'
                    $startDate = Parse-FlexibleDate -DateStr $periodStartStr -Formats @("MMM dd yyyy","MMMM dd yyyy","MMM d yyyy","MMMM d yyyy","MMM dd","MMMM dd","MMM d","MMMM d")
                    if ($startDate -and -not $hasYearInStart -and $endDate) {
                        $startDate = [datetime]::new($endDate.Year, $startDate.Month, $startDate.Day)
                    }
                    if (-not $startDate) { $startDate = $endDate.AddMonths(-1) }
                    $periods += [PSCustomObject]@{
                        start = $startDate; end = $endDate
                        closing_balance = $balance
                        label = "$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
                    }
                }
            } elseif ($line -match '^##\s') { break }
        }
    }
    return $periods
}

function Get-SidecarTxns($AccountName, $PeriodStart, $PeriodEnd) {
    $stmtDir = "$bankDir\$AccountName"
    if (-not (Test-Path $stmtDir)) { return $null }
    $stmtFile = Get-ChildItem "$stmtDir\*$($PeriodEnd.ToString('yyyy-MM-dd')).csv" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Zoho' -and $_.Name -notmatch 'zoho' -and $_.Name -notmatch 'dry-run' } |
        Select-Object -First 1
    if (-not $stmtFile) { return $null, $null }
    $rows = Get-Content $stmtFile.FullName | Where-Object { $_ -notmatch '^#' -and $_ -match '\d{4}-\d{2}-\d{2}' }
    $txns = @()
    foreach ($l in $rows) {
        $c = $l -split ','
        if ($c.Count -lt 5) { continue }
        try {
            $amt = [double]$c[4].Trim('"')
            $dc = $c[3].Trim('"')
            $signed = if ($dc -eq 'debit' -or $dc -eq 'Debit') { -$amt } else { $amt }
            $txns += [PSCustomObject]@{
                date = $c[0].Trim('"')
                payee = $c[1].Trim('"')
                description = $c[2].Trim('"')
                amount = $signed
                amountAbs = $amt
                dc = $dc
            }
        } catch {}
    }
    $closingBalance = $null
    $headerLines = Get-Content $stmtFile.FullName -Head 10
    foreach ($hl in $headerLines) {
        if ($hl -match 'Closing Balance:\s*[\$]?([\d,.]+)') {
            $closingBalance = [double]($matches[1] -replace '[$,]', '')
        }
    }
    return $txns, $closingBalance
}

# --- Get Zoho token ---
$token = $ZohoToken
if (-not $token) {
    Write-Host "Getting Zoho OAuth token..." -ForegroundColor Yellow
    try {
        $authResult = & (Join-Path $PSScriptRoot "Invoke-PrpStep0-TokenAcquisition.ps1") -OrgId $orgId -OrgName $Organization
        if ($authResult -and $authResult.Token) {
            $token = $authResult.Token
        } else {
            # Try direct Node.js approach
            $nodeScript = @'
const TOKEN_URL = 'https://accounts.zoho.com/oauth/v2/token';
const body = new URLSearchParams({
    client_id: process.env.ZOHO_BOOKS_ID,
    client_secret: process.env.ZOHO_BOOKS_SECRET,
    refresh_token: process.env.ZOHO_BOOKS_REFRESH,
    grant_type: 'refresh_token'
});
fetch(TOKEN_URL, { method: 'POST', body }).then(r => r.json()).then(d => {
    if (d.access_token) { process.stdout.write(d.access_token); }
    else { process.exit(1); }
}).catch(() => process.exit(1));
'@
            $token = docker exec FRAD_is-bookkeeping.1.yr05luh08yskj1aqpi1twhvvy node -e $nodeScript 2>$null
            if (-not $token -or $token -eq "") {
                Write-Error "Could not acquire Zoho token. Ensure Bookkeeping container is running and rate limit is not exceeded."
                exit 1
            }
        }
    } catch {
        Write-Error "Token acquisition failed: $_"
        exit 1
    }
}

$headers = @{ Authorization = "Zoho-oauthtoken $token"; "Content-Type" = "application/json" }

function Invoke-ZohoFetch {
    param($BaseUri)
    $all = @(); $page = 1
    do {
        $uri = "$BaseUri&per_page=200&page=$page"
        try {
            $r = Invoke-RestMethod -Uri $uri -Headers $headers
            $items = $r.banktransactions
            if ($items -and $items.Count -gt 0) { $all += $items }
            $hasMore = if ($r.page_context) { $r.page_context.has_more_page } else { $false }
            $page++
        } catch { break }
    } while ($hasMore -and $page -le 20)
    return $all
}

function Write-Status($text, $color) { Write-Host $text -ForegroundColor $color }
$allOk = $true

foreach ($acct in $accountDefs) {
    if ($Account -and $acct.label -ne $Account) { continue }
    $periods = Get-AccountPeriods -MdPath $reconPeriodsPath -AccountName $acct.label
    if ($periods.Count -eq 0) { Write-Status "  No periods found for $($acct.label)" "Yellow"; continue }

    Write-Status "`n══════════════════════════════════════════" "Cyan"
    Write-Status "  $($acct.label) — Zoho Completeness Check" "Cyan"
    Write-Status "══════════════════════════════════════════" "Cyan"

    Write-Status "  Fetching Zoho transactions for $($acct.label)..." "Gray"
    $baseUri = "https://www.zohoapis.com/books/v3/banktransactions?account_id=$($acct.zohoId)&organization_id=$orgId"
    $zohoTxnsAll = Invoke-ZohoFetch -BaseUri $baseUri

    $periodOk = $true
    $periodCount = 0
    $missingTotal = 0
    $extraTotal = 0

    for ($i = 0; $i -lt $periods.Count; $i++) {
        $p = $periods[$i]
        $sidecarTxns, $scClosing = Get-SidecarTxns -AccountName $acct.folder -PeriodStart $p.start -PeriodEnd $p.end
        if (-not $sidecarTxns) {
            Write-Status "  ⚠ No sidecar CSV for period ending $($p.end.ToString('yyyy-MM-dd')) — skipping" "Yellow"
            continue
        }
        $periodCount++

        $zohoPeriod = $zohoTxnsAll | Where-Object {
            try {
                $zd = [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', $null)
                $zd -ge $p.start.AddDays(-2) -and $zd -le $p.end.AddDays(2)
            } catch { $false }
        }

        $zohoAmounts = $zohoPeriod | Where-Object { $_.amount -ne $null }
        $zohoNet = [math]::Round(($zohoAmounts | Measure-Object amount -Sum).Sum, 2)
        if (-not $zohoNet) { $zohoNet = 0 }
        $scNet = [math]::Round(($sidecarTxns | Measure-Object amount -Sum).Sum, 2)

        $filteredSidecar = $sidecarTxns | Where-Object { $_.date -ge $p.start.ToString('yyyy-MM-dd') }
        $scCount = $filteredSidecar.Count
        $zohoCount = $zohoPeriod.Count

        Write-Status "  Period $($p.end.ToString('yyyy-MM-dd')): $scCount sidecar txns, $zohoCount Zoho txns" "White"

        # Find missing in Zoho (in sidecar but not in Zoho)
        $missing = @()
        foreach ($st in $filteredSidecar) {
            $match = $zohoPeriod | Where-Object {
                [math]::Abs($_.amount - $st.amountAbs) -lt 0.50 -and
                ((Get-Date $_.date) - (Get-Date $st.date)).TotalDays -ge -2 -and
                ((Get-Date $_.date) - (Get-Date $st.date)).TotalDays -le 2
            }
            if (-not $match) { $missing += $st }
        }

        # Find extra in Zoho (in Zoho but not in sidecar, excluding opening_balance transactions)
        $extra = @()
        foreach ($zt in $zohoPeriod) {
            if ($zt.transaction_type -eq 'opening_balance') { continue }
            $match = $filteredSidecar | Where-Object {
                [math]::Abs($_.amountAbs - $zt.amount) -lt 0.50 -and
                ((Get-Date $zt.date) - (Get-Date $_.date)).TotalDays -ge -2 -and
                ((Get-Date $zt.date) - (Get-Date $_.date)).TotalDays -le 2
            }
            if (-not $match) { $extra += $zt }
        }

        if ($missing.Count -gt 0) {
            $periodOk = $false; $allOk = $false
            Write-Status "    ❌ $($missing.Count) transaction(s) missing from Zoho:" "Red"
            foreach ($m in $missing) {
                Write-Status "      $($m.date)  $($m.amount)  $($m.payee)" "Red"
            }
        }
        if ($extra.Count -gt 0) {
            $periodOk = $false; $allOk = $false
            Write-Status "    ❌ $($extra.Count) extra transaction(s) in Zoho not on statement:" "Yellow"
            foreach ($e in $extra) {
                Write-Status "      $($e.date)  $($e.amount)  $($e.payee) $($e.description)" "Yellow"
            }
        }
        if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
            $scVsZoho = [math]::Abs($scNet - $zohoNet)
            if ($scVsZoho -le 0.50) {
                Write-Status "    ✅ Sidecar matches Zoho (net=$zohoNet)" "Green"
            } else {
                Write-Status "    ⚠ Net flow diff: sidecar=$scNet vs Zoho=$zohoNet" "Yellow"
            }
        }
        $missingTotal += $missing.Count
        $extraTotal += $extra.Count
    }

    if ($periodOk) {
        Write-Status "  ✅ All $periodCount periods: Zoho matches sidecar" "Green"
    } else {
        Write-Status "  ❌ $missingTotal missing, $extraTotal extra across $periodCount periods" "Red"
    }
}

Write-Status "`nOverall: $(if ($allOk) { 'PASS — Zoho matches sidecars for all periods' } else { 'FAIL — Zoho has discrepancies with sidecars' })" $(if ($allOk) {'Green'} else {'Red'})
if ($allOk) { exit 0 } else { exit 1 }
