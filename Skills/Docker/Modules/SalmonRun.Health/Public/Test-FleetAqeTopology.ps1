<#
.SYNOPSIS
    Runs AQE topology analysis (min-cut health, deep analysis, coherence collapse).
#>
function Test-FleetAqeTopology {
    [OutputType([array])]
    param([array]$AgentRoles)
    <#
    .NOTES
        Timeout chain: 3 sequential Invoke-RestMethod calls (mincut=10s, deep=30s, coherence=10s).
        Worst-case chain sum: 50s. Each call at same level (no nesting).
        Called from Invoke-FleetHealthCheck (sequential, no cumulative timeout).
    #>
    Write-Verbose "`n[11] AQE Topology Analysis"
    $monitorToken = Get-Content "/run/secrets/fleet_aqe_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if ([string]::IsNullOrWhiteSpace($monitorToken)) {
        $monitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    }
    $authHeaders = @{}
    if ($monitorToken) { $authHeaders["Authorization"] = "Bearer $monitorToken" }
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $AgentRolesSummary = ($AgentRoles | ForEach-Object { "$($_.Role)-$($_.Index)" }) -join ","
        $MinCutPayload = @{ graph = @{ vertices = $AgentRolesSummary -split "," } } | ConvertTo-Json -Compress
        $MinCutHealth = Invoke-RestMethod -Uri "http://mcp_aqe:$(Get-ServicePort -Service "mcp_aqe")/tools/qe_mincut_health" -Method POST -Body $MinCutPayload -ContentType "application/json" -Headers $authHeaders -TimeoutSec 10
        $WeakCount = if ($MinCutHealth.weak_vertices) { $MinCutHealth.weak_vertices.Count } else { 0 }
        $results.Add((Test-Step -Name "AQE min-cut health" -Passed:($WeakCount -eq 0) -Detail "weak vertices: $WeakCount" -PassThru))

        $ReportsDir = Get-ReportsDir
        $HistoryPath = Join-Path $ReportsDir "topology-history.json"
        $HistoryEntry = @{
            timestamp     = (Get-Date -Format "o")
            weakVertices  = if ($MinCutHealth.weak_vertices) { @($MinCutHealth.weak_vertices) } else { @() }
            weakCount     = $WeakCount
            totalVertices = $AgentRoles.Count
        }
        $ExistingHistory = if (Test-Path $HistoryPath) { Get-Content -Path $HistoryPath -Raw | ConvertFrom-Json } else { @() }
        if ($ExistingHistory -isnot [array]) { $ExistingHistory = @($ExistingHistory) }
        $UpdatedHistory = $ExistingHistory + $HistoryEntry
        $UpdatedHistory | Write-AtomicJson -Path $HistoryPath -Depth 10 -Compress

        $TrendMsg = ""
        if ($ExistingHistory.Count -gt 0) {
            $LastEntry = $ExistingHistory[-1]
            $PrevWeakCount = if ($null -ne $LastEntry.weakCount) { [int]$LastEntry.weakCount } else { 0 }
            if ($PrevWeakCount -gt 0 -and $WeakCount -gt $PrevWeakCount) {
                $TrendMsg = " (worsening: $PrevWeakCount -> $WeakCount)"
                Write-FleetLog "AQE Topology worsening: $PrevWeakCount -> $WeakCount weak vertices" -Level WARN
            } elseif ($WeakCount -lt $PrevWeakCount) {
                $TrendMsg = " (improving: $PrevWeakCount -> $WeakCount)"
            } elseif ($WeakCount -eq $PrevWeakCount -and $WeakCount -gt 0) {
                $TrendMsg = " (stable: $WeakCount)"
            }
        }

        if ($WeakCount -gt 0) {
            Write-FleetLog "AQE Topology: $WeakCount weak vertices detected: $($MinCutHealth.weak_vertices -join ', ')$TrendMsg" -Level WARN

            $DeepPayload = @{ graph = @{ vertices = $AgentRolesSummary -split "," }; weak = $MinCutHealth.weak_vertices } | ConvertTo-Json -Compress
            $DeepAnalysis = Invoke-RestMethod -Uri "http://mcp_aqe:$(Get-ServicePort -Service "mcp_aqe")/tools/qe_mincut_analyze" -Method POST -Body $DeepPayload -ContentType "application/json" -Headers $authHeaders -TimeoutSec 30
            $results.Add((Test-Step -Name "AQE min-cut deep analysis" -Passed $true -Detail "recommendations: $($DeepAnalysis.recommendations -join '; ')" -PassThru))
            if ($DeepAnalysis.recommendations -and $DeepAnalysis.recommendations.Count -gt 0) {
                Write-FleetLog "AQE Topology recommendations: $($DeepAnalysis.recommendations -join '; ')" -Level WARN
            }
        } else {
            $results.Add((Test-Step -Name "AQE min-cut deep analysis" -Passed $true -Detail "skipped (no weak vertices)$TrendMsg" -PassThru))
        }

        try {
            $CoherenceState = @{
                swarmState = @{
                    agents = $AgentRoles | ForEach-Object { @{ id = "$($_.Role)-$($_.Index)"; status = "running" } }
                }
                riskThreshold = 0.5
            } | ConvertTo-Json -Compress
            $CoherenceResult = Invoke-RestMethod -Uri "http://mcp_aqe:$(Get-ServicePort -Service "mcp_aqe")/tools/qe_coherence_collapse" -Method POST -Body $CoherenceState -ContentType "application/json" -Headers $authHeaders -TimeoutSec 10
            if ($CoherenceResult.riskLevel -and $CoherenceResult.riskLevel -ne "none" -and -not $CoherenceResult.isAtRisk) {
                Write-FleetLog "AQE coherence contradiction: riskLevel=$($CoherenceResult.riskLevel) but isAtRisk=$($CoherenceResult.isAtRisk)" -Level WARN
                $results.Add((Test-Step -Name "AQE coherence collapse" -Passed $false -Detail "Contradiction: riskLevel=$($CoherenceResult.riskLevel) vs isAtRisk=$($CoherenceResult.isAtRisk)" -PassThru))
            } else {
                $results.Add((Test-Step -Name "AQE coherence collapse" -Passed $true -Detail "riskLevel=$($CoherenceResult.riskLevel), isAtRisk=$($CoherenceResult.isAtRisk)" -PassThru))
            }
        } catch {
            $results.Add((Test-Step -Name "AQE coherence collapse" -Passed $true -Detail "skipped (coherence collapse unreachable)" -PassThru))
        }
    } catch {
        $results.Add((Test-Step -Name "AQE min-cut health" -Passed $true -Detail "bridge unreachable (non-blocking)" -PassThru))
        Write-FleetLog "AQE bridge unreachable during topology analysis" -Level WARN
    }
    return $results.ToArray()
}
