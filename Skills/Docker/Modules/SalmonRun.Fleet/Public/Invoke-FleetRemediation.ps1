<#
.SYNOPSIS
    Runs remediation actions for failed fleet health checks.
.DESCRIPTION
    Inspects each failed test result and applies the appropriate fix
    (e.g. force-restart service, remove orphaned volumes/networks).
    With the 2026-08-21 MCP/Hermes/openclaw retirement and 2026-08-25
    session-worker retirement, the only service is is-fleet. Agent-specific and
    mcp_opencode-specific remediation branches have been removed.
.PARAMETER FailedTests
    Array of failed test result objects from Invoke-FleetHealthCheck.
.OUTPUTS
    Hashtable mapping service names to remediation outcomes.
#>
function Invoke-RemedyWithRetry {
    [OutputType([hashtable])]
    param(
        [string]$TestName,
        [scriptblock]$AttemptAction,
        [int]$MaxAttempts = 3,
        [int[]]$BackoffSeconds = @(30, 120, 300)
    )
    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        Write-FleetLog "Remediation attempt $Attempt/$MaxAttempts for '$TestName'" -Level INFO
        try {
            $Result = & $AttemptAction
            if ($Result -and $Result.Success) {
                Write-FleetLog "Remediation '$TestName' succeeded on attempt $Attempt" -Level INFO
                return @{ Test = $TestName; Action = "Auto-fixed (attempt $Attempt): $($Result.Detail)" }
            }
        } catch {
            Write-FleetLog "Remediation attempt $Attempt failed: $_" -Level WARN
        }
        if ($Attempt -lt $MaxAttempts) {
            $Delay = Get-BackoffDelay -Attempt $Attempt -Schedule $BackoffSeconds -JitterFraction 0.25
            $base = $BackoffSeconds[[Math]::Min($Attempt - 1, $BackoffSeconds.Count - 1)]
            Write-FleetLog "Backing off ${Delay}s (base ${base}s with jitter) before retry $($Attempt+1)/$MaxAttempts" -Level DEBUG
            Start-Sleep -Seconds $Delay
        }
    }
    return @{ Test = $TestName; Action = "NEEDS MANUAL FIX after $MaxAttempts attempts: Re-run 0setup.ps1 to rehydrate secrets" }
}

function Invoke-FleetRemediation {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [array]$FailedTests,

        [Parameter(Mandatory)]
        [string]$StackName
    )

        $Fixes = [System.Collections.Generic.List[object]]::new()

        foreach ($Test in $FailedTests) {
            if ($script:CompletedRemediations) {
                $doneKey = $Test.Name -replace '\s+', '-'
                if ($script:CompletedRemediations.ContainsKey($doneKey)) {
                    Write-FleetLog "Idempotency guard: '$($Test.Name)' already remediated this cycle — skipping" -Level DEBUG
                    continue
                }
                $script:CompletedRemediations[$doneKey] = (Get-Date).ToString('o')
            }
            switch -Regex ($Test.Name) {
                # Service has 0 replicas — restart it
                "replicas$" {
                    $SvcName = $Test.Name -replace "\s+replicas$", ""
                    $FullSvcName = docker stack services $StackName --format "{{.Name}}" 2>$null |
                        Where-Object { $_ -match "${StackName}_${SvcName}`$" }
                    if (-not $FullSvcName) { $FullSvcName = $SvcName }
                    Write-Warning "  [FIX] Restarting service: $FullSvcName"
                    $capturedSvc = $FullSvcName
                    $null = Invoke-DockerWithLogging -Command { docker service update --force $capturedSvc 2>&1 } -OperationLabel "Force restart $FullSvcName"
                    $Fixes.Add(@{ Test = $Test.Name; Action = "docker service update --force $FullSvcName" })
                }

                # Double-prefixed volumes — clean them up
                "Double-prefixed volume" {
                    Write-Warning "  [FIX] Removing double-prefixed volumes"
                    $AllVols = docker volume ls --format "{{.Name}}" 2>$null
                    $DoubleVols = $AllVols | Where-Object { $_ -match "^${StackName}_${StackName}_" }
                    foreach ($Vol in $DoubleVols) {
                        Write-Verbose "    Removing: $Vol"
                        $capturedVol = $Vol
                        $null = Invoke-DockerWithLogging -Command { docker volume rm $capturedVol 2>&1 } -OperationLabel "Removing double-prefixed volume $Vol"
                    }
                    $Fixes.Add(@{ Test = $Test.Name; Action = "Removed $($DoubleVols.Count) double-prefixed volumes" })
                }

                # Orphaned networks — clean them up
                "Orphaned networks" {
                    Write-Warning "  [FIX] Removing orphaned networks"
                    $Orphans = docker network ls --format "{{.Name}}" 2>$null |
                        Where-Object { ($_ -match "^${StackName}_.*_.*_net") -or (($_ -match "^${StackName}_") -and ($_ -notmatch "^${StackName}_(service|orchestration|management)_net"))}
                    foreach ($Net in $Orphans) {
                        Write-Verbose "    Removing: $Net"
                        $capturedNet = $Net
                        $null = Invoke-DockerWithLogging -Command { docker network rm $capturedNet 2>&1 } -OperationLabel "Removing orphaned network $Net"
                    }
                    $Fixes.Add(@{ Test = $Test.Name; Action = "Removed $($Orphans.Count) orphaned networks" })
                }

                default {
                    $Fixes.Add(@{ Test = $Test.Name; Action = "No known auto-fix available" })
                }
        }

        }
        return , $Fixes.ToArray()
    }
