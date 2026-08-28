#Requires -Version 7.0

<#
.SYNOPSIS
    Unattended supervisor for the Salmon Run pond engine.
.DESCRIPTION
    Runs Start-SalmonRun -Run -MaxIterations 0 in a resilient loop, restarts the
    engine on crash, writes heartbeat files, and supports graceful shutdown when
    a stop sentinel file is placed at ~/.salmon/orchestrator.stop.
.PARAMETER PollIntervalSeconds
    Seconds the inner engine sleeps when no work is found. Default 300.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes an agent subprocess may run. Default 30.
.PARAMETER NamespaceRepoMap
    Optional hashtable mapping plan namespace to target repo path. Overrides the
    ~/.salmon/orchestrator.config.json file but not the file if the file wins? No.
.PARAMETER ConfigPath
    Path to an orchestrator config JSON with a namespaceRepoMap object.
.PARAMETER LogDir
    Directory for the supervisor log and heartbeat. Default ~/.salmon/Logs.
.EXAMPLE
    .\Run-SalmonRun.ps1
    Start the unattended runner in the foreground.
#>
[CmdletBinding()]
param(
    [int]$PollIntervalSeconds = 300,
    [int]$SubprocessTimeoutMinutes = 60,
    [string]$ConfigPath = '',
    [string]$LogDir = ''
)

$ErrorActionPreference = 'Continue'

$moduleLoader = Join-Path $PSScriptRoot 'Modules' 'SalmonRun.ModuleLoader' 'Public' 'Initialize-InterclawEnvironment.ps1'
if (-not (Test-Path $moduleLoader -PathType Leaf)) {
    throw "Run-SalmonRun: module loader not found at $moduleLoader"
}
. $moduleLoader

