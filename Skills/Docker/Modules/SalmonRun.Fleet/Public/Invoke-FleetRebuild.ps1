<#
.SYNOPSIS
    Two-phase fleet rebuild: PreserveFleet deploy + pending-restart marker.
.DESCRIPTION
    Phase 1: Runs deploy.ps1 with -PreserveFleet and -DroneMode so all
    non-fleet services are updated while the fleet container stays running.
    Phase 2: Writes a pending-restart marker (.fleet-pending-restart.json)
    for the fleet entrypoint loop or a Windows scheduled task to detect
    and trigger the final fleet container restart.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Invoke-FleetRebuild {
    [OutputType([void])]
    param()
    Write-FleetLog "Starting fleet rebuild (two-phase)"
    Write-Verbose "`n[COMMAND] Starting fleet rebuild (two-phase)..."

    $FleetKeyId = Read-FleetSecret -SecretName "fleet_aws_id"
    $FleetSecretKey = Read-FleetSecret -SecretName "fleet_aws_secret"

    if ([string]::IsNullOrWhiteSpace($FleetKeyId) -or [string]::IsNullOrWhiteSpace($FleetSecretKey)) {
        Write-Warning "  [FAIL] Cannot rebuild: fleet AWS credentials not available."
        Write-Warning "  Re-run 0setup.ps1 from the host to provision fleet credentials."
        Write-FleetLog "Rebuild failed: fleet AWS credentials not available" -Level ERROR
        return
    }

    $ProjectCode = $env:INSTALL_PROJECT
    $StackName = $ProjectCode
    $RepoDir = Join-Path (Get-HomeDir) "app"

    if (-not (Test-Path $RepoDir)) {
        Write-Warning "  [FAIL] Cannot rebuild: project directory not found at $RepoDir"
        Write-FleetLog "Rebuild failed: project directory not found" -Level ERROR
        return
    }

    Write-Warning "  [REBUILD] Pulling latest code..."
    Push-Location $RepoDir
    try {
        $GitPull = git pull origin main 2>&1
        Write-Verbose "  [REBUILD] git pull: $GitPull"
        Write-FleetLog "Rebuild: git pull result: $GitPull"
    }
    catch {
        Write-Warning "  [WARN] git pull failed: $($_.Exception.Message). Using current code."
        Write-FleetLog "Rebuild: git pull failed, using current code" -Level WARN
    }

    $SetupScript = Join-Path $RepoDir "Skills" "Docker" "deploy.ps1"
    if (-not (Test-Path $SetupScript)) {
        Write-Warning "  [FAIL] Cannot rebuild: deploy.ps1 not found at $SetupScript"
        Write-FleetLog "Rebuild failed: deploy.ps1 not found" -Level ERROR
        Pop-Location
        return
    }

    Write-Warning "  [REBUILD] Phase 1: PreserveFleet deploy..."
    Write-FleetLog "Rebuild: launching deploy.ps1 -DroneMode -PreserveFleet"

    $env:AWS_ACCESS_KEY_ID = $FleetKeyId
    $env:AWS_SECRET_ACCESS_KEY = $FleetSecretKey
    $env:REBUILD_INTERCLAW = "true"
    $env:INTERCLAW_PRESERVE_FLEET = "true"

    try {
        $SetupResult = Invoke-NativeCommand { & $SetupScript -DroneMode -PreserveFleet }

        if ($SetupResult.Success) {
            Write-Verbose "  [OK] Phase 1 complete (PreserveFleet deploy succeeded)."
            Write-FleetLog "Rebuild Phase 1 succeeded"

            # Write pending-restart marker for Phase 2
            $markerPath = Join-Path $RepoDir ".fleet-pending-restart.json"
            $marker = @{
                timestamp = (Get-Date).ToString("o")
                triggered_by = "Invoke-FleetRebuild"
                message = "Fleet image rebuilt. Execute Phase 2: docker service update --force ${StackName}_is-fleet"
            }
            $marker | ConvertTo-Json | Write-AtomicFile -Path $markerPath -Encoding utf8
            Write-FleetLog "Pending-restart marker written to ${markerPath}"

            (Get-Date -Format 'o') | Write-AtomicFile -Path $StartupCheckMarker -Encoding UTF8
        }
        else {
            Write-Warning "  [FAIL] Fleet rebuild Phase 1 exited with code $($SetupResult.ExitCode)"
            Write-FleetLog "Rebuild Phase 1 failed with exit code $($SetupResult.ExitCode)" -Level ERROR
        }
    }
    catch {
        Write-Warning "  [ERROR] Rebuild failed: $($_.Exception.Message)"
        Write-FleetLog "Rebuild error: $($_.Exception.Message)" -Level ERROR
    }
    finally {
        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\REBUILD_INTERCLAW -ErrorAction SilentlyContinue
        Remove-Item Env:\INTERCLAW_PRESERVE_FLEET -ErrorAction SilentlyContinue
        Pop-Location -ErrorAction SilentlyContinue
    }
}
