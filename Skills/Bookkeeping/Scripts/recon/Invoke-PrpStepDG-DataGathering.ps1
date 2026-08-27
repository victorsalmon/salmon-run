<#
.SYNOPSIS
    PRP Step DG: Data Gathering — export Zoho Plaid transactions and copy CSVs locally.
.DESCRIPTION
    Wraps the Zoho Plaid export + CSV copy logic from the monthly update wrappers.
    Accepts -OrgName and branches on org-specific paths. For intersite-consulting,
    copies 2 CSVs (RBC-INTERSITE, MC 6258) with merge mode. For room-rentals,
    copies 4 CSVs (RBC-FRA, TD-MLM, SCOTIA-TMH, RBC-VISA) via direct copy.
.PARAMETER OrgName
    Organization name ("intersite-consulting" or "room-rentals").
.PARAMETER OrgId
    Optional Zoho organization ID override.
.PARAMETER ContinueOnError
    If set, non-critical failures emit warnings instead of terminating.
.PARAMETER WhatIf
    Dry-run: log export summary, skip file copies, return success.
.EXAMPLE
    Invoke-PrpStepDG-DataGathering.ps1 -OrgName "room-rentals" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [switch]$ContinueOnError,

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
$stepNumber = "DG"
$stepName = "Data Gathering"

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
    Write-Warning "[PRP STEP DG] -Platform Container was requested but $reason — falling back to Host mode"
    $Platform = 'Host'
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))

. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName

