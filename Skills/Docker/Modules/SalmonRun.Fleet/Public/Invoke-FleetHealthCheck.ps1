<#
.SYNOPSIS
Runs scheduled fleet health checks for the is-fleet container.
.DESCRIPTION
    Orchestrates health checks: stack health, network connectivity,
    and fleet self-health. Supports modes: check (report only), fix
    (auto-remediate), and auto. Sets module-level $script:Results and
    $script:FailCount for downstream use.
    TIMEOUT CHAIN: No outer timeout (caller expected to enforce overall timeout).
    Inner: Mutex.WaitOne(30000) — 30s per check. Inner-inner: individual Test-Fleet*
    functions may call docker/HTTP with their own timeouts (must be < 30s).
    The following checks were retired 2026-08-21 with the MCP/Hermes/openclaw
    retirement: VolumeIntegrity, SecretHydration, SecretResolution,
    ContainerHealth, ServiceEndpointHealth, CodeHealth, SidecarHealth,
    TelegramPolling, AqeTopology, SwarmReality. The agent/sidecar targets those
    checks operated on no longer exist.
.PARAMETER Mode
    Operation mode: "check" (default, report only), "fix" (attempt remediation), "auto" (auto-remediate).
.PARAMETER Parallel
    If true, runs health checks in parallel waves using ForEach-Object -Parallel (requires PS 7+).
