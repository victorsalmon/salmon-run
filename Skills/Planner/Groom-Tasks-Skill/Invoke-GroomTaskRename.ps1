<#
.SYNOPSIS
    Executes renames suggested by Invoke-GroomTaskInventory.ps1 -FixNames.
.DESCRIPTION
    Takes a list of Current → Suggested rename pairs and executes them
    atomically. Dry-run by default (reports what would change without
    actually renaming). Use -Apply to execute.

    Called by Invoke-GroomTaskInventory.ps1 when passed -FixNames -Apply.
    Can also be run standalone with -RenamesJson.
.PARAMETER Renames
    Array of hashtables with Current and Suggested keys.
.PARAMETER RenamesJson
    Path to a JSON file containing the rename array, or a JSON string.
.PARAMETER TaskDir
    Directory containing the files to rename.
.PARAMETER Apply
    Actually execute the renames. Without this, dry-run only.
.PARAMETER LogFile
    Path to write a rename log.
.EXAMPLE
    $renames = @(@{Current="old.md"; Suggested="new.md"})
    .\Invoke-GroomTaskRename.ps1 -Renames $renames -TaskDir Tasks/Code/ -Apply
#>
param(
    [object[]]$Renames,
    [string]$RenamesJson,
    [string]$TaskDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")) "Tasks\Code"),
    [switch]$Apply,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"

# Parse input
if ($RenamesJson) {
    if (Test-Path $RenamesJson) {
        $Renames = Get-Content -Path $RenamesJson -Raw | ConvertFrom-Json
    } else {
        $Renames = $RenamesJson | ConvertFrom-Json
    }
}

if (-not $Renames -or $Renames.Count -eq 0) {
    Write-Host "No renames to process." -ForegroundColor Yellow
    exit 0
}

$log = [System.Collections.Generic.List[string]]::new()
$log.Add("Groom Task Rename Log — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$log.Add("")

$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($r in $Renames) {
    $current = if ($r.Current) { $r.Current } else { $r.current }
    $suggested = if ($r.Suggested) { $r.Suggested } else { $r.suggested }

    $oldPath = Join-Path $TaskDir $current
    $newPath = Join-Path $TaskDir $suggested

    if (-not (Test-Path $oldPath)) {
        $log.Add("SKIP: $current → $suggested (source not found)")
        $skipCount++
        continue
    }

    if ($current -eq $suggested) {
        $skipCount++
        continue
    }

    if ((Test-Path $newPath) -and $Apply) {
        $log.Add("ERROR: $current → $suggested (target already exists)")
        Write-Host "  ✗ $current → $suggested (target exists)" -ForegroundColor Red
        $errorCount++
        continue
    }

    if ($Apply) {
        try {
            Rename-Item -Path $oldPath -NewName $suggested -ErrorAction Stop
            $log.Add("OK: $current → $suggested")
            Write-Host "  ✓ $current → $suggested" -ForegroundColor Green
            $successCount++
        } catch {
            $log.Add("ERROR: $current → $suggested ($($_.Exception.Message))")
            Write-Host "  ✗ $current → $suggested ($($_.Exception.Message))" -ForegroundColor Red
            $errorCount++
        }
    } else {
        $log.Add("DRY-RUN: $current → $suggested")
        Write-Host "  ~ $current → $suggested" -ForegroundColor Cyan
        $successCount++
    }
}

$log.Add("")
$log.Add("Summary: $successCount renamed, $skipCount skipped, $errorCount errors")

if ($LogFile) {
    $log | Out-File -FilePath $LogFile -Encoding utf8
    Write-Host "Log written to $LogFile" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Summary: $successCount renamed, $skipCount skipped, $errorCount errors" -ForegroundColor Cyan

if (-not $Apply) {
    Write-Host "(Pass -Apply to execute these renames)" -ForegroundColor DarkGray
}

exit $errorCount
