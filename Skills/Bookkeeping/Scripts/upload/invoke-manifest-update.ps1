<#
.SYNOPSIS
    Dual-mode orchestrator for Manifest Update pipeline.
.DESCRIPTION
    Mode Local: runs Phase 2 sub-steps (PDF extraction, image extraction, metadata renaming, manifest update).
    Mode Cloud: runs Local first, then Phase 3 (credit card matching, Zoho upload/attach).
    Supports resume via .manifest-update-state.json checkpoint after each receipt.
.PARAMETER Mode
    Required. "Local" for Phase 2 only, "Cloud" for Phase 2 + Phase 3.
.PARAMETER ReceiptsDir
    Path to receipts directory. Defaults to entity's receipt_dir from cloud-books-entities.json.
.PARAMETER Entity
    Entity name from cloud-books-entities.json. Default: intersite-consulting.
.PARAMETER CloudConfig
    Path to cloud-books-entities.json. Default: Skills/Bookkeeping/cloud-books-entities.json.
.PARAMETER Force
    Ignore status columns and reprocess all receipts.
.PARAMETER WhatIf
    Print what would be done without making changes.
.EXAMPLE
    .\invoke-manifest-update.ps1 -Mode Local -Entity intersite-consulting
    Run Phase 2 sub-steps for Intersite Consulting.
.EXAMPLE
    .\invoke-manifest-update.ps1 -Mode Cloud -WhatIf
    Preview all Phase 2 + Phase 3 operations.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Local", "Cloud")]
    [string]$Mode,

    [string]$ReceiptsDir,

    [string]$Entity = "intersite-consulting",

    [string]$CloudConfig,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Resolve cloud-books-entities.json
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CloudConfig) {
    $candidates = @(
        Join-Path $scriptDir ".." ".." ".." ".." "Skills" "Bookkeeping" "cloud-books-entities.json"
        Join-Path (Resolve-Path "$scriptDir\..\..\..\..") "Skills" "Bookkeeping" "cloud-books-entities.json"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $CloudConfig = (Resolve-Path $c).Path; break } }
}
if (-not $CloudConfig -or -not (Test-Path $CloudConfig)) {
    Write-Error "cloud-books-entities.json not found. Provide -CloudConfig path."
    exit 1
}

# Load entity config
$entitiesConfig = Get-Content $CloudConfig -Raw | ConvertFrom-Json
$entityConfig = $entitiesConfig.entities.$Entity
if (-not $entityConfig) {
    Write-Error "Entity '$Entity' not found in $CloudConfig"
    exit 1
}

# Resolve ReceiptsDir
if (-not $ReceiptsDir) {
    $ReceiptsDir = $entityConfig.receipt_dir
}

# Resolve manifest path
$manifestPath = Join-Path $ReceiptsDir "manifest.csv"

# State directory
$stateDir = Join-Path $ReceiptsDir ".manifest-update-state"
$null = New-Item -ItemType Directory -Path $stateDir -Force

# --- Phase 2: Local mode sub-steps ---
function Invoke-Phase2Local {
    Write-Host "=== Phase 2: Local Mode ($Entity) ===" -ForegroundColor Cyan

    $subSteps = @(
        @{ Name = "PDF Data Extraction"; Script = "invoke-pdf-data-extraction.ps1"; Args = @{ ReceiptsDir = $ReceiptsDir; ManifestPath = $manifestPath; Force = $Force } }
        @{ Name = "Image Data Extraction"; Script = "invoke-image-data-extraction.ps1"; Args = @{ ReceiptsDir = $ReceiptsDir; ManifestPath = $manifestPath; Force = $Force } }
        @{ Name = "Metadata Renaming"; Script = "invoke-metadata-renaming.ps1"; Args = @{ ReceiptsDir = $ReceiptsDir; ManifestPath = $manifestPath; Force = $Force } }
        @{ Name = "Update Manifest"; Script = "update-manifest.ps1"; Args = @{ ReceiptsDir = $ReceiptsDir; ManifestPath = $manifestPath; Entity = $CloudConfig; Force = $Force } }
    )

    $phase2Stats = @{ Completed = 0; Errors = 0 }

    foreach ($step in $subSteps) {
        $stepPath = Join-Path $scriptDir $step.Script
        if (-not (Test-Path $stepPath)) {
            Write-Warning "Sub-step not found: $stepPath"
            $phase2Stats.Errors++
            continue
        }

        Write-Host "`n--- Step: $($step.Name) ---" -ForegroundColor Yellow

        $argList = @{}
        foreach ($kv in $step.Args.GetEnumerator()) {
            if ($kv.Value -is [bool]) {
                if ($kv.Value) { $argList[$kv.Key] = $true }
            } else {
                $argList[$kv.Key] = $kv.Value
            }
        }

        if ($WhatIf) {
            Write-Host "  [WHAT IF] & $($step.Script) $($argList | ConvertTo-Json -Compress)" -ForegroundColor Magenta
            continue
        }

        try {
            & $stepPath @argList
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                Write-Warning "  Step returned exit code $LASTEXITCODE"
                $phase2Stats.Errors++
            } else {
                $phase2Stats.Completed++
            }
        } catch {
            Write-Warning "  Step failed: $_"
            $phase2Stats.Errors++
        }
    }

    Write-Host "`nPhase 2 complete: $($phase2Stats.Completed) steps done, $($phase2Stats.Errors) errors" -ForegroundColor Cyan
    return $phase2Stats
}