# Determine books root
switch ($OrgName) {
    "intersite-consulting" { $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting" }
    "room-rentals"         { $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals" }
    default { throw "Unknown org: $OrgName" }
}

# --- Detect Bookkeeping container ---
$containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
if (-not $containerId) {
    $msg = "Bookkeeping container not running — is the fleet deployed?"
    Write-Warning "[PRP STEP DG] $msg"
    if (-not $ContinueOnError) {
        return [PSCustomObject]@{
            StepNumber = $stepNumber
            Passed     = $false
            Details    = $msg
            NextSteps  = @("Deploy the fleet first", "Run deploy.ps1 to start services")
            CsvFiles   = @()
        }
    }
}

# --- Container health check (Platform=Container) ---
if ($Platform -eq 'Container' -and $containerId) {
    Write-Information "[PRP STEP DG] Platform=Container — checking container health" -Tags PRP
    try {
        $healthResp = docker exec $containerId curl -s -o /dev/null -w "%{http_code}" http://localhost:21008/api/ready 2>$null
        if ($healthResp -ne '200') {
            $msg = "Container health check failed — /api/ready returned HTTP $healthResp"
            Write-Warning "[PRP STEP DG] $msg"
            if (-not $ContinueOnError) {
                return [PSCustomObject]@{
                    StepNumber = $stepNumber
                    Passed     = $false
                    Details    = $msg
                    NextSteps  = @("Check Bookkeeping container logs", "Verify is-bookkeeping API is running")
                    CsvFiles   = @()
                }
            }
        } else {
            Write-Information "[PRP STEP DG] Container health check passed" -Tags PRP
        }
    } catch {
        Write-Warning "[PRP STEP DG] Container health check threw: $_"
    }
}

# --- Get fleet API token ---
$token = if ($containerId) { docker exec $containerId cat /run/secrets/fleet_api_token 2>$null } else { $null }
if (-not $token -and $containerId) {
    $msg = "Could not get Bookkeeper API token"
    Write-Warning "[PRP STEP DG] $msg"
    if (-not $ContinueOnError) {
        return [PSCustomObject]@{
            StepNumber = $stepNumber
            Passed     = $false
            Details    = $msg
            NextSteps  = @("Check Bookkeeping container secrets")
            CsvFiles   = @()
        }
    }
}

# --- Check Plaid-enabled accounts ---
$anyPlaidEnabled = $false
if ($prpCfg -and $prpCfg.accounts) {
    $anyPlaidEnabled = ($prpCfg.accounts.PSObject.Properties.Value | Where-Object { $_.plaid_enabled -ne $false }).Count -gt 0
}
if (-not $anyPlaidEnabled) {
    Write-Information "[PRP STEP DG] No Plaid-enabled accounts — skipping Zoho export" -Tags PRP
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "Skipped — no Plaid-enabled accounts in config"
        NextSteps  = @("Proceed to Step RC: Receipt Check")
        CsvFiles   = @()
    }
}

# --- Export Zoho Plaid transactions ---
$body = @{dry_run = [bool]$WhatIfPreference; entity = $OrgName} | ConvertTo-Json
$result = $null
$exportOk = $false

if ($token) {
    try {
        $result = Invoke-RestMethod -Uri "http://localhost:21008/zoho/transactions/export" -Method POST `
            -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
            -Body $body -ErrorAction Stop
        $exportOk = $result.success
    } catch {
        Write-Warning "[PRP STEP DG] Export API call failed: $_"
    }
}

if (-not $exportOk) {
    $detail = if ($token) { "Export failed — API returned error" } else { "Cannot export (no token)" }
    Write-Warning "[PRP STEP DG] $detail"
    if (-not $ContinueOnError) {
        return [PSCustomObject]@{
            StepNumber = $stepNumber
            Passed     = $false
            Details    = $detail
            NextSteps  = @("Check Bookkeeping container and fleet API", "Verify Zoho credentials")
            CsvFiles   = @()
        }
    }
}

$totalTxns = if ($result) { $result.total_transactions } else { 0 }
Write-Information "[PRP STEP DG] Export returned $totalTxns transactions across $(if ($result) { $result.total_accounts } else { 0 }) accounts" -Tags PRP

if ($WhatIfPreference) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "WhatIf: export returned $totalTxns transactions, file copies skipped"
        NextSteps  = @("Run without -WhatIf to copy files")
        CsvFiles   = @()
    }
}

# --- Copy CSVs ---
$csvFiles = @()
$copied = 0

if ($containerId -and $exportOk) {
    switch ($OrgName) {
        "intersite-consulting" {
            $bankDir = "$booksRoot\2026 Filing\2026 Bank Statements"

            foreach ($acct in $result.accounts) {
                $csvFile = $acct.csvFile
                if (-not $csvFile) { continue }

                # Skip if this account has Plaid disabled in config
                $acctConfigKey = if ($acct.account -match "RBC" -or $acct.label -match "RBC") { "RBC-INTERSITE" } else { "MC-6258" }
                $acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $acctConfigKey
                if ($acctCfg -and $acctCfg.plaid_enabled -eq $false) {
                    Write-Information "[PRP STEP DG] Skipping $($acct.label) — Plaid disabled" -Tags PRP
                    continue
                }

                $rbcDir = "$bankDir\RBC-INTERSITE"
                $mcDir = "$bankDir\MC 6241 (6258)"
                $dir = if ($acct.account -match "RBC" -or $acct.label -match "RBC") { $rbcDir } else { $mcDir }
                $null = New-Item -ItemType Directory -Path $dir -Force

                $srcPath = "/app/zoho-transactions/intersite-consulting/$csvFile"
                $tempPath = Join-Path $dir "temp-$csvFile"

                try {
                    docker cp "${containerId}:${srcPath}" $tempPath | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "docker cp exit code $LASTEXITCODE" }

                    $existingPath = Join-Path $dir (Get-ChildItem -Path $dir -Filter "*Present*Zoho*" -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty Name)
                    if (-not $existingPath) { $existingPath = Join-Path $dir $csvFile }

                    # Merge into existing CSV
                    if (Test-Path $tempPath) {
                        $existingLines = if (Test-Path $existingPath) { Get-Content $existingPath } else { @() }
                        $freshLines = Get-Content $tempPath

                        if ($existingLines.Count -gt 0) {
                            $headerEnd = 0
                            for ($i = 0; $i -lt $existingLines.Count; $i++) {
                                if ($existingLines[$i] -notmatch '^#') { $headerEnd = $i; break }
                            }
                            $headerLines = $existingLines[0..($headerEnd - 1)]
                            $colHeaderLine = $existingLines[$headerEnd]
                            $existingDataLines = $existingLines[($headerEnd + 1)..($existingLines.Count - 1)]

                            $freshDataStart = 0
                            for ($i = 0; $i -lt $freshLines.Count; $i++) {
                                if ($freshLines[$i] -notmatch '^#') { $freshDataStart = $i + 1; break }
                            }
                            $freshDataLines = $freshLines[$freshDataStart..($freshLines.Count - 1)]

                            $existingIds = @{}
                            foreach ($line in $existingDataLines) {
                                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                                $cols = $line -split ','
                                if ($cols.Count -gt 5 -and $cols[5]) { $existingIds[$cols[5].Trim()] = $true }
                            }

                            $newCount = 0
                            foreach ($line in $freshDataLines) {
                                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                                $cols = $line -split ','
                                if ($cols.Count -gt 5 -and $cols[5] -and -not $existingIds.ContainsKey($cols[5].Trim())) {
                                    $existingDataLines += $line
                                    $existingIds[$cols[5].Trim()] = $true
                                    $newCount++
                                }
                            }

                            $totalCount = $existingDataLines.Count
                            $generatedDate = (Get-Date -Format 'yyyy-MM-dd')
                            $sourceName = if ($csvFile -match '(RBC|MC)') { $Matches[1] } else { "Zoho" }

                            $newHeader = @(
                                "# Source: Zoho Books API (Plaid-synced transactions) - MERGED",
                                "# Account: $sourceName",
                                "# Generated: $generatedDate",
                                "# Transactions: $totalCount",
                                "# Merged from: existing ($($existingDataLines.Count - $newCount) txns) + latest export ($newCount new txns)",
                                $colHeaderLine
                            )

                            $mergedContent = $newHeader + $existingDataLines
                            $mergedContent | Set-Content -Path $existingPath -Encoding utf8
                            Write-Information "[PRP STEP DG] ${sourceName}: merged ($newCount new, $totalCount total)" -Tags PRP
                        } else {
                            Move-Item -LiteralPath $tempPath -Destination $existingPath -Force
                            Write-Information "[PRP STEP DG] ${csvFile}: saved as new file" -Tags PRP
                        }

                        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                        $csvFiles += $existingPath
                        $copied++
                    }
                } catch {
                    Write-Warning "[PRP STEP DG] $($acct.label): copy failed - $_"
                    if (-not $ContinueOnError) { throw }
                }
            }
        }

        "room-rentals" {
            $bankDir = "$booksRoot\2026 Bank Statements"
            $accountMap = @(
                @{ name = "fra"; label = "RBC-FRA 5172549";           folder = "RBC-FRA-5172549";           zoho = "2026.06.11-Present - RBC-FRA 5172549 - Zoho.csv" }
                @{ name = "mlm"; label = "TD-MLM 6467010";            folder = "TD-MLM-6467010";            zoho = "2026.06.11-Present - TD-MLM 6467010 - Zoho.csv" }
                @{ name = "tmh"; label = "SCOTIA-TMH 406000697486";   folder = "SCOTIA-TMH 406000697486";   zoho = "2026.06.11-Present - SCOTIA-TMH 406000697486 - Zoho.csv" }
                @{ name = "rbc-visa"; label = "RBC-FRA-6679 Visa";    folder = "RBC-FRA-6679";              zoho = "2026.06.11-Present - RBC-FRA-6679 Visa - Zoho.csv" }
            )

            foreach ($a in $result.accounts) {
                if (-not $a.csvFile) { continue }
                $map = $accountMap | Where-Object { $_.name -eq $a.account }
                if (-not $map) {
                    Write-Warning "[PRP STEP DG] No folder mapping for account $($a.account) -- skipping"
                    continue
                }

                # Skip if this account has Plaid disabled in config
                $rrConfigKey = "RBC-FRA-5172549"
                switch ($a.account) {
                    "fra"     { $rrConfigKey = "RBC-FRA-5172549" }
                    "mlm"     { $rrConfigKey = "TD-MLM-6467010" }
                    "tmh"     { $rrConfigKey = "SCOTIA-TMH-406000697486" }
                    "rbc-visa" { $rrConfigKey = "RBC-FRA-6679" }
                }
                $rrAcctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $rrConfigKey
                if ($rrAcctCfg -and $rrAcctCfg.plaid_enabled -eq $false) {
                    Write-Information "[PRP STEP DG] Skipping $($a.label) — Plaid disabled" -Tags PRP
                    continue
                }
                $src = "${containerId}:/app/zoho-transactions/room-rentals/$($a.csvFile)"
                $dstDir = "$bankDir\$($map.folder)"
                $null = New-Item -ItemType Directory -Path $dstDir -Force
                $dst = "$dstDir\$($map.zoho)"
                try {
                    docker cp $src $dst | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "docker cp exit code $LASTEXITCODE" }
                    Write-Information "[PRP STEP DG] $($a.label): $($a.csvFile) -> $($map.folder)\$($map.zoho)" -Tags PRP
                    $csvFiles += $dst
                    $copied++
                } catch {
                    Write-Warning "[PRP STEP DG] $($a.label): copy failed - $_"
                    if (-not $ContinueOnError) { throw }
                }
            }
        }
    }
}

$detail = "Exported $totalTxns transactions, copied $copied CSV file(s)"
Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber = $stepNumber
    Passed     = $true
    Details    = $detail
    NextSteps  = @("Proceed to Step RC: Receipt Check")
    CsvFiles   = $csvFiles
}
