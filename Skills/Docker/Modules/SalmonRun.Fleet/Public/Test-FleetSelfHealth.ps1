function Test-FleetSelfHealth {
    <#
    .SYNOPSIS
        Validates the Fleet container's own health endpoint is responding.
    .OUTPUTS
        System.Object[]
    #>
    [OutputType([array])]
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[9] Fleet Health Endpoint"
    $monitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $authHeaders = @{}
    if ($monitorToken) { $authHeaders["Authorization"] = "Bearer $monitorToken" }
    try {
        $FleetHealthResp = Invoke-RestMethod -Uri "http://is-fleet:$(Get-ServicePort -Service "is-fleet")/health" -TimeoutSec 5 -Headers $authHeaders -ErrorAction Stop
        $r = Test-Step -Name "Fleet health endpoint" -Passed:($FleetHealthResp.status -eq "ok") -Detail "status: $($FleetHealthResp.status), uptime: $($FleetHealthResp.uptimeSeconds)s, fails: $($FleetHealthResp.failCount)" -PassThru; if ($r) { $results.Add($r) }
    } catch {
        $r = Test-Step -Name "Fleet health endpoint" -Passed $false -Detail $_.Exception.Message -PassThru; if ($r) { $results.Add($r) }
    }
    if ($results) { return $results.ToArray() }
}
