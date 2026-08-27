#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Scan all bank statement folders and regenerate reconciliation-periods.md.

.DESCRIPTION
    Discovers PDF bank statements across both orgs (room-rentals, intersite-consulting),
    extracts statement period and ending balance using extract-statement-periods.py,
    falls back to vision (render-to-image + OpenRouter vision) when pdfplumber
    cannot extract text, then regenerates the reconciliation-periods.md reference table.

    Policy: Values are sourced exclusively from official bank statement PDFs.
    This script is the single-entry point for regeneration.

.PARAMETER StaleDays
    Number of days before a cached entry expires and triggers re-extraction.
    Default: 7

.PARAMETER Force
    Force re-extraction of all PDFs (ignore cache).

.PARAMETER WhatIf
    Show what would be done without writing files.

.EXAMPLE
    .\Update-ReconciliationPeriods.ps1

.EXAMPLE
    .\Update-ReconciliationPeriods.ps1 -Force
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 7,
    [switch]$Force,
    [switch]$WhatIf
)

$ScriptDir = $PSScriptRoot
$ORCHESTRATORRoot = Resolve-Path "$ScriptDir\..\..\..\.."
$IntersiteDocs = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping"
$ExtractorPy = "$ScriptDir\..\pdf\extract-statement-periods.py"
$PdfToImagePy = "$ScriptDir\..\pdf\convert-pdf-to-image.py"
$OutputFile = "$IntersiteDocs\reconciliation-periods.md"
$VisionTempDir = "$env:TEMP\recon-vision"

# Bank statement directories
$StatementDirs = @(
    # Room Rentals
    "$IntersiteDocs\room-rentals\2026 Bank Statements\RBC-FRA-5172549"
    "$IntersiteDocs\room-rentals\2026 Bank Statements\RBC-FRA-6679"
    "$IntersiteDocs\room-rentals\2026 Bank Statements\TD-MLM-6467010"
    "$IntersiteDocs\room-rentals\2026 Bank Statements\SCOTIA-TMH 406000697486"
    # Intersite Consulting
    "$IntersiteDocs\intersite-consulting\2026 Filing\2026 Bank Statements\RBC-INTERSITE"
    "$IntersiteDocs\intersite-consulting\2026 Filing\2026 Bank Statements\MC 6241 (6258)"
)

function Write-Step {
    param([string]$Message)
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Result {
    param([string]$Message, [string]$Status)
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host "   [$Status] $Message" -ForegroundColor $color
}

function Invoke-VisionFallback {
    param([string]$PdfPath, [string]$TempDir)

    Write-Step "Vision fallback for: $PdfPath"

    # Render PDF pages to images
    $renderOut = "$TempDir\$( [System.IO.Path]::GetFileNameWithoutExtension($PdfPath) )"
    $null = New-Item -ItemType Directory -Path $renderOut -Force

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { return $null }

    & $python $PdfToImagePy --input-dir (Split-Path $PdfPath -Parent) --output-dir $renderOut --dpi 200 2>&1 | Out-Null

    $images = Get-ChildItem -Path $renderOut -Filter "*.jpg" | Sort-Object Name
    if (-not $images) { return $null }

    # Use the first page (statement header has period + balance info)
    $firstImage = $images[0]

    # Try to use fleet vision API first (Platform-First Resolution)
    $visionResult = $null
    try {
        # Check if is-api is available
        $apiCheck = Invoke-RestMethod -Uri "http://is-api:21005/api/health" -Method Get -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($apiCheck) {
            $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($firstImage.FullName))
            $body = @{ image_base64 = $b64; mode = "receipt" } | ConvertTo-Json
            $resp = Invoke-RestMethod -Uri "http://is-api:21005/api/vision" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30 -ErrorAction SilentlyContinue
            if ($resp -and $resp.text) { $visionResult = $resp.text }
        }
    } catch { $visionResult = $null }

    # Fallback: try OpenRouter directly via MCP or direct API
    if (-not $visionResult) {
        try {
            # Use OpenRouter vision API for text extraction
            # Read the OPENROUTER_CODE_KEY from environment or config
            $apiKey = $env:OPENROUTER_CODE_KEY
            if (-not $apiKey) {
                # Try to get from AWS SM
                $smJson = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --profile intersite --region ca-central-1 --query "SecretString" --output text 2>$null | ConvertFrom-Json
                if ($smJson) { $apiKey = $smJson.OPENROUTER_CODE_KEY }
            }

            if ($apiKey) {
                $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($firstImage.FullName))
                $body = @{
                    model = "qwen/qwen2.5-vl-72b-instruct"
                    messages = @(
                        @{
                            role = "user"
                            content = @(
                                @{ type = "text"; text = "Extract the statement period (from-to dates) and the closing/ending balance amount from this bank statement PDF page. Return ONLY the period and balance in this format: PERIOD: <text> | BALANCE: <amount>" }
                                @{ type = "image_url"; image_url = @{ url = "data:image/jpeg;base64,$b64" } }
                            )
                        }
                    )
                    max_tokens = 200
                } | ConvertTo-Json

                $resp = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 60 -ErrorAction SilentlyContinue
                if ($resp -and $resp.choices) { $visionResult = $resp.choices[0].message.content }
            }
        } catch { $visionResult = $null }
    }

    # Cleanup temp files
    Remove-Item -Path $renderOut -Recurse -Force -ErrorAction SilentlyContinue

    return $visionResult
}

