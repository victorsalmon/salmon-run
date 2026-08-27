# Token source: bookkeeping_secrets_bundle (Swarm secret) -> /data/.zoho-token.json (volume)
param(
    [switch]$DryRun,
    [string]$StatementsBase = "/data/statements"
)
$ErrorActionPreference = "Stop"
$base = $StatementsBase

$bundlePath = "/run/secrets/bookkeeping_secrets_bundle"
$accessToken = $null
if (Test-Path $bundlePath) {
    $bundle = Get-Content $bundlePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $accessToken = $bundle.ZOHO_ACCESS_TOKEN
}
if (-not $accessToken) {
    $tokenCache = "/data/.zoho-token.json"
    if (Test-Path $tokenCache) {
        $cached = Get-Content $tokenCache -Raw -Encoding UTF8 | ConvertFrom-Json
        $accessToken = $cached.access_token
    }
}
if (-not $accessToken) {
    throw "No Zoho access token available — authenticate first"
}

function Import-Sidecar($csvPath, $acctId) {
    $lines = Get-Content $csvPath -Encoding UTF8
    $dataLines = $lines | Where-Object { $_ -notmatch '^#' -and $_ -match '^\d{4}' }
    $transactions = @()
    foreach ($line in $dataLines) {
        $vals = $line.Split(',').Trim('"')
        if ($vals.Count -lt 5) { continue }
        $d = $vals[0]; $p = $vals[1]; $dr = $vals[3]; $amt = [double]$vals[4]
        if ($d -lt '2025-04-01' -or $d -gt '2026-03-31') { continue }
        $transactions += @{ date = $d; payee = $p; description = $p; debit_or_credit = $dr; amount = $amt }
    }
    if ($transactions.Count -eq 0) {
        Write-Host ("    WARN: 0 fiscal-2026 transactions in " + $csvPath)
        $warnDir = Split-Path $csvPath -Parent
        $warnFile = Join-Path $warnDir ".pipeline-warnings.json"
        $entry = @(@{ stage = "Import-SidecarStatements"; file = $csvPath; severity = "warning"; message = "0 fiscal-2026 transactions found in sidecar: $([System.IO.Path]::GetFileName($csvPath))" })
        if (Test-Path $warnFile) {
            try { $existing = Get-Content $warnFile -Raw -Encoding UTF8 | ConvertFrom-Json; $entry = $existing + $entry } catch {}
        }
        $entry | ConvertTo-Json -Depth 3 | Out-File -FilePath $warnFile -Encoding utf8
        return $null
    }
    return @{ account_id = $acctId; start_date = "2025-04-01"; end_date = "2026-03-31"; transactions = $transactions }
}

$accounts = @(
    @{ dir = "RBC-INTERSITE"; id = "93310000000100019"; name = "RBC" },
    @{ dir = "MC 6241 (6258)"; id = "93310000000100013"; name = "MC" }
)

foreach ($acct in $accounts) {
    $dir = Join-Path $base $acct.dir
    $sidecars = Get-ChildItem $dir -Filter "*.csv" | Where-Object { $_.Name -notmatch 'dry-run|2026 Fiscal' } | Sort-Object Name
    Write-Host ("=== " + $acct.name + " (" + $sidecars.Count + " sidecars) ===")

    foreach ($csv in $sidecars) {
        $payload = Import-Sidecar $csv.FullName $acct.id
        if (-not $payload) { Write-Host ("  Skip " + $csv.Name + " - no fiscal 2026 txns"); continue }
`
        $txnCount = $payload.transactions.Count
`
        if ($DryRun) {
            Write-Host ("  [DRY-RUN] " + $csv.Name + " - " + $txnCount + " txns")
            continue
        }
`
        Write-Host ("  " + $csv.Name + " - " + $txnCount + " txns importing...")
        $json = $payload | ConvertTo-Json -Depth 3 -Compress
        $result = curl.exe -s -X POST -H "Authorization: Zoho-oauthtoken $accessToken" -H "Content-Type: application/json" -d $json "https://www.zohoapis.com/books/v3/bankstatements?organization_id=925048093"
        $parsed = $result | ConvertFrom-Json
        if ($parsed.code -eq 0) {
            Write-Host ("    OK - statement_id=" + $parsed.statement_id)
        } else {
            Write-Host ("    FAIL - " + $parsed.message)
            $warnDir = Split-Path $csv.FullName -Parent
            $warnFile = Join-Path $warnDir ".pipeline-warnings.json"
            $entry = @(@{ stage = "Import-SidecarStatements"; file = $csv.FullName; severity = "error"; message = "Zoho import failed: $($parsed.message)" })
            if (Test-Path $warnFile) {
                try { $existing = Get-Content $warnFile -Raw -Encoding UTF8 | ConvertFrom-Json; $entry = $existing + $entry } catch {}
            }
            $entry | ConvertTo-Json -Depth 3 | Out-File -FilePath $warnFile -Encoding utf8
        }
        Start-Sleep -Milliseconds 800
    }
}

Write-Host "Done."
