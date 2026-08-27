function Invoke-SalmonRunAQEBridge {
    <#
    .SYNOPSIS
        Calls an optional AQE HTTP bridge for external quality scans.
    .DESCRIPTION
        Sends a JSON payload to the bridge configured by $env:SALMON_AQE_BRIDGE_URI.
        If the bridge is not configured or unreachable, the call fails gracefully
        and returns a skipped result without throwing.
    .PARAMETER Payload
        Hashtable/PSCustomObject payload to send.
    .PARAMETER TimeoutSeconds
        Default 60.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object]$Payload,

        [int]$TimeoutSeconds = 60
    )

    $uri = $env:SALMON_AQE_BRIDGE_URI
    if ([string]::IsNullOrWhiteSpace($uri)) {
        return [PSCustomObject]@{ Skipped = $true; Reason = 'SALMON_AQE_BRIDGE_URI not set' }
    }

    $body = $Payload | ConvertTo-Json -Depth 5 -Compress
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return [PSCustomObject]@{ Skipped = $false; Response = $response }
    } catch {
        return [PSCustomObject]@{ Skipped = $true; Reason = 'Bridge unreachable'; Error = $_.Exception.Message }
    }
}
