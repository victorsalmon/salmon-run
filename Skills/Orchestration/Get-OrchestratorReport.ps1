<#
.SYNOPSIS
    Prints a readable orchestrator state report to stdout.
    Shows queue sizes, running agents, working files, and completed sessions.
    Works with or without ORCHESTRATOR.Core loaded.
.DESCRIPTION
    Provides visibility into orchestrator state without reading raw log files.
    Reports:
      - Coder queue count (root Tasks/Code/*.md)
      - Reviewer queue count (Tasks/Review/*.md)
      - Per-file status in Tasks/Working/ with agent classification
      - Completed session paths from Tasks/Complete/
.EXAMPLE
    ./Scripts/Admin/Get-OrchestratorReport.ps1
#>

$ORCHESTRATORDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ─── Try to load ORCHESTRATOR.Core for Test-AgentAlive ──────────────────────
try {
    Import-Module ORCHESTRATOR.Core -ErrorAction Stop
} catch {
    # Fallback: define a minimal Test-AgentAlive
    function Test-AgentAlive {
        param([string]$AgentId, [int]$HeartbeatStaleThresholdSeconds = 120)
        $repoRoot = $ORCHESTRATORDir
        $agentDir = Join-Path $repoRoot "Tasks" "Logs" "agents"
        $pidPath = Join-Path $agentDir "$AgentId.pid"
        $hbPath = Join-Path $agentDir "$AgentId.heartbeat"

        $result = [PSCustomObject]@{
            AgentId               = $AgentId
            Pid                   = $null
            ProcessAlive          = $false
            HasPidFile            = $false
            HasHeartbeat          = $false
            HeartbeatAgeSeconds   = $null
            HeartbeatStale        = $false
            Stale                 = $false
        }

        if (Test-Path $pidPath) {
            $result.HasPidFile = $true
            try {
                $pidContent = (Get-Content $pidPath -Raw -ErrorAction Stop).Trim()
                if (-not [string]::IsNullOrWhiteSpace($pidContent)) {
                    $parsedPid = [int]::Parse($pidContent)
                    $result.Pid = $parsedPid
                    $result.ProcessAlive = [bool](Get-Process -Id $parsedPid -ErrorAction SilentlyContinue)
                }
            } catch {}
        }

        if (Test-Path $hbPath) {
            $result.HasHeartbeat = $true
            try {
                $hbContent = (Get-Content $hbPath -Raw -ErrorAction Stop).Trim()
                if (-not [string]::IsNullOrWhiteSpace($hbContent)) {
                    $hbUtc = [datetime]::Parse($hbContent, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    $result.HeartbeatAgeSeconds = ([datetime]::UtcNow - $hbUtc).TotalSeconds
                    $result.HeartbeatStale = $result.HeartbeatAgeSeconds -gt $HeartbeatStaleThresholdSeconds
                }
            } catch {}
        }

        if ($result.HasPidFile -and -not $result.ProcessAlive) {
            $result.Stale = $true
        } elseif (-not $result.HasPidFile -and -not $result.HasHeartbeat) {
            $result.Stale = $false
        } elseif ($result.HasPidFile -and $result.ProcessAlive -and $result.HasHeartbeat -and $result.HeartbeatAgeSeconds -gt (2 * $HeartbeatStaleThresholdSeconds)) {
            $result.Stale = $true
        } elseif ($result.HasPidFile -and $result.ProcessAlive -and (-not $result.HasHeartbeat -or $result.HeartbeatAgeSeconds -le $HeartbeatStaleThresholdSeconds)) {
            $result.Stale = $false
        }

        return $result
    }
}

# ─── Helper: Extract agent ID from Lock Header ─────────────────────────
function Get-LockAgent {
    param([string]$FilePath)
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if ($content -match 'Agent: (\w+-\d+-\d+)') { return $Matches[1] }
    return $null
}

# ─── Count queues ──────────────────────────────────────────────────────
$rootTasks = @(Get-ChildItem "$ORCHESTRATORDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' }).Count
$reviewTasks = @(Get-ChildItem "$ORCHESTRATORDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' }).Count
$workingFiles = Get-ChildItem "$ORCHESTRATORDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' }

Write-Host "╔══ Orchestrator Report ═══════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║" -ForegroundColor Cyan
Write-Host "  ● Queue sizes" -ForegroundColor Yellow
Write-Host "    Coder:    $rootTasks tasks" -ForegroundColor Gray
Write-Host "    Reviewer: $reviewTasks tasks" -ForegroundColor Gray
Write-Host "    Working:  $($workingFiles.Count) files" -ForegroundColor Gray

# ─── Working files detail ──────────────────────────────────────────────
if ($workingFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "  ● Working files" -ForegroundColor Yellow
    $idx = 1
    foreach ($f in $workingFiles) {
        $agentId = Get-LockAgent -FilePath $f.FullName
        $statusLabel = "unknown"
        $statusColor = "Gray"
        $aliveInfo = $null

        if (-not $agentId) {
            $statusLabel = "orphaned"
            $statusColor = "Red"
        } else {
            # Check lock status in file
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            $isReleased = $content -match '(?m)^-\s*Status:\s*released'
            if ($isReleased) {
                $statusLabel = "complete"
                $statusColor = "DarkGray"
            } else {
                try {
                    $aliveInfo = Test-AgentAlive -AgentId $agentId
                    if ($aliveInfo.Stale) {
                        $statusLabel = "crashed"
                        $statusColor = "Red"
                    } elseif ($aliveInfo.HasPidFile -and $aliveInfo.ProcessAlive -and $aliveInfo.HasHeartbeat -and $aliveInfo.HeartbeatAgeSeconds -le 120) {
                        $statusLabel = "working"
                        $statusColor = "Green"
                    } elseif ($aliveInfo.HasPidFile -and $aliveInfo.ProcessAlive) {
                        $statusLabel = "working"
                        $statusColor = "Green"
                    } else {
                        $statusLabel = "crashed"
                        $statusColor = "Red"
                    }
                } catch {
                    $statusLabel = "unknown"
                    $statusColor = "Gray"
                }
            }
        }

        Write-Host "    #$idx  $agentId | $($f.Name) | $statusLabel" -ForegroundColor $statusColor
        $idx++
    }
}

# ─── Completed sessions ────────────────────────────────────────────────
$completeDirs = Get-ChildItem "$ORCHESTRATORDir/Tasks/Complete/*" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'PID' }
$completeFiles = Get-ChildItem "$ORCHESTRATORDir/Tasks/Complete/*.md" -ErrorAction SilentlyContinue

if ($completeDirs.Count -gt 0 -or $completeFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "  ● Completed sessions" -ForegroundColor Yellow
    foreach ($d in $completeDirs) {
        $items = @(Get-ChildItem "$($d.FullName)/*.md" -ErrorAction SilentlyContinue)
        Write-Host "    $($d.Name)/  ($($items.Count) files)" -ForegroundColor DarkGray
    }
    foreach ($f in $completeFiles) {
        Write-Host "    $($f.Name)" -ForegroundColor DarkGray
    }
}

Write-Host "║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
