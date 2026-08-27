<#
.SYNOPSIS
    Checks HTTP endpoint health for API-based services.
.DESCRIPTION
    Tests each configured service endpoint with an HTTP GET request.
    A running-but-hung container returns non-200 or times out.
.PARAMETER EndpointMap
    Hashtable mapping service names to health check URLs.
#>
function Test-FleetServiceEndpoints {
    [OutputType([array])]
    param([hashtable]$EndpointMap)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[ServiceEndpointHealth] HTTP endpoint health checks"
    foreach ($entry in $EndpointMap.GetEnumerator()) {
        $svcName = $entry.Key
        $url = $entry.Value
        if ([string]::IsNullOrWhiteSpace($url)) {
            $r = Test-Step -Name "$svcName endpoint" -Passed $true -Detail "No endpoint configured (skipped)" -PassThru; if ($r) { $results.Add($r) }
            continue
        }
        try {
            $Response = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            $r = Test-Step -Name "$svcName endpoint" -Passed:($Response.StatusCode -eq 200) -Detail "HTTP $($Response.StatusCode)" -PassThru; if ($r) { $results.Add($r) }
        } catch {
            $r = Test-Step -Name "$svcName endpoint" -Passed $false -Detail "Unreachable: $($_.Exception.Message)" -PassThru; if ($r) { $results.Add($r) }
        }
    }
    return $results.ToArray()
}
