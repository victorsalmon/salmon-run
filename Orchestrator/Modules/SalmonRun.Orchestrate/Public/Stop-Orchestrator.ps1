<#
.SYNOPSIS
    Signals the orchestrator to stop after current operations complete.
.DESCRIPTION
    Creates stop signal files in the Tasks/ directory that all agent modes
    (code, review) check before starting work. Also writes a soft-stop flag
    for the orchestrator's main loop to drain active streams without
    dispatching new work.
.PARAMETER Force
    If set, creates a global stop signal (stops all modes) instead of mode-specific.
.PARAMETER Mode
    Mode to stop: code, review, audit, or all (default: all).
.OUTPUTS
    System.Void
.EXAMPLE
    Stop-Orchestrator -Mode code
    Stop-Orchestrator -Force
#>
function Stop-Orchestrator {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [switch]$Force,
        [ValidateSet("code", "review", "audit", "all")]
        [string]$Mode = "all"
    )

    $RepoDir = $script:RepoRoot

    if ($Force -or $Mode -eq "all") {
        $globalStop = Join-Path $RepoDir "Tasks/stop"
        $null = New-Item -ItemType File -Path $globalStop -Force
        Write-OrchestratorLog "STOP_SIGNAL_CREATED mode=all file=Tasks/stop"
        if ($Force) {
            Write-Host "[STOP] Global stop signal created — all modes will exit" -ForegroundColor Yellow
        }
    }

    if ($Mode -eq "code" -or $Mode -eq "all") {
        $codeStop = Join-Path $RepoDir "Tasks/stop.code"
        $null = New-Item -ItemType File -Path $codeStop -Force
        Write-OrchestratorLog "STOP_SIGNAL_CREATED mode=code file=Tasks/stop.code"
    }

    if ($Mode -eq "review" -or $Mode -eq "all") {
        $reviewStop = Join-Path $RepoDir "Tasks/stop.review"
        $null = New-Item -ItemType File -Path $reviewStop -Force
        Write-OrchestratorLog "STOP_SIGNAL_CREATED mode=review file=Tasks/stop.review"
    }

    if ($Mode -eq "audit" -or $Mode -eq "all") {
        $auditStop = Join-Path $RepoDir "Tasks/stop.audit"
        $null = New-Item -ItemType File -Path $auditStop -Force
        Write-OrchestratorLog "STOP_SIGNAL_CREATED mode=audit file=Tasks/stop.audit"
    }

    Write-Host "[STOP] Stop signal(s) created for mode: $Mode" -ForegroundColor Green
}

Export-ModuleMember -Function Stop-Orchestrator
