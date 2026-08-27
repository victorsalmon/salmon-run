function Get-PondCapacity {
    <#
    .SYNOPSIS
        Returns whether the pond engine may start a new stream.
    .DESCRIPTION
        Throttles new work when recent crash history is high. If more than
        -MaxCrashesPerWindow crashes occurred within -WindowSeconds, the engine
        should wait before creating more streams.
    .PARAMETER CrashHistory
        List of recent crash timestamps.
    .PARAMETER MaxCrashesPerWindow
        Crash threshold. Default 3.
    .PARAMETER WindowSeconds
        Sliding window. Default 60.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [System.Collections.Generic.List[datetime]]$CrashHistory,

        [int]$MaxCrashesPerWindow = 3,

        [int]$WindowSeconds = 60
    )

    if (-not $CrashHistory -or $CrashHistory.Count -eq 0) { return $true }

    $cutoff = (Get-Date).AddSeconds(-$WindowSeconds)
    $recent = $CrashHistory | Where-Object { $_ -ge $cutoff }

    if ($recent.Count -ge $MaxCrashesPerWindow) {
        Write-Warning "POND_CAPACITY_THROTTLE crashes=$($recent.Count) window=${WindowSeconds}s"
        return $false
    }

    return $true
}

function Get-PondCrashThrottleDelay {
    <#
    .SYNOPSIS
        Computes an exponential backoff delay based on recent crashes.
    .DESCRIPTION
        Returns a delay in milliseconds. Callers can pass this to Start-Sleep.
    .PARAMETER CrashHistory
        List of recent crash timestamps.
    .PARAMETER BaseMs
        Initial delay. Default 1000.
    .PARAMETER CapMs
        Maximum delay. Default 30000.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [System.Collections.Generic.List[datetime]]$CrashHistory,

        [int]$BaseMs = 1000,

        [int]$CapMs = 30000
    )

    if (-not $CrashHistory -or $CrashHistory.Count -eq 0) { return 0 }

    $recentWindow = (Get-Date).AddMinutes(-5)
    $recent = $CrashHistory | Where-Object { $_ -ge $recentWindow }
    $delay = [math]::Min($CapMs, $BaseMs * [math]::Pow(2, $recent.Count - 1))
    return [int]$delay
}
