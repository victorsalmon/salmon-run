# Used by: Skills/Bookkeeping/books/reconciliation/_pre-recon-pipeline.md (Step 8c fallback)
# Invoked by: Invoke-PrpStep8-Reconcile.ps1

<#
.SYNOPSIS
    PRP Browserless Reconciliation Adapter — bridges sidecar data to zoho-reconcile.js.
.DESCRIPTION
    Reads sidecar CSV period data and cloud-books-entities.json to build a
    reconciliation config consumable by zoho-reconcile.js. Runs the reconcile
    script locally (dev) or via docker exec (prod). Returns structured results.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Account name as used in reconciliation-periods.md (e.g. "RBC-INTERSITE", "TD-MLM", "MC 6258").
.PARAMETER Local
    Run with local Playwright Chromium (dev mode). Default: use docker exec on overlay network.
.PARAMETER PeriodStart
    1-indexed period to start from (default: 1, meaning earliest period).
.PARAMETER PeriodEnd
    1-indexed period to end at (default: 99, meaning all periods).
.PARAMETER ReconcileConfigPath
    Path to write the generated reconcile config JSON. If omitted, writes to a temp file.
.PARAMETER PassThru
    Return the reconcile results as objects instead of printing to console.
.EXAMPLE
    .\Invoke-PrpBrowserlessReconcile.ps1 -OrgName "intersite-consulting" -AccountName "RBC-INTERSITE" -Local
.EXAMPLE
    .\Invoke-PrpBrowserlessReconcile.ps1 -OrgName "room-rentals" -AccountName "TD-MLM" -Local -PeriodStart 3 -PeriodEnd 4
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [string]$AccountName,

    [switch]$Local,

    [int]$PeriodStart = 1,

    [int]$PeriodEnd = 99,

    [string]$ReconcileConfigPath,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

# ---- Paths ----
$repoRoot = Resolve-Path "$PSScriptRoot\..\..\.."
$jsScriptDir = Join-Path $repoRoot "Infrastructure\Browserless\Sites\books.zoho.com"
$jsScript = Join-Path $jsScriptDir "zoho-reconcile.js"
$entitiesFile = Join-Path $repoRoot "Skills\Bookkeeping\cloud-books-entities.json"
$sidecarBaseDir = Join-Path $env:USERPROFILE "intersite-docs\Taxes and Bookkeeping"

# ---- Account name to entity config mapping ----
$accountNameMap = @{
    "RBC-INTERSITE" = @{ Entity = "intersite-consulting"; EntityKey = "bank_accounts"; EntitySubKey = "rbc-chequing" }
    "MC 6258"       = @{ Entity = "intersite-consulting"; EntityKey = "credit_cards";   EntitySubKey = "6258" }
    "RBC-FRA"       = @{ Entity = "room-rentals";         EntityKey = "bank_accounts";  EntitySubKey = "rbc-fra" }
    "RBC-VISA"      = @{ Entity = "room-rentals";         EntityKey = "bank_accounts";  EntitySubKey = $null; AccountId = "151803000000101251" }
    "TD-MLM"        = @{ Entity = "room-rentals";         EntityKey = "bank_accounts";  EntitySubKey = "td-mlm" }
    "SCOTIA-TMH"    = @{ Entity = "room-rentals";         EntityKey = "bank_accounts";  EntitySubKey = "scotia-tmh" }
}

if (-not $accountNameMap.ContainsKey($AccountName)) {
    Write-Error "Unknown account name '$AccountName'. Known: $($accountNameMap.Keys -join ', ')"
    exit 1
}

$acctInfo = $accountNameMap[$AccountName]

# ---- Load entity config ----
if (-not (Test-Path -LiteralPath $entitiesFile)) {
    Write-Error "Entity config not found at $entitiesFile"
    exit 1
}
$entities = Get-Content -LiteralPath $entitiesFile -Raw | ConvertFrom-Json

# Resolve org ID
$entity = $entities.entities.$OrgName
if (-not $entity) {
    Write-Error "Unknown org '$OrgName' in cloud-books-entities.json"
    exit 1
}
$orgId = $entity.org_id

# Resolve account ID
$accountId = $acctInfo.AccountId
if (-not $accountId) {
    if ($acctInfo.EntityKey -eq "credit_cards") {
        $cc = $entities.credit_cards.$($acctInfo.EntitySubKey)
        $accountId = $cc.account_id
    } else {
        $ba = $entities.bank_accounts.$($acctInfo.EntitySubKey)
        $accountId = $ba.account_id
    }
}
if (-not $accountId) {
    Write-Error "Could not resolve account ID for '$AccountName'"
    exit 1
}

