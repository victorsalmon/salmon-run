<#
.SYNOPSIS
    Boot-time Docker Desktop starter with WSL2 reset. Called by Windows Scheduled Task "Interclaw-DockerDesktop-Boot".
.DESCRIPTION
    Runs silently at user logon (90s delay). Resets WSL2 to ensure clean state,
    then starts Docker Desktop and waits for the daemon to be reachable.
    Logs to Tasks/Logs/docker-boot.log for diagnostics.
#>
#Requires -Version 7.0

# Resolve repo root from script location
$__ocRepoRoot = Split-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) -Parent

if (-not (Get-Module SalmonRun.Core -ErrorAction SilentlyContinue)) {
    $__ocCorePsd1 = Join-Path $__ocRepoRoot "Skills" "Docker" "Modules" "SalmonRun.Core" "SalmonRun.Core.psd1"
    Import-Module -Name $__ocCorePsd1 -Force -DisableNameChecking
}
Import-InterclawModule Core
Import-InterclawModule Host

$LogDir = Join-Path $__ocRepoRoot "Tasks" "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "docker-boot.log"

try {
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Docker Desktop boot-start triggered" -Encoding utf8

    $Result = Start-DockerDesktop -ResetWsl -MaxAttempts 300

    if ($Result) {
        Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Docker Desktop ready" -Encoding utf8
    }
    else {
        Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Docker Desktop failed to start" -Encoding utf8
    }
}
catch {
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $_" -Encoding utf8
}