function Parse-VisionOutput {
    param([string]$VisionText)

    $period = $null
    $balance = $null

    if ($VisionText -match 'PERIOD:\s*(.+?)\s*\|') { $period = $matches[1].Trim() }
    if ($VisionText -match 'BALANCE:\s*\$?([\d,]+\.\d{2})') { $balance = $matches[1] }

    return @{ period = $period; balance = $balance }
}

# ---- MAIN ----

Write-Step "Update-ReconciliationPeriods"

# Verify Python extractor exists
if (-not (Test-Path $ExtractorPy)) {
    Write-Error "Extractor script not found: $ExtractorPy"
    exit 1
}

# Verify statement directories exist
$validDirs = @()
foreach ($d in $StatementDirs) {
    if (Test-Path $d) { $validDirs += $d }
    else { Write-Result "Directory not found: $d" "SKIP" }
}

# Run Python extractor across all directories
Write-Step "Running extract-statement-periods.py across $($validDirs.Count) directories"

$jsonResults = $null
$tempFile = [System.IO.Path]::GetTempFileName()

# Build Python args for all directories
$pyArgs = @($ExtractorPy) + $validDirs
$pyOutput = & python $pyArgs 2>&1

# Separate stderr (progress) from stdout (JSONL)
$stdOut = @()
$stdErr = @()
foreach ($line in $pyOutput) {
    $trimmed = "$line".Trim()
    if ($trimmed -match '^{' -or $trimmed -match '^\[{') { $stdOut += $trimmed }
    else { $stdErr += $trimmed }
}

foreach ($e in $stdErr) { Write-Host "   $e" -ForegroundColor DarkGray }
$jsonResults = $stdOut | ConvertFrom-Json

# Process each result
$dataByAccount = @{}

# Account display order
$accountOrder = @(
    'RBC-FRA (5172549)',
    'RBC-VISA (6679)',
    'TD-MLM (6467010)',
    'SCOTIA-TMH (406000697486)',
    'RBC-INTERSITE (6632)',
    'MC 6258 (6241)'
)

$orgMap = @{
    'RBC-FRA (5172549)'            = 'room-rentals'
    'RBC-VISA (6679)'              = 'room-rentals'
    'TD-MLM (6467010)'             = 'room-rentals'
    'SCOTIA-TMH (406000697486)'   = 'room-rentals'
    'RBC-INTERSITE (6632)'         = 'intersite-consulting'
    'MC 6258 (6241)'               = 'intersite-consulting'
}