# ---- Read reconciliation periods ----
$reconPeriodsFile = "$sidecarBaseDir\$OrgName\reconciliation-periods.md"
if (-not (Test-Path -LiteralPath $reconPeriodsFile)) {
    Write-Error "Reconciliation periods file not found at $reconPeriodsFile"
    exit 1
}

Write-Information "[PRP BROWSERLESS] Reading reconciliation periods from $reconPeriodsFile" -Tags PRP

$periods = @()
$lines = Get-Content -LiteralPath $reconPeriodsFile
$inTargetSection = $false
$sectionHeaderPattern = "^##\s+$([Regex]::Escape($AccountName))"

foreach ($line in $lines) {
    if ($line -match $sectionHeaderPattern) {
        $inTargetSection = $true
        continue
    }
    if ($inTargetSection) {
        if ($line -match '^\|(.+)\|(.+)\|$') {
            $periodStr = $matches[1].Trim()
            $balanceStr = $matches[2].Trim()
            if ($periodStr -match '–\s*([A-Za-z]+ \d+,? \d{4})') {
                $endDateStr = $matches[1]
                $endDate = $null
                $fmts = @("MMM dd yyyy", "MMMM dd yyyy", "MMM d yyyy", "MMMM d yyyy")
                foreach ($fmt in $fmts) {
                    if ([datetime]::TryParseExact($endDateStr.Trim() -replace ',', '', $fmt, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::None, [ref]$endDate)) {
                        break
                    }
                }
                if (-not $endDate) {
                    Write-Warning "Could not parse end date '$endDateStr' — skipping"
                    continue
                }
                $balance = [decimal]($balanceStr -replace '[$,]', '')
                $periods += @{ end = $endDate.ToString('yyyy-MM-dd'); balance = $balance }
            }
        } elseif ($line -match '^##\s') {
            break
        }
    }
}

if ($periods.Count -eq 0) {
    Write-Error "No periods found for account '$AccountName' in $reconPeriodsFile"
    exit 1
}

Write-Information "[PRP BROWSERLESS] Found $($periods.Count) periods for $AccountName" -Tags PRP

# ---- Build reconcile config JSON ----
$reconConfig = @(
    @{
        slug = $OrgName
        orgId = $orgId
        accounts = @(
            @{
                id = $accountId
                name = $AccountName
                statements = $periods
            }
        )
    }
)

if (-not $ReconcileConfigPath) {
    $ReconcileConfigPath = Join-Path $env:TEMP "prp-reconcile-config-$OrgName-$AccountName-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
}
$reconConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReconcileConfigPath -Encoding utf8
Write-Information "[PRP BROWSERLESS] Config written to $ReconcileConfigPath" -Tags PRP

# ---- Helper: get AWS secret with SSO auto-refresh ----
function Get-AwsSecretWithSsoRefresh {
    param(
        [string]$SecretId,
        [string]$Profile = 'intersite',
        [string]$Region = 'ca-central-1'
    )
    $attempts = 0
    $maxAttempts = 2
    do {
        $attempts++
        try {
            $secretsJson = aws secretsmanager get-secret-value --secret-id $SecretId --profile $Profile --region $Region --query "SecretString" --output text 2>$null
            if (-not $secretsJson) { throw "Empty response from AWS SM" }
            return $secretsJson | ConvertFrom-Json
        } catch {
            if ($attempts -ge $maxAttempts) { throw }
            Write-Warning "[PRP AWS] SSO session may be expired — attempting re-login (attempt $attempts/$maxAttempts)"
            $null = aws sso login --profile $Profile 2>&1 | Out-String
            Start-Sleep -Seconds 3
            $loginResult = aws sso login --profile $Profile 2>&1 | Out-String
            if ($loginResult -match "Successfully logged into Start URL") {
                Write-Information "[PRP AWS] SSO re-login successful" -Tags PRP
            } else {
                Write-Warning "[PRP AWS] SSO re-login may not have completed — retrying credential fetch"
            }
        }
    } while ($attempts -lt $maxAttempts)
    throw "Failed to retrieve AWS SM secret after $maxAttempts attempts"
}

# ---- Fetch Zoho credentials ----
Write-Information "[PRP BROWSERLESS] Fetching Zoho credentials from AWS SM..." -Tags PRP
$profile = $env:AWS_SSO_PROFILE
if (-not $profile) { $profile = 'intersite' }
try {
    $secrets = Get-AwsSecretWithSsoRefresh -SecretId "Interclaw/FRAD/Provisioning" -Profile $profile -Region "ca-central-1"
} catch {
    Write-Error "Failed to fetch AWS SM secret after SSO re-login attempt: $_"
    exit 1
}

