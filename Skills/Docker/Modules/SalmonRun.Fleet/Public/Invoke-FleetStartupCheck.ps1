<#
.SYNOPSIS
    Performs initial startup verification for the fleet container.
.DESCRIPTION
    Checks that the fleet can reach Docker Swarm, queries
    service status, and logs the initial fleet state on startup.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    $true if startup checks pass, $false otherwise.
#>
function Invoke-FleetStartupCheck {
    [OutputType([bool])]
    param()
    Write-FleetLog "Running on-demand startup check"
    Write-Verbose "`n[COMMAND] Running startup health check..."
    try {
        $ExitCode = Invoke-FleetStartupVerification
        if ($ExitCode -eq 0) {
            Write-Verbose "  [OK] Startup check passed."
            Write-FleetLog "Startup check passed"
        }
        else {
            Write-Warning "  [WARN] Startup check found $ExitCode issue(s)."
            Write-FleetLog "Startup check found $ExitCode issue(s)" -Level WARN
        }
    }
    catch {
        Write-Warning "  [ERROR] Startup check failed: $($_.Exception.Message)"
        Write-FleetLog "Startup check error: $($_.Exception.Message)" -Level ERROR
    }
}
