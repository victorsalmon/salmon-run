<#
.SYNOPSIS
    Off-platform schedule poller. Companion to the Sentry poller for local dev.
.DESCRIPTION
    Evaluates Tasks/Schedule/*.json at a fixed interval and dispatches fired
    schedules. Tries mcp_opencode REST API first (if container is reachable),
    falls back to launching LocalOrchestrator.

    When Sentry is deployed, do NOT run this poller on the same host — it will
    double-trigger schedules. Run it on dev machines without the fleet stack.
#>

param(
    [int]$PollIntervalSec = 60,
    [int]$MaxCycles = 0,
    [string]$RepoDir = $PSScriptRoot
)

. (Join-Path $PSScriptRoot "Skills/Workflows/Scheduler/CronParser.ps1")

$ErrorActionPreference = "Continue"
$repoRoot = Resolve-Path (Join-Path $RepoDir "..\..")
$scheduleDir = Join-Path $repoRoot "Tasks" "Schedule"
$logDir = Join-Path $repoRoot "Tasks" "Logs"
$null = New-Item -ItemType Directory -Path $logDir -Force
$logFile = Join-Path $logDir "local-schedule-poller-$PID.log"

function Write-PollerLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "{`"timestamp`":`"$(Get-Date -Format 'o')`",`"level`":`"$Level`",`"poller`":`"local`",`"message`":`"$($Message -replace '"','\"')`"}"
    Add-Content -Path $logFile -Value $entry -Encoding utf8
}

function Write-AtomicScheduleFile {
    param($Schedule, $Path)
    $tmpPath = "$Path.tmp"
    $Schedule | ConvertTo-Json -Depth 5 | Out-File $tmpPath -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
}

function Set-ScheduleProperty {
    param($Schedule, [string]$Name, $Value)
    if ($Schedule.PSObject.Properties.Name -contains $Name) {
        $Schedule.$Name = $Value
    } else {
        $Schedule | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, "Global\ORCHESTRATORLocalSchedulePoller")
    if (-not $mutex.WaitOne(0)) {
        Write-PollerLog "Another local poller is already running — exiting" -Level WARN
        exit 1
    }
} catch {
    Write-PollerLog "Mutex creation failed: $_" -Level WARN
}

$cycle = 0
$null = New-Item -ItemType Directory -Path $scheduleDir -Force -ErrorAction SilentlyContinue
Write-PollerLog "Local schedule poller started (poll interval: ${PollIntervalSec}s, max cycles: $MaxCycles)"

$stopSignalPath = Join-Path $logDir ".local-poller-stop"

while ($true) {
    $cycle++
    if ($MaxCycles -gt 0 -and $cycle -gt $MaxCycles) {
        Write-PollerLog "Max cycles ($MaxCycles) reached — exiting" -Level INFO
        break
    }

    if (Test-Path $stopSignalPath) {
        Remove-Item $stopSignalPath -Force -ErrorAction SilentlyContinue
        Write-PollerLog "Stop signal received — exiting" -Level INFO
        break
    }

    try {
        # Git pull before evaluating schedules
        try {
            & "git" "-C" $repoRoot "pull" "--rebase" 2>&1 | ForEach-Object { Write-PollerLog "git pull: $_" }
        } catch {
            Write-PollerLog "git pull failed (non-fatal): $_" -Level WARN
        }

        $scheduleFiles = @(Get-ChildItem -Path $scheduleDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        $now = [DateTime]::UtcNow

        # Watchdog: schedules triggered > 2h ago with no activity
        $staleThreshold = 7200
        foreach ($sf in $scheduleFiles) {
            try {
                $schedule = Get-Content $sf.FullName -Raw | ConvertFrom-Json
                if ($schedule.status -eq "triggered" -and ($schedule.PSObject.Properties.Name -contains "triggered_at" -and $schedule.triggered_at)) {
                    $triggeredAge = ($now - [DateTime]::Parse($schedule.triggered_at)).TotalSeconds
                    if ($triggeredAge -gt $staleThreshold) {
                        $hasRepeat = $schedule.PSObject.Properties.Name -contains "repeat"
                        $hasAttempt = $schedule.PSObject.Properties.Name -contains "attempt"
                        $hasMaxAttempts = $schedule.PSObject.Properties.Name -contains "max_attempts"
                        if ($hasRepeat -and $hasAttempt -and $hasMaxAttempts -and $schedule.attempt -lt $schedule.max_attempts) {
                            Set-ScheduleProperty -Schedule $schedule -Name "attempt" -Value ($schedule.attempt + 1)
                            if ($schedule.repeat -is [string] -and $schedule.repeat -match '^[\d*,/\-\s]+$') {
                                $nextRun = Get-NextCronOccurrence -Expression $schedule.repeat -After $now
                                $schedule.scheduled_at = if ($nextRun) { $nextRun.ToString("o") } else { $now.AddHours(1).ToString("o") }
                            } else {
                                $intervalMinutes = if ($schedule.repeat.interval_minutes) { $schedule.repeat.interval_minutes } else { 0 }
                                $schedule.scheduled_at = $now.AddMinutes($intervalMinutes).ToString("o")
                            }
                            $schedule.status = "pending"
                            Write-AtomicScheduleFile -Schedule $schedule -Path $sf.FullName
                            Write-PollerLog "Advancing stale triggered schedule $($sf.Name) to attempt $($schedule.attempt)" -Level WARN
                        } else {
                            $retryCount = if ($schedule.PSObject.Properties.Name -contains "retry_count") { $schedule.retry_count } else { 0 }
                            $maxRetries = if ($schedule.PSObject.Properties.Name -contains "max_retries") { $schedule.max_retries } else { 3 }
                            if ($retryCount -lt $maxRetries) {
                                Set-ScheduleProperty -Schedule $schedule -Name "retry_count" -Value ($retryCount + 1)
                                Set-ScheduleProperty -Schedule $schedule -Name "last_error" -Value "stale - plan not completed within 2h (retry $($retryCount + 1)/$maxRetries)"
                                Set-ScheduleProperty -Schedule $schedule -Name "scheduled_at" -Value $now.ToString("o")
                                $schedule.status = "pending"
                                Write-AtomicScheduleFile -Schedule $schedule -Path $sf.FullName
                                Write-PollerLog "retrying stale schedule $($sf.Name) (retry $($retryCount + 1)/$maxRetries)" -Level WARN
                            } else {
                                $schedule.status = "completed"
                                Set-ScheduleProperty -Schedule $schedule -Name "completed_at" -Value $now.ToString("o")
                                Set-ScheduleProperty -Schedule $schedule -Name "error" -Value "max retries exhausted"
                                Set-ScheduleProperty -Schedule $schedule -Name "last_error" -Value "stale - plan not completed within 2h after $maxRetries retries"
                                Write-AtomicScheduleFile -Schedule $schedule -Path $sf.FullName
                                Write-PollerLog "Marking stale schedule $($sf.Name) as completed (max retries exhausted)" -Level WARN
                            }
                        }
                    }
                }
            } catch {
                Write-PollerLog "Watchdog error on $($sf.Name): $_" -Level WARN
            }
        }

        $firedSchedules = @()

        foreach ($sf in $scheduleFiles) {
            try {
                $schedule = Get-Content $sf.FullName -Raw | ConvertFrom-Json
                if ($schedule.status -eq "completed") {
                    $isCron = $schedule.repeat -and ($schedule.repeat -is [string]) -and ($schedule.repeat -match '^[\d*,/\-\s]+$')
                    if ($isCron) {
                        $refTime = if ($schedule.PSObject.Properties.Name -contains "completed_at" -and $schedule.completed_at) {
                            try { [DateTime]::Parse($schedule.completed_at) } catch { $now }
                        } else { $now }
                        $nextRun = Get-NextCronOccurrence -Expression $schedule.repeat -After $refTime
                        if ($nextRun) {
                            $schedule.status = "pending"
                            $schedule.scheduled_at = $nextRun.ToString("o")
                            $schedule.triggered_at = $null
                            $schedule.error = $null
                            $schedule.completed_at = $null
                            Write-AtomicScheduleFile -Schedule $schedule -Path $sf.FullName
                            Write-PollerLog "Re-armed cron schedule $($sf.Name) for $($schedule.scheduled_at)" -Level INFO
                            continue
                        }
                    }
                    $completedAt = if ($schedule.PSObject.Properties.Name -contains "completed_at" -and $schedule.completed_at) {
                        try { [DateTime]::Parse($schedule.completed_at) } catch { $null }
                    } else { $null }
                    $ageReference = if ($completedAt) { $completedAt } else { $sf.LastWriteTime }
                    $fileAge = ($now - $ageReference).TotalHours
                    if ($fileAge -gt 48) {
                        Write-PollerLog "Removing completed schedule $($sf.Name) (completed: ${fileAge}h ago)" -Level INFO
                        Remove-Item -LiteralPath $sf.FullName -Force -ErrorAction SilentlyContinue
                        continue
                    }
                }

                if ($schedule.status -eq "pending") {
                    $stalePending = $false
                    if ($schedule.scheduled_at) {
                        $schedDt = try { [DateTime]::Parse($schedule.scheduled_at) } catch { $null }
                        if ($schedDt -and ($now - $schedDt).TotalHours -gt 48) { $stalePending = $true }
                    } elseif (($now - $sf.LastWriteTime).TotalHours -gt 48) {
                        $stalePending = $true
                    }
                    if ($stalePending) {
                        Write-PollerLog "Removing stale pending schedule $($sf.Name) - scheduled at $($schedule.scheduled_at) was >48h ago" -Level WARN
                        Remove-Item -LiteralPath $sf.FullName -Force -ErrorAction SilentlyContinue
                        continue
                    }
                }

                if ($schedule.status -ne "pending") {
                    continue
                }

                $scheduledAt = if ($schedule.scheduled_at) {
                    try { [DateTime]::Parse($schedule.scheduled_at) } catch { $null }
                } else { $null }

                $fireNow = $false
                if (-not $scheduledAt) {
                    $fireNow = $true
                } elseif (($now - $scheduledAt).TotalSeconds -ge 0) {
                    $fireNow = $true
                }

                if ($fireNow) {
                    $schedule.status = "triggered"
                    Set-ScheduleProperty -Schedule $schedule -Name "triggered_at" -Value $now.ToString("o")
                    Write-AtomicScheduleFile -Schedule $schedule -Path $sf.FullName
                    $firedSchedules += $schedule
                    Write-PollerLog "Triggered schedule $($sf.Name) (type: $($schedule.type))" -Level INFO
                }
            } catch {
                Write-PollerLog "Error processing $($sf.Name): $_" -Level WARN
            }
        }

        # Process fired schedules — try mcp_opencode REST API if reachable, else launch orchestrator
        # Discover mcp_opencode container (Docker DNS from within stack, or docker inspect from host)
        $mcpBaseUrl = $null
        try {
            $health = Invoke-RestMethod -Uri "http://mcp_opencode:21000/api/health" -TimeoutSec 3 -ErrorAction Stop
            if ($health.status -in @("healthy", "starting")) {
                $mcpBaseUrl = "http://mcp_opencode:21001"
                Write-PollerLog "mcp_opencode reachable via Docker DNS" -Level INFO
            }
        } catch {
            try {
                $containers = docker ps --filter "name=mcp_opencode" --format "{{.ID}}" 2>$null
                if ($containers) {
                    $containerId = ($containers -split '\s+')[0]
                    $networkIp = docker inspect $containerId --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>$null
                    if ($networkIp) {
                        $health = Invoke-RestMethod -Uri "http://${networkIp}:21000/api/health" -TimeoutSec 3 -ErrorAction Stop
                        if ($health.status -in @("healthy", "starting")) {
                            $mcpBaseUrl = "http://${networkIp}:21001"
                            Write-PollerLog "mcp_opencode reachable via docker inspect ($networkIp)" -Level INFO
                        }
                    }
                }
            } catch { }
        }

        foreach ($schedule in $firedSchedules) {
            try {
                if ($schedule.type -eq "alignment-audit") {
                    $null = Write-WorkflowEvent -Type "SCHEDULE_AUDIT_SKIPPED" -Detail "Alignment-audit schedule $($schedule.id) cannot run locally (Sentry only)" -Files @() -ErrorAction SilentlyContinue
                    Write-PollerLog "Skipping alignment-audit schedule $($schedule.id) — local poller cannot run audit cycles" -Level WARN
                    continue
                }

                if ($mcpBaseUrl) {
                    # Build prompt the same way Send-OpencodeSession does
                    $prompt = if ($schedule.agent -in @("coder", "reviewer")) {
                        "Execute the schedule task for $($schedule.id). Agent: $($schedule.agent). Prompt: $($schedule.prompt)"
                    } else {
                        "Scheduled task for schedule $($schedule.id).`n`n$($schedule.prompt)"
                    }
                    try {
                        # Authoritative opencode session API: POST /session {} returns .id
                        $sessionResponse = Invoke-RestMethod -Uri "${mcpBaseUrl}/session" -Method Post -Body '{}' -ContentType "application/json" -TimeoutSec 30
                        if (-not $sessionResponse.id) {
                            throw "POST /session did not return an .id field"
                        }
                        $sessionId = $sessionResponse.id
                        $promptAsyncBody = @{ parts = @(@{ type = 'text'; text = $prompt }) } | ConvertTo-Json -Compress -Depth 5
                        $null = Invoke-RestMethod -Uri "${mcpBaseUrl}/session/${sessionId}/prompt_async" -Method Post -Body $promptAsyncBody -ContentType "application/json" -TimeoutSec 30
                        Write-PollerLog "Dispatched $($schedule.id) to mcp_opencode (session $sessionId)" -Level INFO
                        continue
                    } catch {
                        Write-PollerLog "REST dispatch failed for $($schedule.id): $_ — falling back to orchestrator" -Level WARN
                    }
                }

                # Fallback: launch LocalOrchestrator
                $orchPath = Join-Path $PSScriptRoot "LocalOrchestrator.ps1"
                if (Test-Path $orchPath) {
                    $pwsh = Get-Command pwsh.exe | Select-Object -ExpandProperty Source
                    $proc = Start-Process -FilePath $pwsh -ArgumentList @("-NoProfile", "-NoLogo", "-File", "`"$orchPath`"", "-Detach", "-NoAuditPrompt") -WindowStyle Hidden -PassThru
                    Write-PollerLog "Launched LocalOrchestrator (PID $($proc.Id)) for schedule $($schedule.id)" -Level INFO
                } else {
                    Write-PollerLog "LocalOrchestrator.ps1 not found at $orchPath" -Level ERROR
                }
            } catch {
                Write-PollerLog "Failed to process fired schedule $($schedule.id): $_" -Level ERROR
            }
        }

        if ($firedSchedules.Count -eq 0) {
            Write-PollerLog "Poll cycle ${cycle}: no schedules to fire"
        }
    } catch {
        Write-PollerLog "Poll cycle error: $_" -Level ERROR
    }

    Start-Sleep -Seconds $PollIntervalSec
}

if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