$env:ZOHO_EMAIL = $secrets.ZOHO_BOOKS_RWUSER
$env:ZOHO_PASS = $secrets.ZOHO_BOOKS_RWPASS
$env:ZOHO_BOOKS_ID = $secrets.ZOHO_BOOKS_ID
$env:ZOHO_BOOKS_SECRET = $secrets.ZOHO_BOOKS_SECRET
$env:ZOHO_BOOKS_REFRESH = $secrets.ZOHO_BOOKS_REFRESH
$env:ORG_FILTER = $OrgName
$env:ACCT_FILTER = $AccountName
$env:PERIOD_START = $PeriodStart
$env:PERIOD_END = $PeriodEnd
$env:RECONCILE_CONFIG_PATH = $ReconcileConfigPath
$env:BROWSERLESS_API_KEY = $secrets.BROWSERLESS_API_KEY

Write-Information "[PRP BROWSERLESS] Running reconciliation for $AccountName ($OrgName)..." -Tags PRP

$resultOutput = ""

if ($Local) {
    # Local Playwright mode (dev)
    if (-not (Test-Path -LiteralPath $jsScript)) {
        Write-Error "Reconcile script not found at $jsScript"
        exit 1
    }
    Push-Location -LiteralPath $jsScriptDir
    try {
        $resultOutput = node $jsScript 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} else {
    # Docker exec on overlay network (prod)
    $volMount1 = (Resolve-Path $jsScriptDir).Path + ":/data"
    $volMount2 = (Resolve-Path $ReconcileConfigPath).Path + ":/data/reconcile-config.json"
    $dockerArgs = @(
        "run", "--rm", "-i", "--network", "service_net",
        "-e", "BROWSERLESS_API_KEY", "-e", "ZOHO_EMAIL", "-e", "ZOHO_PASS",
        "-e", "ORG_FILTER", "-e", "ACCT_FILTER", "-e", "PERIOD_START", "-e", "PERIOD_END",
        "-e", "RECONCILE_CONFIG_PATH",
        "-v", $volMount1, "-v", $volMount2,
        "-w", "/data", "node:20-slim", "sh", "-c",
        "npm install playwright; node /data/zoho-reconcile.js"
    )
    Write-Information "[PRP BROWSERLESS] Running: docker exec reconcile" -Tags PRP
    $resultOutput = & docker @dockerArgs 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
}

Write-Information "[PRP BROWSERLESS] Script exited with code $exitCode" -Tags PRP

# ---- Parse results ----
$results = @()
$periodPattern = '--- Period \d+: (\S+) \| Balance: \$([\d.]+) ---'
$reconPattern = '(✅|⚠️|❌)\s*(.*)'

$currentPeriod = $null
foreach ($line in ($resultOutput -split "`r`n|`n")) {
    if ($line -match $periodPattern) {
        if ($currentPeriod) { $results += $currentPeriod }
        $currentPeriod = @{
            PeriodEnd = $matches[1]
            ClosingBalance = [decimal]$matches[2]
            Actions = @()
            Success = $null
        }
    }
    if ($currentPeriod -and $line -match $reconPattern) {
        $currentPeriod.Actions += "$($matches[1]) $($matches[2])"
        if ($matches[1] -eq '✅') {
            $currentPeriod.Success = $true
        } elseif ($matches[1] -eq '⚠️' -or $matches[1] -eq '❌') {
            $currentPeriod.Success = $false
        }
    }
}
if ($currentPeriod) { $results += $currentPeriod }

Write-Information "[PRP BROWSERLESS] Reconciliation results:" -Tags PRP
foreach ($r in $results) {
    $status = if ($r.Success -eq $true) { "PASS" } elseif ($r.Success -eq $false) { "FAIL" } else { "UNKNOWN" }
    Write-Information "  Period $($r.PeriodEnd): $status" -Tags PRP
}

Write-Information "[PRP BROWSERLESS] Full output appended below" -Tags PRP
Write-Output $resultOutput

# ---- Cleanup ----
Remove-Item -LiteralPath $ReconcileConfigPath -Force -ErrorAction SilentlyContinue

if ($PassThru) {
    return [PSCustomObject]@{
        OrgName = $OrgName
        AccountName = $AccountName
        AccountId = $accountId
        OrgId = $orgId
        Periods = $periods.Count
        ReconConfigPath = $ReconcileConfigPath
        ExitCode = $exitCode
        Results = $results
        RawOutput = $resultOutput
    }
}
