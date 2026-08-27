<#
.SYNOPSIS
    Verifies post-deployment fleet health by polling service replica counts.
.DESCRIPTION
    Polls docker stack services until all expected services reach desired
    replica counts or max retries are exhausted. Reports failed services.
.PARAMETER
    This function takes no parameters. Uses $StackName from caller scope.
.OUTPUTS
    None.
#>
function Test-FleetDeployment {
    [OutputType([void])]
    param(
        [string]$StackName,
        [hashtable[]]$AgentConfigs,
        [string]$ProjectCode,
        [string]$SovereigntyTier,
        [string]$ImageVersion
    )
Write-SetupLog "Phase 6: Post-deployment verification"
Write-Information -MessageData "`n[FleetHealth] Service Status Overview:" -Tags "INFO"

    $MaxRetries = (Get-InterclawConstants).HealthCheckMaxRetries
    $RetryInterval = (Get-InterclawConstants).HealthCheckRetryIntervalSec

    for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {
    Write-Information -MessageData "  Checking service health (attempt $Attempt/$MaxRetries)..." -Tags "INFO"
    Start-Sleep -Seconds (Get-BackoffDelay -Attempt $Attempt -Schedule @($RetryInterval, $RetryInterval, $RetryInterval, $RetryInterval) -JitterFraction 0.1)

    $ServiceResults = docker stack services $StackName --format "{{.Name}}`t{{.Replicas}}`t{{.Image}}" 2>&1
    if (-not $?) {
        Write-SetupLog "docker stack services command failed for $StackName" -Level ERROR
    }
    $ServiceLines = $ServiceResults | Where-Object { $_ -is [string] }
    $ServiceErrors = $ServiceResults | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    if ($ServiceErrors) {
        Write-SetupLog "docker stack services stderr: $($ServiceErrors -join '; ')" -Level WARN
    }
    $ServiceFailures = @()
    $AllReady = $true

    foreach ($SvcLine in $ServiceLines) {
        if ([string]::IsNullOrWhiteSpace($SvcLine)) { continue }
        $Parts = $SvcLine -split "`t"
        $SvcName = $Parts[0]
        $Replicas = $Parts[1]
        $Image = $Parts[2]

        if ($Replicas -match "^0/") {
            $AllReady = $false
            $ServiceFailures += $SvcName
        }
        elseif ($Replicas -match "^[1-9]/[1-9]$") {
            # Service is healthy
        }
        else {
            $AllReady = $false
        }
    }

    if ($AllReady) {
        Write-Information -MessageData "  All services ready after $Attempt attempt(s)." -Tags "INFO"
        break
    }

    if ($Attempt -lt $MaxRetries) {
        Write-Information -MessageData "  Not all services ready yet, retrying in ${RetryInterval}s..." -Tags "WARN"
    }
}

foreach ($SvcLine in $ServiceLines) {
    if ([string]::IsNullOrWhiteSpace($SvcLine)) { continue }
    $Parts = $SvcLine -split "`t"
    $SvcName = $Parts[0]
    $Replicas = $Parts[1]
    $Image = $Parts[2]

    if ($Replicas -match "^0/") {
        Write-Information -MessageData "  [FAIL] $SvcName ($Replicas replicas, $Image)" -Tags "ERROR"
        Write-SetupLog "Service FAIL: $SvcName ($Replicas, $Image)" -Level ERROR
    }
    elseif ($Replicas -match "^[1-9]/[1-9]$") {
        Write-Information -MessageData "  [OK]   $SvcName ($Replicas, $Image)" -Tags "INFO"
        Write-SetupLog "Service OK: $SvcName ($Replicas)"
    }
    else {
        Write-Information -MessageData "  [WAIT] $SvcName ($Replicas, $Image)" -Tags "WARN"
        Write-SetupLog "Service WAIT: $SvcName ($Replicas)" -Level WARN
    }
}
if ($ServiceFailures.Count -gt 0) {
    Write-Information -MessageData "`n  [WARN] $($ServiceFailures.Count) service(s) have 0 replicas:" -Tags "WARN"
    foreach ($Failed in $ServiceFailures) {
        Write-Information -MessageData "    - $Failed" -Tags "ERROR"
        $ErrorLogs = docker service logs $Failed --tail 5 2>&1
        if (-not [string]::IsNullOrWhiteSpace($ErrorLogs)) {
            Write-Information -MessageData "      Last logs:" -Tags "INFO"
            foreach ($Line in ($ErrorLogs -split "`n" | Select-Object -Last 3)) {
                Write-Information -MessageData "      $Line" -Tags "INFO"
            }
        }
    }
}

Write-Information -MessageData "`n[COMPLETED] Fleet of $($AgentConfigs.Count) agent(s) for Project $ProjectCode has been provisioned." -Tags "INFO"
$DeploySummary = @()
foreach ($Ac in $AgentConfigs) {
    $NameDisplay = if ($Ac.DisplayName) { " ($($Ac.DisplayName))" }
    $DeploySummary += "  - $($Ac.AgentName)$NameDisplay (prefix=$($Ac.Prefix), port=$($Ac.GatewayPort))"
    Write-Information -MessageData $DeploySummary[-1] -Tags "INFO"
}
    Write-Information -MessageData "`n  Image version: $ImageVersion" -Tags "INFO"
    Write-Information -MessageData "  Fleet version:  fleet:$ImageVersion" -Tags "INFO"
Write-Information -MessageData "  Sovereignty:    $SovereigntyTier" -Tags "INFO"
Write-Information -MessageData "  Services:       $($($ServiceLines | Measure-Object).Count) total, $($ServiceFailures.Count) failing" -Tags "INFO"
Write-SetupLog "Phase 6 complete: post-deployment verification done ($($ServiceFailures.Count) failures)"
Write-SetupLog "1Deploy complete"
}

