<#
.SYNOPSIS
    PRP Step RC: Receipt Check — check email for new receipts and process PDFs.
.DESCRIPTION
    Wraps the email receipt checking logic from Invoke-RoomRentalsMonthlyUpdate.ps1.
    For room-rentals, POSTs to the Bookkeeping container's check-email endpoint,
    downloads new PDFs, runs invoice conversion, and files them. For
    intersite-consulting, logs a no-op (email checking not configured).
.PARAMETER OrgName
    Organization name ("intersite-consulting" or "room-rentals").
.PARAMETER ContinueOnError
    If set, non-critical failures emit warnings instead of terminating.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStepRC-ReceiptCheck.ps1 -OrgName "room-rentals" -WhatIf
.EXAMPLE
    Invoke-PrpStepRC-ReceiptCheck.ps1 -OrgName "intersite-consulting" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [switch]$ContinueOnError,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = "RC"
$stepName = "Receipt Check"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))

# Intersite-consulting: no email receipt checking configured
if ($OrgName -eq "intersite-consulting") {
    Write-Information "[PRP STEP RC] No email receipt checking configured for intersite-consulting — skipping" -Tags PRP
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = "No email receipt checking configured for this org"
        NextSteps  = @("Proceed to Step TR: TAS Rebuild")
        NewReceipts = 0
    }
}

# --- room-rentals: check email ---
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals"

$containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" 2>$null
if (-not $containerId) {
    $msg = "Bookkeeping container not running — email check skipped (non-critical)"
    Write-Warning "[PRP STEP RC] $msg"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = $msg
        NextSteps  = @("Proceed to Step TR: TAS Rebuild")
        NewReceipts = 0
    }
}

$token = docker exec $containerId cat /run/secrets/fleet_api_token 2>$null
if (-not $token) {
    $msg = "Could not get Bookkeeper API token — email check skipped (non-critical)"
    Write-Warning "[PRP STEP RC] $msg"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $true
        Details    = $msg
        NextSteps  = @("Proceed to Step TR: TAS Rebuild")
        NewReceipts = 0
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP RC] WhatIf: would check email for mailbox=receipts_rentals, since_days=30" -Tags PRP
    $now = Get-Date
    $emailCheckRecord = [ordered]@{
        checked_at = $now.ToString('o')
        mailbox    = "receipts_rentals"
        checked_by = "$stepName (WhatIf)"
        downloaded = 0
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $emailCheckFile = "$booksRoot\email-last-checked.json"
    try {
        [System.IO.File]::WriteAllText($emailCheckFile, ($emailCheckRecord | ConvertTo-Json), $utf8NoBom)
    } catch { Write-Warning "[PRP STEP RC] Could not write email check timestamp: $_" }

    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber  = $stepNumber
        Passed      = $true
        Details     = "WhatIf: email check skipped"
        NextSteps   = @("Run without -WhatIf to execute")
        NewReceipts = 0
    }
}

# --- Execute email check ---
$emailBody = @{mailbox = "receipts_rentals"; since_days = 30; download = $true; download_dir = "/data/receipts/room-rentals/ingest"} | ConvertTo-Json

try {
    $emailResult = Invoke-RestMethod -Uri "http://localhost:21008/sources/check-email" -Method POST `
        -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
        -Body $emailBody -ErrorAction Stop
} catch {
    $msg = "Email check failed: $_"
    Write-Warning "[PRP STEP RC] $msg"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber  = $stepNumber
        Passed      = $false
        Details     = $msg
        NextSteps   = @("Check Bookkeeping container health", "Verify IMAP credentials in secret bundle")
        NewReceipts = 0
    }
}

$newReceipts = $emailResult.total_downloaded

if ($newReceipts -gt 0) {
    Write-Information "[PRP STEP RC] Downloaded $newReceipts new receipt(s) from email" -Tags PRP

    $ingestDir = "$booksRoot\2026 Receipts\ingest"
    $null = New-Item -ItemType Directory -Path $ingestDir -Force

    $converterPy = "$repoRoot\Skills\Bookkeeping\Scripts\pdf\convert-pdf-invoice-to-sidecar.py"

    $containerFiles = docker exec $containerId ls /data/receipts/room-rentals/ingest/ 2>$null
    if ($containerFiles) {
        $containerFiles -split "`n" | ForEach-Object {
            $fn = $_.Trim()
            if ($fn -and $fn -ne "logo.png") {
                try {
                    docker cp "${containerId}:/data/receipts/room-rentals/ingest/$fn" "$ingestDir\$fn" 2>$null
                    Write-Information "[PRP STEP RC] Copied: $fn" -Tags PRP
                } catch {
                    Write-Warning "[PRP STEP RC] Copy failed for $fn : $_"
                }
            }
        }
    }

    # Run invoice converter on each PDF
    Get-ChildItem "$ingestDir\*.pdf" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Write-Information "[PRP STEP RC] Converting: $($_.Name)" -Tags PRP
            & python $converterPy $_.FullName 2>&1 | ForEach-Object {
                Write-Information "[PRP STEP RC]   $_" -Tags PRP
            }
        } catch {
            Write-Warning "[PRP STEP RC] Conversion failed for $($_.Name): $_"
        }
    }

    # Move converted files to receipt folders
    $receiptDir = "$booksRoot\2026 Receipts"
    Get-ChildItem "$ingestDir\*.pdf", "$ingestDir\*.csv", "$ingestDir\*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        $dest = if ($_.Name -match "83.95.*Internet") { "$receiptDir\TD" } else { $receiptDir }
        $null = New-Item -ItemType Directory -Path $dest -Force
        try {
            Move-Item $_.FullName "$dest\" -Force
            Write-Information "[PRP STEP RC] Filed: $($_.Name) -> $(Split-Path $dest -Leaf)" -Tags PRP
        } catch {
            Write-Warning "[PRP STEP RC] Move failed for $($_.Name): $_"
        }
    }

    # Update manifest
    & "$PSScriptRoot\update-manifest.ps1" -ReceiptsDir $receiptDir 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Information "[PRP STEP RC] Manifest update: skipped (update-manifest.ps1 not found or failed)" -Tags PRP
    }
} else {
    Write-Information "[PRP STEP RC] No new receipts found in email" -Tags PRP
}

# Record email check timestamp
$emailCheckFile = "$booksRoot\email-last-checked.json"
$now = Get-Date
$emailCheckRecord = [ordered]@{
    checked_at = $now.ToString('o')
    mailbox    = "receipts_rentals"
    checked_by = "$stepName (PRP)"
    downloaded = $newReceipts
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [System.IO.File]::WriteAllText($emailCheckFile, ($emailCheckRecord | ConvertTo-Json), $utf8NoBom)
} catch { Write-Warning "[PRP STEP RC] Could not write email check timestamp: $_" }

Write-Information "[PRP STEP RC] Email check recorded: $emailCheckFile" -Tags PRP
Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber  = $stepNumber
    Passed      = $true
    Details     = "Email check completed: $newReceipts new receipt(s)"
    NextSteps   = @("Proceed to Step TR: TAS Rebuild")
    NewReceipts = $newReceipts
}
