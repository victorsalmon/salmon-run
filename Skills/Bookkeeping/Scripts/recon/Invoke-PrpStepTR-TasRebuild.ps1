<#
.SYNOPSIS
    PRP Step TR: TAS Rebuild — backup existing TAS, regenerate, detect manual edits.
.DESCRIPTION
    Wraps the TAS backup + rebuild logic from the monthly update wrappers.
    Backs up TAS-2026.csv, calls Build-IntersiteTAS.ps1 or Build-TAS.ps1
    depending on -OrgName, reads the row count, and detects manual edits
    by diffing backup vs regenerated file.
.PARAMETER OrgName
    Organization name ("intersite-consulting" or "room-rentals").
.PARAMETER WhatIf
    Dry-run: show what would happen without executing.
.EXAMPLE
    Invoke-PrpStepTR-TasRebuild.ps1 -OrgName "room-rentals" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = "TR"
$stepName = "TAS Rebuild"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))

switch ($OrgName) {
    "intersite-consulting" {
        $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting"
        $buildScript = Join-Path $scriptDir "Build-IntersiteTAS.ps1"
    }
    "room-rentals" {
        $booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals"
        $buildScript = Join-Path $scriptDir "Build-TAS.ps1"
    }
    default { throw "Unknown org: $OrgName" }
}

$tasPath = "$booksRoot\TAS-2026.csv"
$backupPath = "$booksRoot\TAS-2026.bak"
$manualEditsDetected = $false

if ($WhatIfPreference) {
    Write-Information "[PRP STEP TR] WhatIf: would backup $tasPath, run $buildScript, diff backup vs regenerated" -Tags PRP
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber          = $stepNumber
        Passed              = $true
        Details             = "WhatIf: TAS rebuild skipped"
        NextSteps           = @("Run without -WhatIf to execute")
        TasRowCount         = 0
        ManualEditsDetected = $false
    }
}

# --- Backup current TAS ---
if (Test-Path $tasPath) {
    Copy-Item -LiteralPath $tasPath -Destination $backupPath -Force
    Write-Information "[PRP STEP TR] Backup saved: $backupPath" -Tags PRP
}

# --- Regenerate TAS ---
if (-not (Test-Path $buildScript)) {
    $msg = "Build script not found: $buildScript"
    Write-Error "[PRP STEP TR] $msg"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber          = $stepNumber
        Passed              = $false
        Details             = $msg
        NextSteps           = @("Verify Bookkeeping scripts are installed")
        TasRowCount         = 0
        ManualEditsDetected = $false
    }
}

Write-Information "[PRP STEP TR] Running $buildScript" -Tags PRP
& $buildScript
if ($LASTEXITCODE -ne 0) {
    $msg = "TAS rebuild failed with exit code $LASTEXITCODE"
    Write-Error "[PRP STEP TR] $msg"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber          = $stepNumber
        Passed              = $false
        Details             = $msg
        NextSteps           = @("Check build script for errors", "Verify bank statement CSVs are in place")
        TasRowCount         = 0
        ManualEditsDetected = $false
    }
}

# --- Read TAS row count ---
$tasRows = 0
if (Test-Path $tasPath) {
    foreach ($line in (Get-Content $tasPath -TotalCount 10 -ErrorAction SilentlyContinue)) {
        if ($line -match "^# Total transactions:\s*(\d+)") {
            $tasRows = [int]$Matches[1]
            break
        }
    }
}
Write-Information "[PRP STEP TR] TAS row count: $tasRows" -Tags PRP

# --- Detect manual edits ---
if (Test-Path $backupPath) {
    $diffOutput = & git diff --no-index -- "$backupPath" "$tasPath" 2>&1
    if ($LASTEXITCODE -ne 0 -and $diffOutput) {
        $changeCount = ($diffOutput | Select-String -Pattern '^[+-].' | Where-Object { $_ -notmatch '^[+-]#' } | Measure-Object).Count
        if ($changeCount -gt 0) {
            $manualEditsDetected = $true
            Write-Warning "[PRP STEP TR] TAS content differs from backup ($changeCount data-line changes)"
            Write-Warning "[PRP STEP TR] Manual edits detected — backup preserved at: $backupPath"
            Write-Warning "[PRP STEP TR] Run: git diff --no-index `"$backupPath`" `"$tasPath`" to review changes"
        }
    } else {
        Write-Information "[PRP STEP TR] TAS unchanged from backup — no manual edits" -Tags PRP
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

$detail = "TAS rebuilt: $tasRows rows"
if ($manualEditsDetected) { $detail += ", manual edits detected (backup preserved)" }

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber          = $stepNumber
    Passed              = $true
    Details             = $detail
    NextSteps           = @("Proceed to Step 0: Token Acquisition")
    TasRowCount         = $tasRows
    ManualEditsDetected = $manualEditsDetected
}
