#Requires -Version 7.0
Set-StrictMode -Off

$script:FailCount = 0
$script:Results = @()

<#
.SYNOPSIS
    Appends a timestamped entry to the setup log file.
    The log path is determined by SALMONRUN_SETUP_LOG env var (INTERCLAW_SETUP_LOG as fallback).
    If the env var is not set, logging is silently skipped.
    Each 0setup.ps1 run creates one log file stamped with the start time.
    All downstream scripts inherit the same log path via the env var.
.PARAMETER Message
    The message to log. A timestamp prefix is added automatically.
.PARAMETER Level
    Optional log level: INFO, WARN, ERROR, DEBUG. Defaults to INFO.
    DEBUG entries are for troubleshooting markers that don't appear in terminal output.
#>
function Write-SetupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",
        [string]$Agent = "",
        [string]$Phase = "",
        [string]$RunId = $env:INTERCLAW_RUN_ID
    )
    $LogPath = $env:SALMONRUN_SETUP_LOG
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = $env:INTERCLAW_SETUP_LOG
    }
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path $env:TEMP "salmonrun-setup-fallback.log"
        Write-Warning "SALMONRUN_SETUP_LOG or INTERCLAW_SETUP_LOG not set — falling back to temp path: $LogPath"
    }
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Log level filter -- skip messages below the configured minimum
    $currentMinLevel = switch ($env:INTERCLAW_LOG_LEVEL) {
        "DEBUG" { 0 }
        "INFO"  { 1 }
        "WARN"  { 2 }
        "ERROR" { 3 }
        default { 0 }
    }
    $msgLevelValue = switch ($Level) {
        "DEBUG" { 0 }
        "INFO"  { 1 }
        "WARN"  { 2 }
        "ERROR" { 3 }
    }
    if ($msgLevelValue -lt $currentMinLevel) { return }

    $UseJson = $env:INTERCLAW_LOG_FORMAT -eq "json"
    if ($UseJson) {
        $Entry = (@{
            timestamp = $Timestamp
            level     = $Level
            message   = $Message
            agent     = $Agent
            phase     = $Phase
            runId     = $RunId
        } | ConvertTo-Json -Compress)
    }
    else {
        $RunIdTag = if ($RunId) { " [$RunId]" } else { "" }
        $AgentTag = if ($Agent) { " [$Agent]" } else { "" }
        $PhaseTag = if ($Phase) { " [$Phase]" } else { "" }
        $Entry = "$Timestamp$RunIdTag$AgentTag$PhaseTag [$Level] $Message"
    }

    if (-not $script:SetupLogMutex) {
        if ($IsLinux -or $IsMacOS) {
            $script:SetupLogMutex = New-Object System.Threading.Mutex($false)
        } else {
            $script:SetupLogMutex = New-Object System.Threading.Mutex($false, "Global\SalmonRun-SetupLog-Mutex")
        }
    }
    $mtx = $script:SetupLogMutex
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mtx.WaitOne(5000)
            if (-not $lockTaken) {
                Write-Warning "Write-SetupLog: Mutex timeout (5s) ΓÇö skipping log entry"
                $mtx.Dispose()
                $mtx = $null
                return
            }
        } catch {
            Write-Warning "Write-SetupLog: Failed to create mutex: $($_.Exception.Message)"
            return
        }

        Add-Content -Path $LogPath -Value $Entry -Encoding UTF8NoBOM -ErrorAction Stop
    }
    catch {
        Write-Warning "Write-SetupLog: Failed to write to $LogPath ΓÇö $($_.Exception.Message)"
        try {
            $fallback = "$env:TEMP\ORCHESTRATOR-fallback.log"
            Add-Content -Path $fallback -Value $Entry -Encoding UTF8NoBOM -ErrorAction SilentlyContinue
        } catch { Write-Debug "Write-SetupLog: Fallback log write failed: $_" }
    }
    finally {
        if ($lockTaken) { try { $mtx.ReleaseMutex() } catch { Write-Debug "Write-SetupLog: Mutex release failed: $_" } }
    }

    # Tee WARN/ERROR to review log
    if ($Level -in @("WARN", "ERROR") -and $env:INTERCLAW_SETUP_WARN_LOG) {
        try {
            $ReviewEntry = "$Timestamp$RunIdTag$AgentTag$PhaseTag [$Level] $Message"
            Add-Content -Path $env:INTERCLAW_SETUP_WARN_LOG -Value $ReviewEntry -Encoding UTF8NoBOM -ErrorAction Stop
        } catch {
            Write-Warning "Write-SetupLog: Failed to write to warn log ΓÇö $($_.Exception.Message)"
            try {
                $fallback = "$env:TEMP\ORCHESTRATOR-fallback.log"
                Add-Content -Path $fallback -Value $ReviewEntry -Encoding UTF8NoBOM -ErrorAction SilentlyContinue
            } catch { Write-Debug "Write-SetupLog: Warn-log fallback write failed: $_" }
        }
    }

    # Terminal output (mirrors the old 0config.ps1 Write-Log behavior)
    switch ($Level) {
        "ERROR" { Write-Host "  [FAIL] $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
        "DEBUG" {
            if ($env:INTERCLAW_LOG_LEVEL -eq "DEBUG") {
                Write-Host "  $Message"
            }
        }
        default { Write-Host "  $Message" }
    }
}

<#
.SYNOPSIS
    Records a pass/fail test result. Increments global fail counter on failure.
    Used by health check and startup check scripts.
#>
function Test-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [bool]$Passed,
        [string]$Detail = "",
        [string]$Remediation = "",
        [switch]$PassThru
    )
    $Status = if ($Passed) { "PASS" } else { "FAIL" }
    $Color = if ($Passed) { "Green" } else { "Red" }
    $Msg = if ($Detail) { "  [$Status] $Name -- $Detail" } else { "  [$Status] $Name" }
    Write-Host $Msg -ForegroundColor $Color
    if (-not $Passed) { $script:FailCount++ }
    $script:Results += @{ Name = $Name; Passed = $Passed; Detail = $Detail; Remediation = $Remediation }
    if ($PassThru) { return [PSCustomObject]@{ Name = $Name; Passed = $Passed; Detail = $Detail; Remediation = $Remediation } }
}

<#
.SYNOPSIS
    Resolves the reports directory path.
    Prefers the container path, falls back to Tasks/Logs/ in the repo root.
#>
function Get-ReportsDir {
    $ContainerPath = Join-Path (Get-HomeDir) ".ORCHESTRATOR" "workspace" "reports"
    if (Test-Path $ContainerPath) { return $ContainerPath }
    $HostPath = Join-Path (Join-Path (Get-RepoRoot) "Tasks") "Logs"
    if (-not (Test-Path $HostPath)) {
        $null = New-Item -ItemType Directory -Path $HostPath -Force
    }
    return $HostPath
}

function Get-DeliverablesDir {
    $ContainerPath = Join-Path (Get-HomeDir) ".ORCHESTRATOR" "workspace" "deliverables"
    if (-not (Test-Path $ContainerPath)) {
        $null = New-Item -ItemType Directory -Path $ContainerPath -Force
    }
    $TrashPath = Join-Path $ContainerPath "Trash"
    if (-not (Test-Path $TrashPath)) {
        $null = New-Item -ItemType Directory -Path $TrashPath -Force
    }
    return $ContainerPath
}