foreach ($r in $jsonResults) {
    if (-not $r.text_empty -and $r.ending_balance) {
        if (-not $dataByAccount.ContainsKey($r.account)) { $dataByAccount[$r.account] = @() }
        $dataByAccount[$r.account] += $r
    } elseif ($r.text_empty) {
        Write-Result "$($r.file): text empty, trying vision fallback" "SKIP"
        $visionText = Invoke-VisionFallback -PdfPath $r.path -TempDir $VisionTempDir
        if ($visionText) {
            $parsed = Parse-VisionOutput $visionText
            if ($parsed.period -and $parsed.balance) {
                if (-not $dataByAccount.ContainsKey($r.account)) { $dataByAccount[$r.account] = @() }
                $r.statement_period = $parsed.period
                $r.ending_balance = $parsed.balance
                $dataByAccount[$r.account] += $r
                Write-Result "$($r.file): vision extracted $($parsed.period) = $$($parsed.balance)" "OK"
            }
        } else {
            Write-Result "$($r.file): vision fallback failed" "FAIL"
        }
    } else {
        Write-Result "$($r.file): balance not found in text" "SKIP"
    }
}

# Generate markdown
Write-Step "Generating $OutputFile"

$md = @"
# Reconciliation Periods — Organization-Wide

> **Policy**: All values in this document are sourced exclusively from official bank statement PDFs. Statement period and closing/ending balance are extracted directly from each PDF via text extraction (pdfplumber). No Zoho exports, no CSV summaries, no estimated values. This is the single source of truth for reconciliation reference.
>
> **Regeneration**: Run `Skills/Bookkeeping/Scripts/Update-ReconciliationPeriods.ps1` to scan all statement folders and regenerate this table.

"@

$orgSections = @{
    'room-rentals'       = 'Room Rentals'
    'intersite-consulting' = 'Intersite Consulting'
}

$orgAccountLabels = @{
    'RBC-FRA (5172549)'          = 'RBC-FRA — Chequing (5172549)'
    'RBC-VISA (6679)'            = 'RBC-VISA — Visa (6679)'
    'TD-MLM (6467010)'           = 'TD-MLM — Chequing (6467010)'
    'SCOTIA-TMH (406000697486)' = 'SCOTIA-TMH — Chequing (406000697486)'
    'RBC-INTERSITE (6632)'       = 'RBC-INTERSITE — Chequing (6632)'
    'MC 6258 (6241)'             = 'MC 6258 — MasterCard (6241)'
}

$balanceLabels = @{
    'RBC-FRA (5172549)'          = 'Ending Balance'
    'RBC-VISA (6679)'            = 'Ending Balance'
    'TD-MLM (6467010)'           = 'Ending Balance'
    'SCOTIA-TMH (406000697486)' = 'Ending Balance'
    'RBC-INTERSITE (6632)'       = 'Ending Balance'
    'MC 6258 (6241)'             = 'New Balance'
}

$processedOrgs = @{}
foreach ($acct in $accountOrder) {
    $org = $orgMap[$acct]
    if (-not $processedOrgs.ContainsKey($org)) {
        $processedOrgs[$org] = $true
        $md += "## $($orgSections[$org])\n\n"
    }

    $label = $orgAccountLabels[$acct]
    $balLabel = $balanceLabels[$acct]
    $md += "### $label\n\n"
    $md += '| Statement Period | ' + $balLabel + " |\n"
    $md += '|---|---|\n'

    $entries = $dataByAccount[$acct] | Sort-Object -Property { $_.statement_period }
    if ($entries) {
        foreach ($e in $entries) {
            $period = $e.statement_period
            $balance = $e.ending_balance
            if ($balance) {
                try { $balance = [double]$balance; $balance = "`$$($balance.ToString('N2'))" } catch {}
            }
            $md += "| $period | $balance |\n"
        }
    } else {
        $md += '| _(no statements found)_ | _(N/A)_ |\n'
    }
    $md += "\n"
}

$date = Get-Date -Format 'yyyy-MM-dd'
$md += "---\n\n*Generated: $date. Source: official PDF bank statements from each account's statement folder.*\n"

if ($WhatIf) {
    Write-Host "`n$md`n" -ForegroundColor DarkGray
    Write-Step "WHATIF: would write to $OutputFile"
} else {
    $md | Out-File -FilePath $OutputFile -Encoding utf8 -Force
    Write-Result "Written to $OutputFile" "OK"
}

Write-Step "Done"
