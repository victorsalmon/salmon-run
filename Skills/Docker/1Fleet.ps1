<#
.SYNOPSIS
    Fleet runtime entrypoint. Runs fleet health checks with auto-remediation, startup verification, and periodic system updates.
.DESCRIPTION
    The main entrypoint for the is-fleet container. Supports four modes:
    Entrypoint — main fleet loop (default). Runs continuous health checks, remediation,
    system updates, and task dispatch polling.
    HealthCheck — run fleet health check once and exit.
    StartupCheck — run post-deploy startup verification once.
    Update — run system update once.
.PARAMETER Mode
    Operating mode. Supported: Entrypoint, HealthCheck, StartupCheck, Update.
    Entrypoint is the default and starts the continuous fleet management loop.
.EXAMPLE
    .\1Fleet.ps1
    Start the continuous fleet management loop (default Entrypoint mode).
.EXAMPLE
    .\1Fleet.ps1 -Mode HealthCheck
    Run a single fleet health check and exit.
.NOTES
    File: 1Fleet.ps1
    Requires: PowerShell 7.0+, Docker socket access (/var/run/docker.sock)
    See-also: deploy.ps1, 1Deploy.ps1
#>
# ==============================================================================
# Interclaw — 1Fleet.ps1 (v2.0 - Fleet Runtime)
# ==============================================================================
# Entrypoint for the fleet container. Combines:
#   1. Main loop (health checks, remediation, system updates, task dispatch)
#   2. Fleet health check with auto-remediation
#   3. Post-deploy startup verification
#   4. Periodic system update
#
# Modes:
#   Entrypoint    — Main fleet loop (default)
#   HealthCheck   — Run fleet health check once
#   StartupCheck  — Run post-deploy startup verification once
#   Update        — Run system update once
# ==============================================================================

param(
    [ValidateSet("Entrypoint","HealthCheck","StartupCheck","Update")]
    [string]$Mode = "Entrypoint",
    [switch]$MaintenanceMode
)

$ErrorActionPreference = "Continue"

# Detect container context — some paths are container-only
$script:InContainer = Test-Path "/run/secrets" -PathType Container

# Bootstrap: detect repo root using AGENTS.md marker (works in both host and container layouts)
$__ocParent = Split-Path $PSScriptRoot -Parent
$__ocRepoRoot = if (Test-Path (Join-Path $__ocParent "AGENTS.md")) { $__ocParent } else { Split-Path $__ocParent -Parent }
$__ocModulesDir = Join-Path $__ocRepoRoot "Skills" "Docker" "Modules"
$__ocSalmonModulesDir = Join-Path $__ocRepoRoot "Skills" "Orchestrator" "Salmon" "Modules"
$env:PSModulePath = "$__ocModulesDir$([System.IO.Path]::PathSeparator)$__ocSalmonModulesDir$([System.IO.Path]::PathSeparator)$env:PSModulePath"
try {
    $__moduleLoaderPath = Join-Path $__ocSalmonModulesDir "SalmonRun.ModuleLoader" "SalmonRun.ModuleLoader.psd1"
    if (-not (Test-Path $__moduleLoaderPath)) { $__moduleLoaderPath = Join-Path $__ocModulesDir "SalmonRun.ModuleLoader" "SalmonRun.ModuleLoader.psd1" }
    Import-Module $__moduleLoaderPath -Force -DisableNameChecking -ErrorAction Stop
    Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot

    Import-InterclawModule Core
    Import-InterclawModule Config
    Import-InterclawModule Constants
    Import-InterclawModule Identity
    Import-InterclawModule Secrets
    Import-InterclawModule Fleet
} catch {
    if (-not $script:InContainer) {
        Write-Warning "1Fleet.ps1 running outside container — modules not loaded. Some features unavailable."
        return
    }
    throw
}

# ==============================================================================
# FLEET HEALTH STATE (owned by SalmonRun.Fleet module — access via module accessors)
# ==============================================================================
$fleetHealthState = Get-FleetHealthState
if ($null -eq $fleetHealthState) {
    Write-SetupLog "Fleet health state warm-up returned no state — initializing fresh" -Level WARN
}
Update-FleetHealthState -Properties @{
    Hostname  = $env:HOSTNAME
    StackName = (Get-StackName)
    StartTime = [DateTime]::UtcNow
}

$FleetReportsDir = "/home/node/.ORCHESTRATOR/workspace/Tasks/Logs"
# Idempotent create — no existence-check guard (TOCTOU-safe): New-Item -Force succeeds whether or not the dir exists.
$null = New-Item -ItemType Directory -Path $FleetReportsDir -Force -ErrorAction Stop
$FleetDeliverablesDir = "/home/node/.ORCHESTRATOR/workspace/deliverables"
# Idempotent create — no existence-check guard (TOCTOU-safe): New-Item -Force succeeds whether or not the dir exists.
$null = New-Item -ItemType Directory -Path (Join-Path $FleetDeliverablesDir "Trash") -Force -ErrorAction Stop
$FleetLogPath = Join-Path $FleetReportsDir "fleet-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Set-Content -Path $FleetLogPath -Value "# Interclaw Fleet Log — $(Get-Date -Format 'o')" -Encoding UTF8
Set-Item -Path "Env:\INTERCLAW_SETUP_LOG" -Value $FleetLogPath

if (-not $env:INTERCLAW_LOG_LEVEL) { $env:INTERCLAW_LOG_LEVEL = "INFO" }
Write-SetupLog "Log level: $env:INTERCLAW_LOG_LEVEL" -Level INFO

$InstallJson = Read-InstallJson -Path "/home/node/app/install.json"
if ($null -ne $InstallJson) { Export-InstallJsonToEnv -InstallJson $InstallJson -Force }

# ==============================================================================
# MODE DISPATCH
# ==============================================================================
if ($Mode -eq "Entrypoint") {
    if ($MaintenanceMode) {
        $markerPath = Join-Path $PWD "Tasks/Logs/.maintenance-mode"
        "Suppressed via -MaintenanceMode flag at $(Get-Date -Format 'o')" | Set-Content -Path $markerPath -Encoding UTF8 -Force
        Write-SetupLog "Maintenance mode enabled via flag — health checks suppressed" -Level WARN
    }
    while ($true) {
        try {
            Invoke-FleetEntrypoint
            break
        } catch {
            Write-SetupLog "FATAL: Fleet entrypoint loop crashed: $($_.Exception.Message)" -Level ERROR
            Write-SetupLog "Stack: $($_.ScriptStackTrace)" -Level ERROR
            # Jittered crash-retry backoff (30-44s) — bounded delay prevents a tight restart loop overloading the host.
            Start-Sleep -Seconds (30 + (Get-Random -Maximum 15))
        }
    }
}
elseif ($Mode -eq "HealthCheck") {
    Invoke-FleetHealthCheck
}
elseif ($Mode -eq "StartupCheck") {
    Invoke-FleetStartupVerification -StartupDelay
}

