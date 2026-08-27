<#
.SYNOPSIS
    Host-side Telegram monitoring loop for agent alerts and incoming commands.
.DESCRIPTION
    Runs as a background loop that:
      1. Polls Telegram for incoming messages → writes to Tasks/Telegram/
      2. Checks Tasks/Paused/ for stuck daemon workers → sends notification
      3. Checks Tasks/Failed/ for exhausted plans → sends notification
      4. Checks agent heartbeats for stale agents → sends notification
      5. Sends periodic heartbeat to confirm the monitor is alive

    Uses Invoke-TelegramPollingWithBackoff for resilient polling with
    exponential backoff and circuit-breaker.

.PARAMETER IntervalSec
    How often to run the full check cycle (default: 60).
.PARAMETER HeartbeatIntervalMins
    How often to send an "I'm alive" heartbeat (default: 60, 0 to disable).
#>
[CmdletBinding()]
param(
    [int]$IntervalSec = 60,
    [int]$HeartbeatIntervalMins = 60
)

# Ensure required modules are loaded
$moduleRoot = Join-Path $PSScriptRoot '..\Skills\Docker\Modules'
$telegramModule = Join-Path $moduleRoot 'SalmonRun.Telegram\SalmonRun.Telegram.ps1'
$coreModule = Join-Path $moduleRoot 'SalmonRun.Core\SalmonRun.Core.ps1'

if (Test-Path $coreModule) { . $coreModule }
if (Test-Path $telegramModule) { . $telegramModule }

# Repo root
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$tasksDir = Join-Path $repoRoot 'Tasks'

$lastHeartbeat = 0
$lastSeenPaused = @{}
$lastSeenFailed = @{}
$config = $null

function Get-MonitorConfig {
    $cfg = Get-TelegramConfig
    if ($cfg.IsConfigured) {
        Write-SetupLog "[TELEGRAM MONITOR] Configured for @$($cfg.OwnerUsername) (ID: $($cfg.OwnerUserId))"
    } else {
        Write-SetupLog "[TELEGRAM MONITOR] Telegram not configured — monitor running in log-only mode" -Level WARN
    }
    return $cfg
}

function Send-StatusMessage {
    param([string]$Message, [string]$Type = 'info')
    if (-not $config.IsConfigured) { return }
    $prefix = @{
        info    = ''
        warning = '⚠ '
        error   = '🚫 '
    }
    $full = "$($prefix[$Type])$Message"
    $null = Send-TelegramMessage -Message $full -Config $config -Silent:$($Type -ne 'error')
}

function Test-NewPausedItems {
    $pausedDir = Join-Path $tasksDir 'paused'
    if (-not (Test-Path $pausedDir)) { return }

    $files = Get-ChildItem "$pausedDir/*.md" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if (-not $lastSeenPaused.ContainsKey($f.Name)) {
            $lastSeenPaused[$f.Name] = (Get-Date)
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            $questions = @()
            if ($content -match '(?s)(\d+\..*?)(?=\n---|\Z)') {
                $questions = [regex]::Matches($content, '\*\*Q:\*\*\s*(.*?)(?:\n|$)') | ForEach-Object { $_.Groups[1].Value.Trim() }
            }
            $qSummary = if ($questions) { " — $($questions.Count) question(s)" } else { '' }
            Send-StatusMessage "Paused: $($f.Name)$qSummary" -Type 'warning'
        }
    }
}

function Test-NewFailedItems {
    $failedDir = Join-Path $tasksDir 'Failed'
    if (-not (Test-Path $failedDir)) { return }

    $files = Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.failure\.md$' }
    foreach ($f in $files) {
        if (-not $lastSeenFailed.ContainsKey($f.Name)) {
            $lastSeenFailed[$f.Name] = (Get-Date)
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            $reason = if ($content -match '\*\*reason\*\*:\s*(.*?)$') { $matches[1].Trim() } else { 'unknown' }
            Send-StatusMessage "Failed: $($f.Name) (reason: $reason)" -Type 'error'
        }
    }

    # Clean up stale entries
    $currentNames = @($files | ForEach-Object { $_.Name })
    $toRemove = @($lastSeenFailed.Keys | Where-Object { $_ -notin $currentNames })
    foreach ($k in $toRemove) { $lastSeenFailed.Remove($k) }
}

function Test-StaleAgents {
    $agentsDir = Join-Path $tasksDir 'Logs\agents'
    if (-not (Test-Path $agentsDir)) { return }

    $heartbeatFiles = Get-ChildItem "$agentsDir/*.heartbeat" -ErrorAction SilentlyContinue
    $staleCutoff = (Get-Date).AddMinutes(-5).ToString('o')

    foreach ($hf in $heartbeatFiles) {
        $content = Get-Content $hf.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $ts = $content.Trim()
        if ($ts -lt $staleCutoff) {
            $agentId = $hf.BaseName
            $pidFile = Join-Path $agentsDir "$agentId.pid"
            $pidAlive = $false
            if (Test-Path $pidFile) {
                $pid = Get-Content $pidFile -Raw -ErrorAction SilentlyContinue
                if ($pid -match '\d+') {
                    $pidAlive = Get-Process -Id $pid -ErrorAction SilentlyContinue -ErrorVariable ev | Select-Object -First 1
                }
            }
            if (-not $pidAlive) {
                Send-StatusMessage "Stale agent: $agentId (last heartbeat $ts)" -Type 'warning'
            }
        }
    }
}

# ─── Main polling action ──────────────────────────────────────────────────────

$pollAction = {
    $config = Get-TelegramConfig

    # 1. Poll for incoming messages
    if ($config.IsConfigured) {
        $null = Receive-TelegramMessages -Config $config
    }

    # 2. Check for new paused items
    Test-NewPausedItems

    # 3. Check for new failed items
    Test-NewFailedItems

    # 4. Check for stale agents
    Test-StaleAgents

    # 5. Periodic heartbeat
    if ($HeartbeatIntervalMins -gt 0 -and $config.IsConfigured) {
        $now = [datetime]::UtcNow
        $elapsed = ($now - (Get-Date '1970-01-01 00:00:00')).TotalMinutes
        if ($elapsed - $lastHeartbeat -ge $HeartbeatIntervalMins) {
            $lastHeartbeat = $elapsed
            $planSummary = "..."
            Send-StatusMessage "Monitor OK — running every ${IntervalSec}s"
        }
    }

    return $true
}

# ─── Initial setup ────────────────────────────────────────────────────────────

Write-SetupLog "[TELEGRAM MONITOR] Starting — interval: ${IntervalSec}s, heartbeat: ${HeartbeatIntervalMins}m"
$config = Get-MonitorConfig

if ($config.IsConfigured) {
    Send-StatusMessage "Monitor started — polling every ${IntervalSec}s"
}

# ─── Enter polling loop ───────────────────────────────────────────────────────

Invoke-TelegramPollingWithBackoff -PollAction $pollAction -BaseIntervalSec $IntervalSec -MaxBackoffSec 120 -CircuitBreakerThreshold 5 -CircuitBreakerIntervalSec 300