# --- Phase 3: Cloud mode (credit card match + Zoho upload) ---
function Invoke-Phase3Cloud {
    Write-Host "`n=== Phase 3: Cloud Mode ($Entity) ===" -ForegroundColor Cyan

    if (-not (Test-Path $manifestPath)) {
        Write-Warning "Manifest not found: $manifestPath"
        return @{ Completed = 0; Errors = 1 }
    }

    # Read manifest to find pending receipts
    $raw = Get-Content $manifestPath -Raw -Encoding UTF8
    $bom = [char]0xFEFF
    if ($raw[0] -eq $bom) { $raw = $raw.Substring(1) }
    $receipts = $raw | ConvertFrom-Csv

    if ($Force) {
        $pending = $receipts
    } else {
        $pending = $receipts | Where-Object { $_.status_cloud_match -ne "done" }
    }

    if (-not $pending) {
        Write-Host "No receipts pending cloud match." -ForegroundColor Green
        return @{ Completed = 0; Errors = 0 }
    }

    $stats = @{ Completed = 0; Errors = 0; Total = @($pending).Count }

    # Get credit card suffix from entity config
    $cardSuffix = ""
    $ccTable = $entitiesConfig.credit_cards
    if ($ccTable) {
        foreach ($ccProp in $ccTable.PSObject.Properties) {
            if ($ccProp.Value.entity -eq $Entity) { $cardSuffix = $ccProp.Name; break }
        }
    }

    $extractMatchPy = Join-Path $scriptDir "extract-match-credit-card.py"
    $zohoAttachMjs = Join-Path $scriptDir "zoho-attach-receipts.mjs"

    foreach ($receipt in $pending) {
        $filename = $receipt.filename
        $hash = if ($receipt.hash) { $receipt.hash } else { $filename }

        # Check state
        $stateFile = Join-Path $stateDir "$hash.json"
        if ((Test-Path $stateFile) -and -not $Force) {
            Write-Host "  SKIP (state exists): $filename" -ForegroundColor Gray
            $stats.Completed++
            continue
        }

        if ($WhatIf) {
            Write-Host "  [WHAT IF] Process: $filename" -ForegroundColor Magenta
            continue
        }

        try {
            # Step 3a: Extract-match via Python (delegates to extract-match-credit-card.py)
            if ($extractMatchPy) {
                Write-Host "  Matching: $filename" -ForegroundColor Gray
                & python $extractMatchPy --card-suffix $cardSuffix --manifest $manifestPath 2>&1
            }

            # Step 3b: Check manifest for existing transaction match
            $manifestRow = $receipts | Where-Object { $_.filename -eq $filename -or $_.hash -eq $hash } | Select-Object -First 1
            $matchId = if ($manifestRow) { $manifestRow.cloud_books_match_id } else { "" }

            if ($matchId) {
                # Existing match — attach receipt to existing expense
                Write-Host "  Attaching to existing expense: $filename" -ForegroundColor Gray
                & node $zohoAttachMjs --entity $Entity
            } else {
                # No existing match — upload as new expense (delegates to zoho.js pipeline)
                Write-Host "  Uploading new expense: $filename" -ForegroundColor Gray
                & node (Join-Path $scriptDir "zoho-upload.js") $Entity
            }

            # Update status in manifest
            $receipt.status_cloud_match = "done"
            $raw = $receipts | ConvertTo-Csv -NoTypeInformation
            $raw | Set-Content $manifestPath -Encoding UTF8

            Write-Host "  Done: $filename" -ForegroundColor Green
            $stats.Completed++

            # Write checkpoint
            $checkpoint = @{
                filename = $filename
                hash = $hash
                entity = $Entity
                completed_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                status = "done"
            }
            $checkpoint | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
        } catch {
            Write-Warning "  Failed: $filename — $_"
            $stats.Errors++

            $checkpoint = @{
                filename = $filename
                hash = $hash
                entity = $Entity
                completed_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                status = "error"
                error = "$_"
            }
            $checkpoint | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
        }
    }

    Write-Host "`nPhase 3 complete: $($stats.Completed)/$($stats.Total) done, $($stats.Errors) errors" -ForegroundColor Cyan
    return $stats
}

# --- Main ---
Write-Host "=== Manifest Update Orchestrator ===" -ForegroundColor Cyan
Write-Host "Mode: $Mode | Entity: $Entity | ReceiptsDir: $ReceiptsDir" -ForegroundColor White
if ($Force) { Write-Host "Force mode: reprocessing all receipts" -ForegroundColor Yellow }
if ($WhatIf) { Write-Host "WHAT IF mode: no changes will be made" -ForegroundColor Magenta }

$phase2Result = $null
$phase3Result = $null

if ($Mode -eq "Local" -or $Mode -eq "Cloud") {
    $phase2Result = Invoke-Phase2Local
}

if ($Mode -eq "Cloud") {
    $phase3Result = Invoke-Phase3Cloud
}

# Summary
Write-Host "`n=== Orchestrator Summary ===" -ForegroundColor Cyan
if ($phase2Result) {
    Write-Host "Phase 2 (Local): $($phase2Result.Completed) completed, $($phase2Result.Errors) errors" -ForegroundColor $(if ($phase2Result.Errors -eq 0) { "Green" } else { "Yellow" })
}
if ($phase3Result) {
    Write-Host "Phase 3 (Cloud): $($phase3Result.Completed)/$($phase3Result.Total) completed, $($phase3Result.Errors) errors" -ForegroundColor $(if ($phase3Result.Errors -eq 0) { "Green" } else { "Yellow" })
}
Write-Host "Done." -ForegroundColor Cyan
