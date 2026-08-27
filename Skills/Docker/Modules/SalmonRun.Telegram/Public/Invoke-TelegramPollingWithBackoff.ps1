<#
.SYNOPSIS
    Polls Telegram API with exponential backoff and circuit breaker on errors.
.DESCRIPTION
    Wraps a Telegram API polling call with exponential backoff (1s, 2s, 4s, 8s, 16s, max 30s)
    on API errors. After 5 consecutive failures, enters circuit-breaker mode — polls every 5 min
    instead of every 2s. Resets backoff on success.
.PARAMETER PollAction
    Script block that performs a single Telegram poll/API call. Should return $true on success,
    $false or throw on error.
.PARAMETER BaseIntervalSec
    Base polling interval in seconds (default: 2). Used as the starting delay.
.PARAMETER MaxBackoffSec
    Maximum exponential backoff in seconds (default: 30).
.PARAMETER CircuitBreakerThreshold
    Consecutive failures before entering circuit-breaker mode (default: 5).
.PARAMETER CircuitBreakerIntervalSec
    Polling interval in circuit-breaker mode (default: 300 / 5 min).
.OUTPUTS
    Runs indefinitely (infinite polling loop). Write-FleetLog entries for state transitions.
#>
function Invoke-TelegramPollingWithBackoff {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$PollAction,
        [int]$BaseIntervalSec = 2,
        [int]$MaxBackoffSec = 30,
        [int]$CircuitBreakerThreshold = 5,
        [int]$CircuitBreakerIntervalSec = 300
    )
    $consecutiveFailures = 0
    $circuitBreakerActive = $false
    $successCount = 0

    while ($true) {
        try {
            if ($circuitBreakerActive) {
                Write-FleetLog "Telegram polling: circuit-breaker active — sleeping ${CircuitBreakerIntervalSec}s"
                Start-Sleep -Seconds $CircuitBreakerIntervalSec
            }
            $result = & $PollAction
            if ($result) {
                if ($circuitBreakerActive) {
                    Write-FleetLog "Telegram polling: circuit-breaker reset (success after $consecutiveFailures failures)"
                    $circuitBreakerActive = $false
                }
                if ($consecutiveFailures -gt 0) {
                    Write-FleetLog "Telegram polling: backoff reset after ${consecutiveFailures} consecutive failures"
                }
                $consecutiveFailures = 0
                $successCount++
                Start-Sleep -Seconds $BaseIntervalSec
            } else {
                throw "PollAction returned false"
            }
        } catch {
            $consecutiveFailures++
            Write-FleetLog "Telegram polling: error (failure #$consecutiveFailures): $($_.Exception.Message)" -Level WARN

            if ($consecutiveFailures -ge $CircuitBreakerThreshold) {
                if (-not $circuitBreakerActive) {
                    Write-FleetLog "Telegram polling: circuit-breaker engaged after ${consecutiveFailures} consecutive failures — polling every ${CircuitBreakerIntervalSec}s"
                    $circuitBreakerActive = $true
                }
                Start-Sleep -Seconds $CircuitBreakerIntervalSec
            } else {
                $backoffSec = [math]::Min([math]::Pow(2, $consecutiveFailures - 1), $MaxBackoffSec)
                Write-FleetLog "Telegram polling: backing off ${backoffSec}s"
                Start-Sleep -Seconds $backoffSec
            }
        }
    }
}
