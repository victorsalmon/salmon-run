#Requires -Version 7.0
<#
.SYNOPSIS
    Re-associates .ps1 and .psm1 file extensions with PowerShell 7 (pwsh.exe) in HKCU.
.DESCRIPTION
    Antigravity IDE's installer registers custom ProgIDs (Antigravity.psm1, AntigravityIDE.psm1, etc.)
    in HKCU:\SOFTWARE\Classes\ that shadow the proper PowerShell handlers. When Microsoft.PowerShellModule.1
    has no shell\open\command, Windows falls through the OpenWithList to Antigravity and launches the IDE.

    This script creates the missing shell\open\command entries in HKCU (user-level, no admin needed)
    and sets .psm1 / .ps1 to the proper PowerShell ProgIDs.

    Idempotent — safe to re-run after Antigravity updates that may reset the associations.
.NOTES
    Author: opencode (Code mode, 2026-06-14)
    Run as: current user (no elevation required)
    See also: Tasks/Manual/2026-06-14-fix-psm1-file-association.md
#>
[CmdletBinding()]
param(
    [string]$PwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PwshPath)) {
    throw "pwsh.exe not found at: $PwshPath. Pass -PwshPath to specify the correct location."
}

Write-Host "=== Fix-PowerShellFileAssociation.ps1 ===" -ForegroundColor Cyan
Write-Host "pwsh path: $PwshPath"
Write-Host ""

# 1. .psm1 → Microsoft.PowerShellModule.1
$psm1Default = "Microsoft.PowerShellModule.1"
$psm1Path = "HKCU:\SOFTWARE\Classes\.psm1"
if (-not (Test-Path $psm1Path)) { New-Item -Path $psm1Path -Force | Out-Null }
Set-ItemProperty -Path $psm1Path -Name "(default)" -Value $psm1Default -Force
Write-Host "[1/4] Set .psm1 default to $psm1Default" -ForegroundColor Green

# 2. Microsoft.PowerShellModule.1\shell\open\command
$psm1ProgId = "HKCU:\SOFTWARE\Classes\Microsoft.PowerShellModule.1"
$psm1Cmd = "`"$PwshPath`" -NoExit -Command ""Import-Module '%1'"""
if (-not (Test-Path $psm1ProgId)) { New-Item -Path $psm1ProgId -Force | Out-Null }
$psm1Shell = "$psm1ProgId\shell\open\command"
if (-not (Test-Path $psm1Shell)) { New-Item -Path $psm1Shell -Force | Out-Null }
Set-ItemProperty -Path $psm1Shell -Name "(default)" -Value $psm1Cmd -Force
Write-Host "[2/4] Set Microsoft.PowerShellModule.1 shell\open\command to pwsh.exe (Import-Module)" -ForegroundColor Green

# 3. .ps1 → Microsoft.PowerShellScript.1
$ps1Default = "Microsoft.PowerShellScript.1"
$ps1Path = "HKCU:\SOFTWARE\Classes\.ps1"
if (-not (Test-Path $ps1Path)) { New-Item -Path $ps1Path -Force | Out-Null }
Set-ItemProperty -Path $ps1Path -Name "(default)" -Value $ps1Default -Force
Write-Host "[3/4] Set .ps1 default to $ps1Default" -ForegroundColor Green

# 4. Microsoft.PowerShellScript.1\shell\open\command
$ps1ProgId = "HKCU:\SOFTWARE\Classes\Microsoft.PowerShellScript.1"
$ps1Cmd = "`"$PwshPath`" -NoExit -File ""%1"""
if (-not (Test-Path $ps1ProgId)) { New-Item -Path $ps1ProgId -Force | Out-Null }
$ps1Shell = "$ps1ProgId\shell\open\command"
if (-not (Test-Path $ps1Shell)) { New-Item -Path $ps1Shell -Force | Out-Null }
Set-ItemProperty -Path $ps1Shell -Name "(default)" -Value $ps1Cmd -Force
Write-Host "[4/4] Set Microsoft.PowerShellScript.1 shell\open\command to pwsh.exe (run script)" -ForegroundColor Green

# 5. Clean Antigravity from .psm1 OpenWithList (was the trigger)
$openWithList = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psm1\OpenWithList"
if (Test-Path $openWithList) {
    $existing = Get-ItemProperty $openWithList -ErrorAction SilentlyContinue
    if ($existing.'a' -eq 'Antigravity.exe') {
        Remove-ItemProperty -Path $openWithList -Name "a" -ErrorAction SilentlyContinue
        Write-Host "[+] Removed Antigravity from .psm1 OpenWithList" -ForegroundColor Green
    }
    $mru = (Get-ItemProperty $openWithList -ErrorAction SilentlyContinue).MRUList
    if ($mru) {
        Remove-ItemProperty -Path $openWithList -Name "MRUList" -ErrorAction SilentlyContinue
        Write-Host "[+] Cleared .psm1 OpenWithList MRUList" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan
Write-Host ".psm1 default:   $((Get-ItemProperty 'HKCU:\SOFTWARE\Classes\.psm1' -ErrorAction SilentlyContinue).'(default)')"
Write-Host "psm1 command:    $((Get-ItemProperty 'HKCU:\SOFTWARE\Classes\Microsoft.PowerShellModule.1\shell\open\command' -ErrorAction SilentlyContinue).'(default)')"
Write-Host ".ps1 default:    $((Get-ItemProperty 'HKCU:\SOFTWARE\Classes\.ps1' -ErrorAction SilentlyContinue).'(default)')"
Write-Host "ps1 command:     $((Get-ItemProperty 'HKCU:\SOFTWARE\Classes\Microsoft.PowerShellScript.1\shell\open\command' -ErrorAction SilentlyContinue).'(default)')"
Write-Host ""
Write-Host "Done. .psm1 and .ps1 files will now open in pwsh.exe instead of launching Antigravity." -ForegroundColor Cyan
Write-Host "Re-run this script if Antigravity overrides the associations on update."