#>
function Invoke-FleetHealthCheck {
    [OutputType([int])]
    param(
        [ValidateSet("check", "fix", "auto")]
        [string]$Mode = "check",
        [bool]$Parallel = $false
    )

    $script:Results = @()
    $script:FailCount = 0
    $script:RemediationActions = @()
    $script:CompletedRemediations = @{}

    $suppressAll = Test-Path (Join-Path $PWD "Tasks/Logs/.suppress-health-all") -ErrorAction SilentlyContinue
    $suppressedServices = if (-not $suppressAll) { Get-SuppressedHealthServices } else { @() }
    if ($suppressAll) {
        Write-Warning "Global health suppression active — all remediation paused"
    }

    $script:RemediationCooldown = $script:RemediationCooldown ?? @{}
    $remediationCooldownSec = 900

    $StackName = Get-StackName
    $AgentRoles = Get-ActiveAgentRoles

    if (-not $StackName) {
        Test-Step -Name "Stack detection" -Passed $false -Detail "No running stack found"
        Write-Warning "`n  Cannot proceed without a stack. Exiting."
        return 1
    }

    $errStackServices = $null
    $StackServices = $null
    $dockerRetries = @(2, 4, 8)
    for ($di = 0; $di -lt $dockerRetries.Count; $di++) {
        $errStackServices = $null
        $StackServices = docker stack services $StackName --format "{{.Name}}`t{{.Replicas}}`t{{.Image}}" 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $errStackServices += "$_`n"; $null } else { $_ }
        }
        if ($LASTEXITCODE -eq 0) { break }
        if ($di -lt $dockerRetries.Count - 1) {
            Write-SetupLog "docker stack services failed (attempt $($di+1)/$($dockerRetries.Count), exit $LASTEXITCODE) — retrying in $($dockerRetries[$di])s" -Level WARN
            Start-Sleep -Seconds $dockerRetries[$di]
        }
    }
    if ($errStackServices) { Write-SetupLog "StackServices stderr: $errStackServices" -Level WARN }

    $errAllVolumes = $null
    $AllVolumes = $null
    for ($di = 0; $di -lt $dockerRetries.Count; $di++) {
        $errAllVolumes = $null
        $AllVolumes = docker volume ls --format "{{.Name}}" 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $errAllVolumes += "$_`n"; $null } else { $_ }
        }
        if ($LASTEXITCODE -eq 0) { break }
        if ($di -lt $dockerRetries.Count - 1) {
            Write-SetupLog "docker volume ls failed (attempt $($di+1)/$($dockerRetries.Count), exit $LASTEXITCODE) — retrying in $($dockerRetries[$di])s" -Level WARN
            Start-Sleep -Seconds $dockerRetries[$di]
        }
    }
    if ($errAllVolumes) { Write-SetupLog "AllVolumes stderr: $errAllVolumes" -Level WARN }

    # No per-service HTTP health endpoints remain after session-worker retirement.
    $ServiceHealthEndpoints = @{}

    # Per-service mutex map to prevent concurrent checks on the same service
    if (-not $script:ServiceCheckMutexes) { $script:ServiceCheckMutexes = @{} }

    $checkList = @(
        @{ Name = "StackHealth";          Script = { Test-FleetStackHealth -StackName $args[0] -AgentRoles $args[1] -StackServices $args[2] };        Args = @($StackName, $AgentRoles, $StackServices); Wave = 1 }
        @{ Name = "NetworkConnectivity";  Script = { Test-FleetNetworkConnectivity -StackName $args[0] };                                        Args = @($StackName);                                    Wave = 1 }
        @{ Name = "SelfHealth";           Script = { Test-FleetSelfHealth };                                                                      Args = @();                                              Wave = 2 }
    )

    # Check for health suppression files
    $suppressAll = Test-Path (Join-Path $PSScriptRoot "../../../../Tasks/Logs/.suppress-health-all")
    if (-not $suppressAll) {
        $suppressedServices = @(Get-SuppressedHealthServices)
        $suppressFiles = Get-ChildItem (Join-Path $PSScriptRoot "../../../../Tasks/Logs/.suppress-health-*") -ErrorAction SilentlyContinue
        foreach ($sf in $suppressFiles) {
            $serviceName = $sf.Name -replace '^\.suppress-health-', ''
            $suppressedServices += $serviceName
        }
        $suppressedServices = @($suppressedServices | Select-Object -Unique)
    }

    $seqResults = [System.Collections.Generic.List[object]]::new()

    if ($suppressAll) {
        Write-Warning "Health check suppression active (global override) — all remediation skipped"
    }

    if ($Parallel) {
        $SimpleAgentRoles = $AgentRoles | ForEach-Object {
            @{ Role = $_.Role; Index = $_.Index; ShortName = $_.ShortName }
        }
        # Rebuild checklist with simplified agent roles for parallel runspaces
        $parallelCheckList = @(
            @{ Name = "StackHealth";          Script = { Test-FleetStackHealth -StackName $args[0] -AgentRoles $args[1] -StackServices $args[2] };        Args = @($StackName, $SimpleAgentRoles, $StackServices); Wave = 1 }
            @{ Name = "NetworkConnectivity";  Script = { Test-FleetNetworkConnectivity -StackName $args[0] };                                        Args = @($StackName);                                    Wave = 1 }
            @{ Name = "SelfHealth";           Script = { Test-FleetSelfHealth };                                                                      Args = @();                                              Wave = 2 }
        )

        $Wave1Checks = $parallelCheckList | Where-Object { $_.Wave -eq 1 }
        $Wave2Checks = $parallelCheckList | Where-Object { $_.Wave -eq 2 }

        $runParallelWave = {
            param($jobs)
            $jobs | ForEach-Object -Parallel {
                $job = $_
                Import-Module SalmonRun.Fleet
                $runspaceResults = [System.Collections.Generic.List[object]]::new()
                $serviceName = $job.Name
                # Drop the Windows-only "Global\" kernel-namespace prefix — it is
                # not supported by .NET's named-mutex implementation on Linux and
                # throws "The system cannot open the device or file specified" on
                # every health-check cycle inside the (Linux) is-fleet container.
                $mutexKey = "SalmonRunHealthCheck_${serviceName}"
                $serviceMutex = $null
                $mutexAcquired = $false
                try {
                    $serviceMutex = New-Object System.Threading.Mutex($false, $mutexKey)
                    $mutexAcquired = $serviceMutex.WaitOne(30000)
                    if (-not $mutexAcquired) {
                        Write-Warning "  [SKIP] $serviceName health check — another check in progress (mutex timeout)"
                        return $runspaceResults.ToArray()
                    }
                    $scriptArgs = $job.Args
                    $r = & $job.Script @scriptArgs
                    if ($r) { if ($r -is [array]) { $runspaceResults.AddRange($r) } else { $runspaceResults.Add($r) } }
                } catch {
                    $runspaceResults.Add(@{
                        Name = $job.Name
                        Passed = $false
                        Detail = "Parallel runspace error: $($_.Exception.Message)"
                        Remediation = "Check fleet logs for details"
                    })
                } finally {
                    if ($mutexAcquired -and $serviceMutex) { try { $serviceMutex.ReleaseMutex() } catch { Write-SetupLog "Mutex release failed (parallel): $($_.Exception.Message)" -Level WARN } }
                    if ($serviceMutex) { $serviceMutex.Dispose() }
                }
                return $runspaceResults.ToArray()
            } -ThrottleLimit 4
        }

        $Wave1Results = & $runParallelWave ($Wave1Checks)
        $Wave2Results = & $runParallelWave ($Wave2Checks)

        foreach ($r in @($Wave1Results + $Wave2Results | Where-Object { $_ -ne $null })) { if ($r -is [array]) { $seqResults.AddRange($r) } else { $seqResults.Add($r) } }
    } else {
        foreach ($check in $checkList) {
            $serviceName = $check.Name
            $mutexKey = "SalmonRunHealthCheck_${serviceName}"
            if (-not $script:ServiceCheckMutexes.ContainsKey($serviceName)) {
                $script:ServiceCheckMutexes[$serviceName] = New-Object System.Threading.Mutex($false, $mutexKey)
            }
            $serviceMutex = $script:ServiceCheckMutexes[$serviceName]
            $mutexAcquired = $false
            try {
                $mutexAcquired = $serviceMutex.WaitOne(30000)
                if (-not $mutexAcquired) {
                    Write-Warning "  [SKIP] $serviceName health check — another check in progress (mutex timeout)"
                    continue
                }
                $checkArgs = $check.Args
                $r = & $check.Script @checkArgs
                if ($r) { if ($r -is [array]) { $seqResults.AddRange($r) } else { $seqResults.Add($r) } }
            } finally {
                if ($mutexAcquired) { try { $serviceMutex.ReleaseMutex() } catch { Write-SetupLog "Mutex release failed: $($_.Exception.Message)" -Level WARN } }
            }
        }
    }

    # Telegram/AQE/SwarmReality checks retired 2026-08-21 — their targets
    # (oc-base Telegram gateway, mcp_aqe, agent containers) no longer exist.

    $script:Results = @($seqResults.ToArray() | Where-Object { $_ -ne $null })
    $script:FailCount = ($script:Results | Where-Object { -not $_.Passed }).Count

    Format-FleetHealthReport

    if ($script:FailCount -gt 0 -and $Mode -in @("fix", "auto")) {
        $failedTests = $script:Results | Where-Object { -not $_.Passed }
        $now = [DateTime]::UtcNow
        $freshTests = [System.Collections.Generic.List[object]]::new()
        foreach ($ft in $failedTests) {
            $testKey = $ft.Name
            if ($script:RemediationCooldown.ContainsKey($testKey)) {
                $lastRemediated = $script:RemediationCooldown[$testKey]
                $ageSec = ($now - $lastRemediated).TotalSeconds
                if ($ageSec -lt $remediationCooldownSec) {
                    Write-Warning "  [SKIP] $testKey — remediated $([math]::Round($ageSec))s ago (cooldown $remediationCooldownSec)s"
                    continue
                }
            }
            $freshTests.Add($ft)
        }
        if ($suppressAll) {
            Write-Warning "Health suppression active (global) — remediation skipped for $($freshTests.Count) failures"
            $script:RemediationActions = @()
        } elseif ($suppressedServices.Count -gt 0) {
            $filteredTests = @($freshTests | Where-Object { $_.Name -notmatch ($suppressedServices -join '|') })
            $skippedCount = $freshTests.Count - $filteredTests.Count
            if ($skippedCount -gt 0) {
                Write-Warning "Suppression active for services: $($suppressedServices -join ', ') - skipping $skippedCount failed tests"
            }
            $script:RemediationActions = Invoke-FleetRemediation -FailedTests $filteredTests -StackName $StackName
        } else {
            $script:RemediationActions = Invoke-FleetRemediation -FailedTests $freshTests -StackName $StackName
        }
        foreach ($ra in $script:RemediationActions) {
            if ($ra.Action -match '^Auto-fixed|docker service|Removed') {
                $script:RemediationCooldown[$ra.Test] = $now
            }
        }
    }

    return ($script:FailCount)
}
