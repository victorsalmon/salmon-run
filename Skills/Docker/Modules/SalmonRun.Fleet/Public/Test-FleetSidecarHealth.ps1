<#
.SYNOPSIS
    Test health of sidecar services (mcp_browserless, mcp_opencode).
.DESCRIPTION
    Iterates over the stack service list and runs HTTP health checks against
    each discovered sidecar service. Reports pass/fail via Test-Step.
.PARAMETER StackServices
    Array of service name strings from the deployed Docker Swarm stack.
#>
function Test-FleetSidecarHealth {
    [OutputType([array])]
    param([array]$StackServices)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[8] Sidecar Services"
    $monitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $authHeaders = @{}
    if ($monitorToken) { $authHeaders["Authorization"] = "Bearer $monitorToken" }
    $AllSvcNames = $StackServices | ForEach-Object { ($_ -split "`t")[0] }

    $McpBrowserlessService = $AllSvcNames | Where-Object { $_ -match 'mcp_browserless' }
    if ($McpBrowserlessService) {
        try {
            $Health = Invoke-RestMethod -Uri "http://mcp_browserless:$(Get-ServicePort -Service "mcp_browserless")/health" -Method GET -Headers $authHeaders -TimeoutSec 5
            $r = Test-Step -Name "MCP browserless health endpoint" -Passed ($Health.status -eq "ok") -Detail "uptime=$($Health.uptime)" -PassThru; if ($r) { $results.Add($r) }
        } catch {
            $r = Test-Step -Name "MCP browserless health endpoint" -Passed $false -Detail $_.Exception.Message -Remediation "Verify mcp_browserless is running" -PassThru; if ($r) { $results.Add($r) }
        }
    }

    $FunnelProxyService = $AllSvcNames | Where-Object { $_ -match 'funnel-proxy' }
    if ($FunnelProxyService) {
        try {
            $Health = Invoke-RestMethod -Uri "http://funnel-proxy:$(Get-ServicePort -Service "funnel_proxy")/health" -Method GET -Headers $authHeaders -TimeoutSec 5
            $r = Test-Step -Name "funnel-proxy health endpoint" -Passed ($null -ne $Health) -Detail "nginx proxy reachable" -PassThru; if ($r) { $results.Add($r) }
        } catch {
            $r = Test-Step -Name "funnel-proxy health endpoint" -Passed $false -Detail $_.Exception.Message -Remediation "Verify funnel-proxy is running" -PassThru; if ($r) { $results.Add($r) }
        }
    }

    $McpOpencodeService = $AllSvcNames | Where-Object { $_ -match 'mcp_opencode' }
    if ($McpOpencodeService) {
        try {
            $Health = Invoke-RestMethod -Uri "http://mcp_opencode:$(Get-ServicePort -Service "mcp_opencode_health")" -Method GET -Headers $authHeaders -TimeoutSec 5
            $Detail = "status=$($Health.status) sessions=$($Health.sessions) keys=$($Health.key_count) limit=$($Health.session_limit)"
            $r = Test-Step -Name "mcp_opencode health endpoint" -Passed ($Health.status -eq "server") -Detail $Detail -PassThru; if ($r) { $results.Add($r) }
        } catch {
            $r = Test-Step -Name "mcp_opencode health endpoint" -Passed $false -Detail $_.Exception.Message -Remediation "Verify mcp_opencode is running and port $(Get-ServicePort -Service "mcp_opencode_health") is reachable" -PassThru; if ($r) { $results.Add($r) }
        }
    }
    return $results.ToArray()
}