$null = Initialize-InterclawEnvironment -RepoRoot $PSScriptRoot
$salmonHome = Get-SalmonHome
$taskRoot = Get-SalmonTaskRoot
if (-not (Test-Path $taskRoot -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $taskRoot -Force
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $salmonHome 'Logs'
}
if (-not (Test-Path $LogDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $LogDir -Force
}

$logPath = Join-Path $LogDir 'orchestrator.log'
$heartbeatPath = Join-Path $LogDir 'orchestrator.heartbeat.json'
$stopFile = Join-Path $taskRoot 'orchestrator.stop'

function Write-OrchestratorLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Date -Format 'o') [$Level] $Message"
    $line | Add-Content -LiteralPath $logPath -Encoding utf8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Write-Heartbeat {
    param([string]$State, [string]$Detail)
    $hb = [PSCustomObject]@{
        ts        = (Get-Date -Format 'o')
        state     = $State
        detail    = $Detail
        pid       = $PID
        logPath   = $logPath
        stopFile  = $stopFile
    } | ConvertTo-Json -Depth 2
    $hb | Set-Content -LiteralPath $heartbeatPath -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
}

# Remove a stale stop file at startup so the user can stop gracefully later.
if (Test-Path -LiteralPath $stopFile) {
    Remove-Item -LiteralPath $stopFile -Force
    Write-OrchestratorLog -Message 'removed stale stop sentinel' -Level 'INFO'
}

Write-OrchestratorLog -Message 'Salmon Run unattended supervisor starting' -Level 'INFO'
Write-Heartbeat -State 'starting' -Detail 'pid init'

$consecutiveCrashes = 0
$maxConsecutiveCrashes = 10

while ($true) {
    if (Test-Path -LiteralPath $stopFile) {
        Write-OrchestratorLog -Message 'stop sentinel found; shutting down' -Level 'INFO'
        Write-Heartbeat -State 'stopped' -Detail 'stop sentinel'
        break
    }

    Write-Heartbeat -State 'running' -Detail "cycle start (crashes=$consecutiveCrashes)"

    $startArgs = @{
        FilePath     = (Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue).Source
        ArgumentList = @(
            '-NoProfile'
            '-NonInteractive'
            '-File', (Join-Path $PSScriptRoot 'Start-SalmonRun.ps1')
            '-Run'
            '-MaxIterations', 0
            '-PollIntervalSeconds', $PollIntervalSeconds
            '-SubprocessTimeoutMinutes', $SubprocessTimeoutMinutes
        )
        PassThru     = $true
        NoNewWindow  = $true
        WorkingDirectory = $PSScriptRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $startArgs.ArgumentList += '-ConfigPath'
        $startArgs.ArgumentList += $ConfigPath
    }

    $exitCode = 0
    $process = $null
    try {
        $process = Start-Process @startArgs

        # Poll for stop sentinel while the engine is running. Also emit a
        # health/churn report every 5 minutes so an unattended engine with
        # MaxIterations 0 still produces status output.
        $nextHealthCheck = (Get-Date).AddMinutes(5)
        $nextHeartbeat = (Get-Date)
        while (-not $process.HasExited) {
            if ((Get-Date) -ge $nextHeartbeat) {
                $nextHeartbeat = (Get-Date).AddSeconds(30)
                Write-Heartbeat -State 'running' -Detail "engine monitor"
            }

            if (Test-Path -LiteralPath $stopFile) {
                Write-OrchestratorLog -Message 'stop sentinel found; terminating pond engine' -Level 'INFO'
                $null = taskkill /T /F /PID $process.Id 2>&1 | Out-Null
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                break
            }

            if ((Get-Date) -ge $nextHealthCheck) {
                $nextHealthCheck = (Get-Date).AddMinutes(5)

                $healthScript = Join-Path $PSScriptRoot 'Tools' 'Get-SalmonRunHealthReport.ps1'
                if (Test-Path -LiteralPath $healthScript) {
                    $health = & $healthScript -TaskRoot $salmonHome -LogDir $LogDir -HistoryHours 24
                    if ($health) {
                        Write-OrchestratorLog -Message "health: $($health.summary)" -Level 'INFO'
                    }
                }

                # The pond engine blocks in a Monitor task while a subprocess runs,
                # so a separate janitor sweeps any completed or failed lanes that
                # the main engine cannot transition right away.
                $janitorScript = Join-Path $PSScriptRoot 'Tools' 'Start-WorkingLaneJanitor.ps1'
                if (Test-Path -LiteralPath $janitorScript) {
                    & $janitorScript -TaskRoot $taskRoot -RepoDir $PSScriptRoot | Out-Null
                }
            }

            Start-Sleep -Seconds 5
        }

        if (-not $process.HasExited) {
            $null = taskkill /T /F /PID $process.Id 2>&1 | Out-Null
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        $process.WaitForExit(5000)
        $exitCode = $process.ExitCode
    } catch {
        $exitCode = 1
        Write-OrchestratorLog -Message "failed to start or monitor pond engine: $_" -Level 'ERROR'
    }

    if (Test-Path -LiteralPath $stopFile) {
        Write-OrchestratorLog -Message 'stop sentinel found after engine exit; shutting down' -Level 'INFO'
        Write-Heartbeat -State 'stopped' -Detail 'stop sentinel after engine exit'
        break
    }

    if ($exitCode -ne 0) {
        $consecutiveCrashes++
        Write-OrchestratorLog -Message "pond engine exited with code $exitCode (consecutive crashes: $consecutiveCrashes)" -Level 'ERROR'
        if ($consecutiveCrashes -ge $maxConsecutiveCrashes) {
            Write-OrchestratorLog -Message 'too many consecutive crashes; giving up' -Level 'FATAL'
            Write-Heartbeat -State 'failed' -Detail "crashed $consecutiveCrashes times"
            break
        }
    } else {
        $consecutiveCrashes = 0
        Write-OrchestratorLog -Message 'pond engine exited cleanly (restarting)' -Level 'INFO'
    }

    $backoff = [math]::Min($consecutiveCrashes * 10, 300)
    Write-Heartbeat -State 'recovering' -Detail "sleeping ${backoff}s before restart"

    # Health / churn watchdog: produce a report after every engine cycle.
    $healthScript = Join-Path $PSScriptRoot 'Tools' 'Get-SalmonRunHealthReport.ps1'
    if (Test-Path -LiteralPath $healthScript) {
        $liveStale = ($SubprocessTimeoutMinutes * 60) + 300
        $health = & $healthScript -TaskRoot $salmonHome -LogDir $LogDir -HistoryHours 24 -LiveStaleThresholdSeconds $liveStale
        if ($health) {
            Write-OrchestratorLog -Message "health: $($health.summary)" -Level 'INFO'
        }
    }

    Start-Sleep -Seconds $backoff
}

Write-OrchestratorLog -Message 'Salmon Run unattended supervisor stopped' -Level 'INFO'
