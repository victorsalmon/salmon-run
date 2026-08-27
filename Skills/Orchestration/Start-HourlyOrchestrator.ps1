<#
.SYNOPSIS
    Starts the ORCHESTRATOR orchestrator with a persistent watchdog and
    registers a Windows scheduled task as a failsafe relauncher.
.DESCRIPTION
    Launches Invoke-Orchestrate.ps1 -DetachWatchdog -WatchIntervalSeconds 60 so
    the orchestrator runs in the background and the watchdog returns every minute to
    check health, rescue stuck queues, and relaunch on crash. Also registers a
    Windows scheduled task named 'ORCHESTRATOR-HourlyOrchestrator' that re-runs the
    same command every hour; if the watchdog is already running the task exits
    immediately, otherwise it relaunches it.

    If scheduled-task registration fails (e.g., non-elevated session), the
    background watchdog process is still started and will keep running until it
    exits or the machine reboots.
.PARAMETER WatchIntervalSeconds
    Seconds between watchdog health checks. Default 60 (1 minute), range 30-3600.
.PARAMETER CodeParallelCount
    Max concurrent coder streams. Default 3.
.PARAMETER ReviewerParallelCount
    Max concurrent reviewer streams. Default 3.
.PARAMETER NoScheduledTask
    Skip registering the Windows scheduled task. The watchdog still starts now.
.PARAMETER MaxRuntimeMinutes
    Max minutes the orchestrator should run before entering drain mode.
.PARAMETER PollIntervalSeconds
    Seconds between queue scans when no streams are active.
.PARAMETER IdleTimeoutMinutes
    Minutes to wait with empty queues before exiting.
.EXAMPLE
    .\Skills\\Orchestration\Start-HourlyOrchestrator.ps1
.EXAMPLE
    .\Skills\\Orchestration\Start-HourlyOrchestrator.ps1 -CodeParallelCount 2 -ReviewerParallelCount 2
#>

param(
    [ValidateRange(30, 3600)]
    [int]$WatchIntervalSeconds = 60,

    [ValidateRange(1, 20)]
    [int]$CodeParallelCount = 3,

    [ValidateRange(1, 20)]
    [int]$ReviewerParallelCount = 3,

    [switch]$NoScheduledTask,

    [ValidateRange(0, 1440)]
    [int]$MaxRuntimeMinutes = 0,

    [ValidateRange(10, 600)]
    [int]$PollIntervalSeconds = 0,

    [ValidateRange(1, 480)]
    [int]$IdleTimeoutMinutes = 0
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$invokeScript = Join-Path $repoRoot "Skills\\Orchestration\Invoke-Orchestrate.ps1"

if (-not (Test-Path $invokeScript)) {
    Write-Error "Invoke-Orchestrate.ps1 not found at $invokeScript"
    exit 1
}

# Build argument list for the background launch.
$launchArgs = @(
    "-File `"$invokeScript`"",
    "-DetachWatchdog",
    "-WatchIntervalSeconds $WatchIntervalSeconds",
    "-CodeParallelCount $CodeParallelCount",
    "-ReviewerParallelCount $ReviewerParallelCount"
)
if ($MaxRuntimeMinutes) { $launchArgs += "-MaxRuntimeMinutes $MaxRuntimeMinutes" }
if ($PollIntervalSeconds) { $launchArgs += "-PollIntervalSeconds $PollIntervalSeconds" }
if ($IdleTimeoutMinutes) { $launchArgs += "-IdleTimeoutMinutes $IdleTimeoutMinutes" }

# Start the watchdog now.
$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) {
    Write-Error "Neither pwsh.exe nor powershell.exe found."
    exit 1
}

$proc = Start-Process -FilePath $pwsh -ArgumentList $launchArgs -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
Write-Host "ORCHESTRATOR orchestrator watchdog launched (PID $($proc.Id))." -ForegroundColor Green
Write-Host "  Watch interval: ${WatchIntervalSeconds}s" -ForegroundColor DarkGray
Write-Host "  Coder streams:  $CodeParallelCount" -ForegroundColor DarkGray
Write-Host "  Reviewer streams: $ReviewerParallelCount" -ForegroundColor DarkGray

# Register a Windows scheduled task as an hourly failsafe relauncher.
if (-not $NoScheduledTask) {
    $taskName = "ORCHESTRATOR-HourlyOrchestrator"
    $taskArgs = $launchArgs -join " "

    try {
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument $taskArgs -WorkingDirectory $repoRoot

        # Start one minute from now and repeat every hour for the next 10 years.
        $startAt = (Get-Date).AddMinutes(1)
        $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false

        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Host "Scheduled task '$taskName' registered; it will relaunch the watchdog every hour if it is not running." -ForegroundColor Green
    } catch {
        Write-Warning "Could not register scheduled task (may require elevation or Task Scheduler is unavailable): $_"
        Write-Host "The watchdog process is still running. To restart it after a reboot, re-run this script." -ForegroundColor Yellow
    }
}

# Write a small state marker so other tools can see when the timer was configured.
$marker = Join-Path $repoRoot "Tasks\Logs\.hourly-orchestrator-configured"
$null = New-Item -ItemType Directory -Path (Split-Path $marker -Parent) -Force
@{
    configured_at = (Get-Date -Format 'o')
    watchdog_pid  = $proc.Id
    watch_interval_seconds = $WatchIntervalSeconds
    code_parallel_count = $CodeParallelCount
    reviewer_parallel_count = $ReviewerParallelCount
    scheduled_task = (-not $NoScheduledTask.IsPresent)
} | ConvertTo-Json -Depth 3 | Set-Content -Path $marker -Encoding utf8 -NoNewline

Write-Host "Done. Use `Invoke-MonitorSubagents.ps1` to watch the fleet." -ForegroundColor DarkGray
