<#
.SYNOPSIS
    Main entrypoint loop for the fleet container.
.DESCRIPTION
    Runs a continuous loop performing fleet health checks, remediation,
    startup verification at configured intervals.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None. Runs indefinitely (infinite loop).
#>
function Invoke-FleetEntrypoint {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Write-Verbose "`n  Interclaw - Fleet v2.0"
    Write-Verbose "  Stack: $($env:INSTALL_PROJECT)"
    Write-FleetLog "Fleet started (v2.0)"

    $script:InContainer = Test-Path "/var/run/docker.sock" -ErrorAction SilentlyContinue
    if (-not $script:InContainer) {
        Write-Warning "  [WARN] No Docker socket found at /var/run/docker.sock — not running inside is-fleet container."
        Write-Warning "  [WARN] Fleet health checks and remediation will be degraded."
        Write-FleetLog "Not running inside is-fleet container (no Docker socket) — degraded mode" -Level WARN
    }

    # Phase 1: First-boot startup check (5-minute delay)
    if (-not (Test-Path $StartupCheckMarker)) {
        Write-Verbose "`n[FIRST BOOT] Scheduling startup health check in 5 minutes..."
        Write-FleetLog "First boot detected, scheduling startup check with 5-min delay"

        $StartupDelaySec = (Get-InterclawConstants).FleetMainLoopIntervalSec
        # Resolve repo root by walking up from the module Public/ dir until AGENTS.md is found.
        $RepoRoot = $PSScriptRoot
        while ($RepoRoot -and -not (Test-Path (Join-Path $RepoRoot "AGENTS.md"))) {
            $parent = Split-Path $RepoRoot -Parent
            if ($parent -eq $RepoRoot) { break }
            $RepoRoot = $parent
        }
        # The Dockerfile copies 1Fleet.ps1 to Scripts/1Fleet.ps1 (container layout),
        # but on the host it lives at Skills/Docker/1Fleet.ps1. Check both.
        $candidatePaths = @(
            (Join-Path $RepoRoot "Scripts/1Fleet.ps1"),
            (Join-Path $RepoRoot "Skills/Docker/1Fleet.ps1")
        )
        $StartupCheckScript = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $StartupCheckScript) {
            Write-FleetLog "Startup check script not found (tried: $($candidatePaths -join ', ')) — first-boot verification disabled" -Level ERROR
            Write-Verbose "  [ERROR] Startup check script missing in candidate paths"
        }
        else {
            $StartupJob = Start-Job -ScriptBlock {
                [OutputType([void])]
                param([string]$ScriptPath, [int]$DelaySec)
                Start-Sleep -Seconds $DelaySec
                & $ScriptPath -Mode StartupCheck
            } -ArgumentList $StartupCheckScript, $StartupDelaySec
        }

        $LastProcessedTimestamp = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }
    else {
        Write-Verbose "`n  Startup check already completed (marker found)."
        $LastProcessedTimestamp = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }

    # Phase 2: Main loop — fleet health + startup verification
    $constants = Get-InterclawConstants
    $LastFleetHealthTime = $null
    $FleetHealthIntervalSec = $constants.FleetHealthIntervalSec

    Write-Verbose "`n  Entering main loop (command poll: $($script:CommandPollInterval)s)"

    $script:StateSyncFailCount = 0
    $script:LastGcTime = [DateTime]::UtcNow

    # Start MCP proxy sidecar (Node.js) in background
    $McpProxyPath = "/home/node/app/Infrastructure/mcp-proxy/server.js"
    if (Test-Path $McpProxyPath) {
        $env:MCP_PORT = "21014"
        $env:API_PORT = "21002"
        $env:API_HOST = "127.0.0.1"
        $env:SERVICE_NAME = "is-fleet-mcp"
        $env:SERVICE_VERSION = "2.0.0"
        $McpProxyJob = Start-Job -ScriptBlock {
            param($scriptPath)
            node $scriptPath
        } -ArgumentList $McpProxyPath
        Write-Verbose "  [OK] MCP proxy started on port 21014 (job id: $($McpProxyJob.Id))"
        Write-FleetLog "MCP proxy started on port 21014"
    } else {
        Write-Warning "MCP proxy not found at $McpProxyPath — skipping"
    }

    # Start lightweight HTTP health endpoint in background
    $HealthListenerJob = Start-FleetHealthListener
    $HealthPort = Get-ServicePort -Service "is-fleet" -Type "host"
    $HealthInternalPort = (Get-InterclawConstants).FleetApiPort
    # Verify listener is actually serving before proceeding
    $listenerReady = $false
    $listenerRetries = 0
    $listenerMaxRetries = 5
    while (-not $listenerReady -and $listenerRetries -lt $listenerMaxRetries) {
        Start-Sleep -Seconds 1
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:${HealthInternalPort}/health" -Method GET -TimeoutSec 2
            $listenerReady = $true
        } catch {
            $listenerRetries++
        }
    }
    if (-not $listenerReady) {
        Write-Warning "  [WARN] Health listener not responding after $listenerMaxRetries seconds — restarting"
        Write-FleetLog "Health listener not responding after ${listenerMaxRetries}s — restarting" -Level WARN
        try { $HealthListenerJob | Stop-Job -ErrorAction SilentlyContinue; $HealthListenerJob | Remove-Job -ErrorAction SilentlyContinue } catch { Write-Warning "Invoke-FleetEntrypoint: failed to stop/remove health listener job before restart: $_" }
        $HealthListenerJob = Start-FleetHealthListener
        Start-Sleep -Seconds 2
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:${HealthInternalPort}/health" -Method GET -TimeoutSec 2
            Write-Verbose "  [OK] Health listener responding after restart."
            Write-FleetLog "Health listener responding after restart"
        } catch {
            Write-Warning "  [WARN] Health listener still not responding — proceeding anyway"
            Write-FleetLog "Health listener still not responding after restart" -Level WARN
        }
    } else {
        Write-Verbose "  [OK] Health endpoint started and verified on port $HealthPort -> internal :$HealthInternalPort (/health, /ready, /log)"
        Write-FleetLog "Health endpoint started and verified on port $HealthPort -> internal :$HealthInternalPort"
    }

    # Start secret rotation endpoint in background
    $RotationPort = $constants.FleetRotationPort
    $RotationJob = Start-SecretRotationEndpoint -Port $RotationPort
    Write-Verbose "  [OK] Secret rotation endpoint started on port $RotationPort (/secret/update)"
    Write-FleetLog "Secret rotation endpoint started on port $RotationPort"

    $RepoDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { "/workspace/repo" }

    # Data-driven background job definitions for restart loop
    $bgJobDefs = @(
        @{ Name = "McpProxy"; Script = {
            $p = "/home/node/app/Infrastructure/mcp-proxy/server.js"
            Start-Job -ScriptBlock { param($s) node $s } -ArgumentList $p
        }}
        @{ Name = "HealthListener"; Script = { Start-FleetHealthListener }}
        @{ Name = "Rotation"; Script = { Start-SecretRotationEndpoint -Port (Get-InterclawConstants).FleetRotationPort }}
    )

    while ($true) {
        try {
            # Maintenance mode check — suppress health checks and state sync
            $maintenanceModeFile = Join-Path $PWD "Tasks/Logs/.maintenance-mode"
            $inMaintenance = Test-Path $maintenanceModeFile
            if ($inMaintenance) {
                $maintenanceDetail = if (Test-Path $maintenanceModeFile) { (Get-Content $maintenanceModeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "" }
                Write-FleetLog "Maintenance mode active$(if ($maintenanceDetail) { ': ' + $maintenanceDetail }) — skipping health checks" -Level WARN
            }

            # Check startup job — only treat as complete when its state is 'Completed'
            # (JobStateInfo.Reason is null both while running and after success, so it cannot
            # be used to detect completion; a running job must be left in place to finish).
            if ($StartupJob) {
                $StartupJobState = if ($StartupJob.ChildJobs -and $StartupJob.ChildJobs[0] -and $StartupJob.ChildJobs[0].JobStateInfo) { $StartupJob.ChildJobs[0].JobStateInfo.State } else { $null }
                if ($StartupJobState -eq 'Completed') {
                    $JobOutput = Receive-Job $StartupJob -ErrorAction SilentlyContinue -ErrorVariable receiveJobErrors
                    if ($receiveJobErrors) {
                        Write-FleetLog "Receive-Job errors: $($receiveJobErrors -join '; ')" -Level WARN
                    }
                    ([DateTime]::UtcNow.ToString('o')) | Write-AtomicFile -Path $StartupCheckMarker -Encoding UTF8
                    Write-Verbose "  [OK] Startup check completed (marker written)."
                    Write-FleetLog "Startup check job completed"
                    Remove-Job $StartupJob -Force
                    $StartupJob = $null
                }
                elseif ($StartupJobState -in @('Failed', 'Stopped', 'Terminated')) {
                    Write-Warning "  [WARN] Startup check job failed: $StartupJobState"
                    Write-FleetLog "Startup check job failed: $StartupJobState" -Level WARN
                    Remove-Job $StartupJob -Force
                    $StartupJob = $null
                }
                # else: still Running — leave for a later iteration to reap once completed
            }

            # Check all background jobs — restart if failed (data-driven)
        foreach ($def in $bgJobDefs) {
            $bgName = $def.Name
            $jobVar = Get-Variable -Name "${bgName}Job" -ErrorAction SilentlyContinue
            if (-not $jobVar) { continue }
            $job = $jobVar.Value
            if ($job -and $job.State -in @("Failed", "Stopped")) {
                $output = Receive-Job $job -ErrorAction SilentlyContinue
                Write-FleetLog "${bgName} job failed: $output" -Level WARN
                Remove-Job $job -Force
                $restartKey = "RestartCount_${bgName}"
                if (-not $script:FleetHealthState.ContainsKey($restartKey)) { $script:FleetHealthState[$restartKey] = 0 }
                $script:FleetHealthState[$restartKey]++
                if ($script:FleetHealthState[$restartKey] -le 3) {
                    Write-FleetLog "Restarting ${bgName} job (attempt $($script:FleetHealthState[$restartKey]))"
                    $newJob = & $def.Script
                    Set-Variable -Name "${bgName}Job" -Value $newJob
                } else {
                    Write-FleetLog "${bgName} job exceeded max restarts (3) — not restarting" -Level WARN
                }
            }
        }

        # Periodic fleet health check with auto-remediation (every 30 minutes)
        $Now = [DateTime]::UtcNow
        $ShouldRunFleetHealth = $false
        if ($null -eq $StartupJob) {
            if ($null -eq $LastFleetHealthTime) {
                $ShouldRunFleetHealth = $true
            }
            elseif (($Now - $LastFleetHealthTime).TotalSeconds -ge $FleetHealthIntervalSec) {
                $ShouldRunFleetHealth = $true
            }
        }

        if ($ShouldRunFleetHealth -and (-not $inMaintenance)) {
            Write-FleetLog "Running periodic fleet health check"
            try {
                $HealthResult = Invoke-FleetHealthCheck -Mode auto 2>&1 | Out-String
                $RemediationActions = $script:RemediationActions
                if ($RemediationActions) {
                    foreach ($Fix in $RemediationActions) {
                        if ($Fix.Action -match 'NEEDS MANUAL FIX') {
                            $Key = $Fix.Test
                            if (Should-LogRemediationFailure -FailureKey $Key) {
                                $Count = $script:FailureTracker[$Key].ConsecutiveCount
                                Write-FleetLog "[$Count] $($Fix.Test): $($Fix.Action)" -Level WARN
                            }
                        } elseif ($Fix.Action -match 'Auto-fixed') {
                            Reset-RemediationFailureTracking -FailureKey $Fix.Test
                            Write-FleetLog "[FIXED] $($Fix.Test): $($Fix.Action)" -Level INFO
                        }
                    }
                }
                $HealthFailedCount = if ($HealthResult -match "Failed: (\d+)") { [int]$Matches[1] } else { 0 }
                if ($HealthFailedCount -gt 0) {
                    Write-FleetLog "Fleet health check found issues (auto-remediated)" -Level WARN
                }
                else {
                    Write-FleetLog "Fleet health check passed"
                }
            }
            catch {
                Write-FleetLog "Fleet health check error: $($_.Exception.Message)" -Level WARN
            }

            $LastFleetHealthTime = [DateTime]::UtcNow

            # Periodic GC collection — prevent memory leak in long-running loop
            $gcNow = [DateTime]::UtcNow
            if (($gcNow - $script:LastGcTime).TotalMinutes -ge 5) {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                $script:LastGcTime = $gcNow
                Write-FleetLog "GC collection completed"
            }
        }

    # Push health state to HTTP listener via POST (no cross-process serialization) — with retry
        $updatePort = if ((Get-InterclawConstants) -and (Get-InterclawConstants).FleetApiPort) { (Get-InterclawConstants).FleetApiPort } else { Get-ServicePort -Service "is-fleet" -Type "internal" }
        $monitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
        $authHeaders = @{}
        if ($monitorToken) { $authHeaders["Authorization"] = "Bearer $monitorToken" }
        $body = @{
            Status     = if ($script:FleetHealthState['FailCount'] -gt 0) { "degraded" } else { "ok" }
            FailCount  = $script:FleetHealthState['FailCount']
            LastUpdate = ([DateTime]::UtcNow.ToString('o'))
        } | ConvertTo-Json -Compress
        $statePosted = $false
        $stateRetries = 0
        $stateMaxRetries = 3
        $stateBackoff = 1
        while (-not $statePosted -and $stateRetries -lt $stateMaxRetries) {
            try {
                $null = Invoke-RestMethod -Uri "http://localhost:$updatePort/update-state" -Method POST -Headers $authHeaders -Body $body -ContentType "application/json" -TimeoutSec 5
                $statePosted = $true
            } catch {
                $stateRetries++
                if ($stateRetries -lt $stateMaxRetries) {
                    Write-FleetLog "Fleet state POST attempt $stateRetries failed — retrying in ${stateBackoff}s: $_" -Level WARN
                    Start-Sleep -Seconds $stateBackoff
                    $stateBackoff *= 2
                } else {
                    $script:StateSyncDegraded = $true
                    $null = [System.Threading.Interlocked]::Increment([ref]$script:StateSyncFailCount)
                    Write-FleetLog "Fleet state POST failed after $stateMaxRetries attempts — state sync degraded ($($script:StateSyncFailCount) consecutive cycles): $_" -Level WARN
                }
            }
        }
        if ($statePosted) {
            $script:StateSyncFailCount = 0
            if ($script:StateSyncDegraded) { $script:StateSyncDegraded = $false }
        }
        if ($script:StateSyncFailCount -ge 3) {
            Write-FleetLog "Fleet state POST failed $($script:StateSyncFailCount) consecutive cycles — restarting health listener" -Level ERROR
            $script:StateSyncFailCount = 0
            try { $HealthListenerJob | Stop-Job -ErrorAction SilentlyContinue; $HealthListenerJob | Remove-Job -ErrorAction SilentlyContinue } catch { Write-FleetLog "Invoke-FleetEntrypoint: failed to stop/remove health listener job after state sync failure: $_" -Level WARN }
            $HealthListenerJob = Start-FleetHealthListener
            if (-not $HealthListenerJob) { Write-FleetLog "Failed to restart health listener" -Level ERROR }
        }

        # Check for pending-restart marker from Invoke-FleetRebuild or PreserveFleet deploy
        $pendingRestartPath = "/workspace/repo/.fleet-pending-restart.json"
        if (Test-Path $pendingRestartPath) {
            try {
                $pending = Get-Content $pendingRestartPath -Raw | ConvertFrom-Json
                Write-FleetLog "Pending-restart marker found (timestamp: $($pending.timestamp)). Triggering self-restart..."
                Remove-Item $pendingRestartPath -Force -ErrorAction SilentlyContinue
                $stackName = $env:INSTALL_PROJECT
                $fleetServiceName = "${stackName}_is-fleet"
                Write-FleetLog "Running: docker service update --force $fleetServiceName"
                $null = docker service update --force $fleetServiceName 2>&1
                Write-FleetLog "Self-restart command issued. Exiting entrypoint loop."
                break
            } catch {
                Write-FleetLog "Pending-restart marker processing failed: $_" -Level WARN
                Remove-Item $pendingRestartPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($inMaintenance) {
            Start-Sleep -Seconds 60
            continue
        }

        Start-Sleep -Seconds $script:CommandPollInterval
        } catch {
            Write-FleetLog "Unhandled exception in main loop: $($_.Exception.Message)" -Level ERROR
            Write-FleetLog "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
            Start-Sleep -Seconds 30
        }
    }
}