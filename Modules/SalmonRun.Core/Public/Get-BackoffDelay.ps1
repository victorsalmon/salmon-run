<#
.SYNOPSIS
    Returns a backoff delay with random jitter from a schedule array.
.DESCRIPTION
    Returns the base delay from the schedule for the given attempt number,
    with uniform random jitter applied. For attempts beyond the schedule
    length, the last schedule value is doubled with jitter (capped at a
    configurable maximum). Designed to prevent thundering herd problems
    when multiple services retry simultaneously.
.PARAMETER Attempt
    Current retry attempt number (1-based).
.PARAMETER Schedule
    Array of base delays in seconds (e.g., @(30, 120, 300)).
.PARAMETER JitterFraction
    Fraction of base delay used for jitter range, default 0.25 (+/- 25%).
.PARAMETER MaxDelay
    Maximum delay in seconds, default 3600 (1 hour).
.OUTPUTS
    int. Delay in seconds with jitter applied.
.EXAMPLE
    $delay = Get-BackoffDelay -Attempt 2 -Schedule @(30, 120, 300)
    Returns ~120s +/- 25% jitter.
#>
function Get-BackoffDelay {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$Attempt,

        [int[]]$Schedule = @(),

        [ValidateRange(0.0, 1.0)]
        [double]$JitterFraction = 0.25,

        [int]$MaxDelay = 3600
    )

    if ($Schedule.Count -eq 0) { return [Math]::Min($MaxDelay, (Get-Random -Minimum 1 -Maximum 60)) }
    $index = [Math]::Min($Attempt - 1, $Schedule.Count - 1)
    $baseDelay = $Schedule[$index]

    if ($Attempt -gt $Schedule.Count) {
        $baseDelay = $Schedule[-1] * 2
    }

    if ($JitterFraction -le 0) {
        return [Math]::Min($MaxDelay, $baseDelay)
    }

    $jitter = $baseDelay * (1.0 - $JitterFraction + (Get-Random -Minimum 0.0 -Maximum ($JitterFraction * 2.0)))
    $delay = [Math]::Max(1, [Math]::Min([Math]::Round($jitter), $MaxDelay))

    return $delay
}
