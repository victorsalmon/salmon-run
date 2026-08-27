<#
.SYNOPSIS
    Fleet-wide stale agent lock file cleanup across all repos under C:\Repos.
.DESCRIPTION
    Scans all git repos under C:\Repos for Tasks/Logs/agents/ directories.
    Removes .pid files whose process is no longer running, and .heartbeat
    files older than the stale threshold. Orphaned heartbeat files (no
    corresponding .pid) are also removed. All removals are logged to
    C:\Repos\salmon-orchestrator\Tasks\Logs\Audit\lock-cleanup.log.
.PARAMETER HeartbeatStaleThresholdSeconds
    Age in seconds beyond which a heartbeat is considered stale. Default 120.
.PARAMETER WhatIf
    If set, only reports what would be removed without deleting anything.
.PARAMETER ReposRoot
    Root directory containing git repos to scan. Default C:\Repos.
.EXAMPLE
    .\Clear-FleetStaleLocks.ps1
.EXAMPLE
    .\Clear-FleetStaleLocks.ps1 -WhatIf
.EXAMPLE
    .\Clear-FleetStaleLocks.ps1 -HeartbeatStaleThresholdSeconds 300
#>
param(
    [int]$HeartbeatStaleThresholdSeconds = 120,
    [switch]$WhatIf,
    [string]$ReposRoot = "C:\Repos"
)

# Audit log lives in the orchestrator repo, not the bare $ReposRoot scan dir,
# so it is kept with the rest of the fleet state. ($ReposRoot is still used
# below to enumerate repos for scanning.) This script lives at
# C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\ (3 levels under the repo root).
$orchestratorRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
$auditLogDir = Join-Path $orchestratorRoot "Tasks\Logs\Audit"
$null = New-Item -ItemType Directory -Path $auditLogDir -Force
$logFile = Join-Path $auditLogDir "lock-cleanup.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-AuditLog {
    param([string]$Message)
    $line = "[$timestamp] $Message"
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Host $line
}

function Convert-PidSafe {
    param([string]$Value)
    $trimmed = $Value.Trim()
    if ($trimmed -match '^\d+$') { return [int]$trimmed }
    return $null
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-HeartbeatStale {
    param([string]$HeartbeatPath, [int]$ThresholdSeconds)
    if (-not (Test-Path $HeartbeatPath)) { return $true }
    try {
        $content = (Get-Content $HeartbeatPath -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($content)) { return $true }
        $hbUtc = [datetime]::Parse($content, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $ageSeconds = ([datetime]::UtcNow - $hbUtc).TotalSeconds
        return $ageSeconds -gt $ThresholdSeconds
    } catch {
        return $true
    }
}

$repos = Get-ChildItem -LiteralPath $ReposRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") }
$totalRemoved = 0
$removedFiles = [System.Collections.Generic.List[string]]::new()

Write-AuditLog "=== CLEAN-FLEET-STALE-LOCKS start (threshold=${HeartbeatStaleThresholdSeconds}s) ==="

foreach ($repo in $repos) {
    $agentDir = Join-Path $repo.FullName "Tasks\Logs\agents"
    if (-not (Test-Path $agentDir)) { continue }

    Write-Host "Scanning $($repo.Name)/Tasks/Logs/agents/..."

    Get-ChildItem "$agentDir\*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
        $agentId = $_.BaseName
        $pidPath = $_.FullName
        $hbPath = Join-Path $agentDir "$agentId.heartbeat"

        try {
            $pidContent = (Get-Content $pidPath -Raw -ErrorAction Stop).Trim()
            $parsedPid = Convert-PidSafe -Value $pidContent
            $processAlive = if ($parsedPid) { Test-ProcessAlive -Pid $parsedPid } else { $false }
            $heartbeatStale = Test-HeartbeatStale -HeartbeatPath $hbPath -ThresholdSeconds $HeartbeatStaleThresholdSeconds

            $removeReason = $null
            if (-not $processAlive) { $removeReason = "process-dead (pid=$parsedPid)" }
            elseif ($heartbeatStale) { $removeReason = "heartbeat-stale" }

            if ($removeReason) {
                $msg = "repo=$($repo.Name) agent=$agentId type=pid pid=$parsedPid reason=$removeReason"
                if (-not $WhatIf) {
                    Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
                    if (Test-Path $hbPath) {
                        Remove-Item $hbPath -Force -ErrorAction SilentlyContinue
                        $msg += " +heartbeat"
                    }
                    Write-AuditLog "REMOVED $msg"
                } else {
                    Write-AuditLog "WOULD-REMOVE $msg"
                }
                $removedFiles.Add("repo=$($repo.Name) agent=$agentId reason=$removeReason")
                $totalRemoved++
            }
        } catch {
            Write-AuditLog "ERROR repo=$($repo.Name) agent=$agentId error='$_'"
        }
    }

    Get-ChildItem "$agentDir\*.heartbeat" -ErrorAction SilentlyContinue | ForEach-Object {
        $agentId = $_.BaseName
        $pidPath = Join-Path $agentDir "$agentId.pid"
        if (-not (Test-Path $pidPath)) {
            $stale = Test-HeartbeatStale -HeartbeatPath $_.FullName -ThresholdSeconds $HeartbeatStaleThresholdSeconds
            if ($stale) {
                $msg = "repo=$($repo.Name) agent=$agentId type=heartbeat reason=orphan-stale"
                if (-not $WhatIf) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    Write-AuditLog "REMOVED $msg"
                } else {
                    Write-AuditLog "WOULD-REMOVE $msg"
                }
                $removedFiles.Add("repo=$($repo.Name) agent=$agentId reason=orphan-stale")
                $totalRemoved++
            }
        }
    }
}

Write-AuditLog "=== CLEAN-FLEET-STALE-LOCKS complete totalRemoved=$totalRemoved ==="

[PSCustomObject]@{
    RemovedCount = $totalRemoved
    RemovedFiles = $removedFiles.ToArray()
    WhatIf       = $WhatIf.IsPresent
    LogFile      = $logFile
}
exit 0
