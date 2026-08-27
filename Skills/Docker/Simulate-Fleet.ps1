<#
.DEPRECATED
    This script is an ad-hoc diagnostic tool with no known automated callers.
    Fleet load testing is now performed via the fleet health check framework
    (Invoke-FleetHealthCheck.ps1) and the Simulate-Fleet.ps1 container entrypoint
    in the fleet runtime. Retained for standalone dry-run testing only.

.SYNOPSIS
    Simulates Fleet load testing against the AQE bridge.

.DESCRIPTION
    Sends a load test request to the AQE bridge's qe_tests_load tool with configurable
    profile (light/medium/heavy), target agent count, and duration. Reports bottlenecks,
    pass/fail status, and recommendations.
#>
param(
    [ValidateSet("light", "medium", "heavy")]
    [string]$Profile = "medium",
    [int]$TargetAgents = 10,
    [int]$DurationMs = 30000,
    [switch]$Quick
)

$ErrorActionPreference = "Stop"
$BridgeUrl = "http://mcp_aqe:21004"  # See Infrastructure/port-registry.json

# ==== DEFINE LOAD PROFILE CONFIGURATIONS ====
$ProfileParams = @{
    light  = @{ concurrent = 2;  task_rate = 5;  memory_mb = 512 }
    medium = @{ concurrent = 10; task_rate = 20; memory_mb = 1024 }
    heavy  = @{ concurrent = 25; task_rate = 50; memory_mb = 2048 }
}

if ($Quick) {
    $Profile = "light"
    $TargetAgents = 5
    $DurationMs = 10000
}

$Params = $ProfileParams[$Profile]
$Params.target_agents = $TargetAgents
$Params.duration_ms = $DurationMs

# ==== BEGIN SIMULATION ====
Write-Information -MessageData "`n  AQE Fleet Simulation" -InformationAction Continue
Write-Information -MessageData "  Profile:     $Profile$(if ($Quick) { ' (quick)' })" -InformationAction Continue
Write-Information -MessageData "  Agents:      $TargetAgents" -InformationAction Continue
Write-Information -MessageData "  Duration:    ${DurationMs}ms" -InformationAction Continue
Write-Information -MessageData "  Concurrent:  $($Params.concurrent)" -InformationAction Continue
Write-Information -MessageData "  Task rate:   $($Params.task_rate)/s" -InformationAction Continue
Write-Information -MessageData "  Memory:      $($Params.memory_mb)MB`n" -InformationAction Continue

try {
    $Response = Invoke-RestMethod -Uri "${BridgeUrl}/tools/qe_tests_load" -Method POST -Body ($Params | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 120

    if ($Quick) {
        $Passed = $Response.passed
        Write-Information -MessageData "  Result: $(if ($Passed) { 'PASS' } else { 'FAIL' })" -InformationAction Continue -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' })
        if (-not $Passed -and $Response.bottlenecks) {
            Write-Information -MessageData "  Bottlenecks:" -InformationAction Continue
            foreach ($B in $Response.bottlenecks) { Write-Information -MessageData "    - $B" -InformationAction Continue }
        }
    } else {
        Write-Information -MessageData "  Results:" -InformationAction Continue
        if ($Response.bottlenecks -and $Response.bottlenecks.Count -gt 0) {
            Write-Information -MessageData "  [WARN] Bottlenecks:" -InformationAction Continue
            foreach ($B in $Response.bottlenecks) { Write-Information -MessageData "    - $B" -InformationAction Continue }
        } else {
            Write-Information -MessageData "  [OK]   No bottlenecks detected" -InformationAction Continue
        }

        $Passed = $Response.passed
        Write-Information -MessageData "  Status: $(if ($Passed) { 'PASS' } else { 'FAIL' })" -InformationAction Continue -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' })

        if ($Response.recommendations -and $Response.recommendations.Count -gt 0) {
            Write-Information -MessageData "`n  Recommendations:" -InformationAction Continue
            foreach ($R in $Response.recommendations) { Write-Information -MessageData "    - $R" -InformationAction Continue }
        }
    }

    $SimResult = @{
        timestamp      = (Get-Date -Format "o")
        profile        = $Profile
        target_agents  = $TargetAgents
        duration_ms    = $DurationMs
        quick          = $Quick.IsPresent
        passed         = $Response.passed
        bottlenecks    = $Response.bottlenecks
        recommendations = $Response.recommendations
    }
    $ReportsDir = Get-ReportsDir
    $ReportFile = Join-Path $ReportsDir "Fleet-load-sim-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $SimResult | Write-AtomicJson -Path $ReportFile -Depth 3
    Write-Information -MessageData "`n  Report saved: $ReportFile" -InformationAction Continue

    if ($Response.bottlenecks -and $Response.bottlenecks.Count -gt 0) {
        Write-Information -MessageData "`n  Actionable bottlenecks:" -InformationAction Continue
        foreach ($B in $Response.bottlenecks) {
            Write-Information -MessageData "    - $B" -InformationAction Continue
        }
    }

    exit 0
} catch {
    Write-Information -MessageData "  [ERROR] Simulation failed: $($_.Exception.Message)" -InformationAction Continue
    exit 1
}
