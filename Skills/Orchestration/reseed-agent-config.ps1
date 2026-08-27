<#
.SYNOPSIS
    Re-seeds agent config files (agents.md etc.) into the Docker config volume and restarts the service.
.DESCRIPTION
    Thin CLI wrapper around Invoke-AgentReseed. Delegates all reseed logic to the module function.
.PARAMETER Role
    Agent role to refresh (ORCH, VERI, BASE). Default: ORCH.
.PARAMETER Index
    Instance index (0 for first instance). Default: 0.
.PARAMETER StackName
    Docker stack name. Auto-detected via Get-StackName if not provided.
.PARAMETER File
    Specific file(s) to re-seed (e.g. "agents.md"). Default: all role files + shared files.
.PARAMETER Force
    Skip the confirmation prompt before restarting.
.PARAMETER NoRestart
    Re-seed only, do not restart the service.
.EXAMPLE
    PS> Scripts/Admin/reseed-agent-config.ps1 -Role ORCH -Force
    Re-seeds all ORCH config files and restarts without prompting.
.EXAMPLE
    PS> Scripts/Admin/reseed-agent-config.ps1 -Role VERI -File agents.md -NoRestart
    Re-seeds only agents.md for VERI, no restart.
#>
#Requires -Version 7.0

param(
    [string]$Role = "ORCH",
    [int]$Index = 0,
    [string]$StackName,
    [string[]]$File,
    [switch]$Force,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Get-Module ORCHESTRATOR.Core)) {
    $__ocCorePsd1 = Join-Path $__ocRepoRoot "Scripts" "Modules" "ORCHESTRATOR.Core" "ORCHESTRATOR.Core.psd1"
    Import-Module -Name $__ocCorePsd1 -Force -DisableNameChecking
}
Import-InterclawModule Core

# --- Resolve stack name ---
if (-not $StackName) {
    if (Get-Command Get-StackName -ErrorAction SilentlyContinue) {
        $StackName = Get-StackName
    }
    if (-not $StackName -and $env:INSTALL_PROJECT) {
        $StackName = $env:INSTALL_PROJECT.ToLower()
    }
    if (-not $StackName) {
        Write-SetupLog -Message "Could not resolve stack name. Pass -StackName or set INSTALL_PROJECT." -Level ERROR
        exit 1
    }
}

# --- Verify target service exists ---
$SvcName = Get-AgentServiceName -Role $Role -Index $Index
$FullSvcName = "${StackName}_${SvcName}"
$SvcExists = docker service ls --filter "name=$FullSvcName" --format "{{.Name}}" 2>$null
if (-not $SvcExists) {
    Write-SetupLog -Message "Service '$FullSvcName' not found." -Level ERROR
    exit 1
}

Write-Host "`n=== Re-seed Agent Config: $Role (index=$Index) ===" -ForegroundColor Cyan
Write-Host "  Stack: $StackName" -ForegroundColor Gray

# --- Delegate to Invoke-AgentReseed ---
try {
    $result = Invoke-AgentReseed -StackName $StackName -Roles @($Role) -File $File -Restart:(-not $NoRestart) -Force:$Force
    $exitCode = if ($result.Failed -gt 0) { 1 } else { 0 }
}
catch {
    Write-SetupLog -Message "Reseed failed: $($_.Exception.Message)" -Level ERROR
    exit 1
}

exit $exitCode
