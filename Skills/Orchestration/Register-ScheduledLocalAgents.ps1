<#
.DEPRECATED
    The Sentry poller (Start-SentrySchedulePoller) is the canonical scheduler.
    This script registered a Windows scheduled task to run the local poller,
    which is now deprecated. Kept for reference only — do not use.
#>

param(
    [switch]$WhatIf,
    [string]$Date = (Get-Date -Format "yyyy/MM/dd")
)

$ErrorActionPreference = "Stop"
$repo = "C:\Users\Victor\intersite-orchestrator"
$pwsh = (Get-Command pwsh.exe).Source

# Rename old discrete tasks to Legacy (backward compat)
$legacyTasks = @(
    "ORCHESTRATOR-ArchitecturalAudit",
    "ORCHESTRATOR-CodeDrain",
    "ORCHESTRATOR-ReviewDrain"
)

foreach ($legacyName in $legacyTasks) {
    $renameArg = "/CHANGE /TN `"$legacyName`" /DISABLE"
    $legacyNewName = "ORCHESTRATOR-Legacy-$legacyName"
    $queryResult = schtasks /Query /TN "$legacyName" 2>$null
    if ($LASTEXITCODE -eq 0) {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would rename '$legacyName' to '$legacyNewName' and disable" -ForegroundColor DarkGray
        } else {
            Write-Host "Disabling legacy task '$legacyName'..." -NoNewline
            $null = schtasks /CHANGE /TN "$legacyName" /DISABLE 2>&1
            Write-Host " disabled" -ForegroundColor DarkGray
        }
    }
}

# Create single recurring poller task
$pollerScript = Join-Path $repo "Skills\\Orchestration\Start-LocalSchedulePoller.ps1"
$tr = "`"$pwsh`" -NoProfile -NoLogo -File `"$pollerScript`""
$taskName = "ORCHESTRATOR-LocalSchedulePoller"
$taskArg = "/CREATE /SC HOURLY /TN `"$taskName`" /TR $tr /RU $env:USERNAME /IT /RL HIGHEST /F /ST 00:00"

if ($WhatIf) {
    Write-Host "[WhatIf] schtasks $taskArg" -ForegroundColor DarkGray
} else {
    Write-Host "Creating task '$taskName' (recurring hourly)..." -NoNewline
    $result = schtasks.exe $taskArg 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Host " FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        Write-Host "  $result" -ForegroundColor Yellow
    }
}

if (-not $WhatIf) {
    Write-Host ""
    Write-Host "Tasks configured. Verify: schtasks /Query /FO LIST /V | Select-String ORCHESTRATOR -Context 0,15" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Notes:" -ForegroundColor Cyan
    Write-Host "  - ORCHESTRATOR-LocalSchedulePoller runs hourly on logon" -ForegroundColor DarkGray
    Write-Host "  - Legacy tasks (ORCHESTRATOR-ArchitecturalAudit, CodeDrain, ReviewDrain) are disabled" -ForegroundColor DarkGray
    Write-Host "  - /IT (Interactive only): runs when user is logged in (including locked screen)" -ForegroundColor DarkGray
    Write-Host "  - /RL HIGHEST: highest privilege level" -ForegroundColor DarkGray
}
