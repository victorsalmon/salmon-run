<#
.SYNOPSIS
    Repair Windows file associations for .ps1 and .psm1 to execute with pwsh.exe.

.DESCRIPTION
    Idempotent fix for .ps1 and .psm1 file associations that may have been
    set to editors (Notepad, ISE) instead of pwsh.exe on clean Windows installs.
    Detects the current pwsh.exe path, creates the Microsoft.PowerShellScript.1
    ProgId if missing, and clears conflicting per-user UserChoice overrides.

    Must run as Administrator (assoc/ftype are machine-level).

.EXAMPLE
    .\Repair-PowerShellFileAssociations.ps1
    Checks and fixes associations, reports what changed.

.EXAMPLE
    .\Repair-PowerShellFileAssociations.ps1 -WhatIf
    Dry-run: shows what would be fixed without making changes.

.NOTES
    Author: ORCHESTRATOR
    RunFix: Skills/Workflows/RunFix/runfix-repair-pwsh-associations.md
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param()

$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$targetProgId = 'Microsoft.PowerShellScript.1'

# Check elevation (assoc/ftype require admin)
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated -and -not $WhatIfPreference) {
    Write-Error "This script requires Administrator privileges. Run from an elevated PowerShell prompt."
    exit 1
}

$changes = @()

# --- Step 1: Ensure target ProgId exists ---
$currentFtype = & cmd /c ftype $targetProgId 2>$null
if ($LASTEXITCODE -ne 0 -or ("$currentFtype").Trim() -notmatch [regex]::Escape($pwshPath)) {
    $newFtype = "$targetProgId=`"$pwshPath`" `"%1`""
    $changes += "ftype $newFtype"
    if ($PSCmdlet.ShouldProcess($targetProgId, "Set ftype to $pwshPath")) {
        & cmd /c ftype $newFtype
    }
}

# --- Step 2: Fix .psm1 association ---
$currentPsm1 = & cmd /c assoc .psm1 2>$null
if ($LASTEXITCODE -ne 0 -or ("$currentPsm1").Trim() -ne ".psm1=$targetProgId") {
    $changes += "assoc .psm1=$targetProgId"
    if ($PSCmdlet.ShouldProcess('.psm1', "Associate with $targetProgId")) {
        & cmd /c assoc ".psm1=$targetProgId"
        # Clear per-user override that may conflict
        $userChoicePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psm1\UserChoice'
        if (Test-Path $userChoicePath) {
            Remove-Item -Path $userChoicePath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Step 3: Fix .ps1 association ---
$currentPs1 = & cmd /c assoc .ps1 2>$null
if ($LASTEXITCODE -ne 0 -or ("$currentPs1").Trim() -ne ".ps1=$targetProgId") {
    $changes += "assoc .ps1=$targetProgId"
    if ($PSCmdlet.ShouldProcess('.ps1', "Associate with $targetProgId")) {
        & cmd /c assoc ".ps1=$targetProgId"
        # Clear per-user override that may conflict
        $userChoicePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice'
        if (Test-Path $userChoicePath) {
            Remove-Item -Path $userChoicePath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Report ---
if ($changes.Count -eq 0) {
    Write-Host "All PowerShell file associations are correct (pwsh at $pwshPath)." -ForegroundColor Green
} else {
    Write-Host "Fixed $($changes.Count) issue(s):" -ForegroundColor Yellow
    $changes | ForEach-Object { Write-Host "  $_" }
    Write-Host "Log out/in or reboot for changes to take full effect." -ForegroundColor Cyan
}
