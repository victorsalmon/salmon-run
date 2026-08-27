<#
.SYNOPSIS
    Rate-limited failure tracker for Fleet remediation operations.
.DESCRIPTION
    Tracks consecutive remediation failures per failure key and implements
    logarithmic backoff: logs the first 3 failures, then every 6th occurrence.
    Prevents alert fatigue from persistent-but-known issues.
.PARAMETER FailureKey
    Unique string identifier for the failure condition being tracked.
#>
$script:FailureTracker = @{}

<#
.SYNOPSIS
Rate-limits remediation failure logging to avoid repeated alerts for the same issue.
#>
function Should-LogRemediationFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$FailureKey)
    $Now = Get-Date
    if (-not $script:FailureTracker.ContainsKey($FailureKey)) {
        $script:FailureTracker[$FailureKey] = @{
            ConsecutiveCount = 0
            FirstSeen        = $Now
            LastLogged       = $Now
        }
    }
    $Tracker = $script:FailureTracker[$FailureKey]
    $Tracker.ConsecutiveCount++

    $ShouldLog = switch ($Tracker.ConsecutiveCount) {
        { $_ -le 3 }    { $true }
        { $_ % 6 -eq 0 } { $true }
        default          { $false }
    }

    if ($ShouldLog) {
        $Tracker.LastLogged = $Now
    }
    return $ShouldLog
}

<#
.SYNOPSIS
    Resets the failure tracking counter for a specific failure key.
.DESCRIPTION
    Removes the tracked failure entry so the next failure for the same key
    starts fresh with the first-3-logged rate-limiting window.
.PARAMETER FailureKey
    The failure key whose counter to reset.
#>
function Reset-RemediationFailureTracking {
    [CmdletBinding()]
    [OutputType([void])]
    param([string]$FailureKey)
    $script:FailureTracker.Remove($FailureKey)
}
