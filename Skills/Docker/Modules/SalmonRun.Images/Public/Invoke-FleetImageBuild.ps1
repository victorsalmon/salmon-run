<#
.SYNOPSIS
    Builds the fleet Docker image if stale or missing.
.DESCRIPTION
    Checks existing fleet:local image version label against source
    version. Rebuilds if the label is missing or does not match.
.PARAMETER
    This function takes no parameters. Uses $TargetDir from caller scope.
.OUTPUTS
    None.
#>
function Invoke-FleetImageBuild {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetDir,
        [string]$ImageVersion = "local"
    )
    $InformationPreference = "Continue"
    # --- Fleet Image ---
Write-Information -MessageData "`n[FleetImageBuild] Checking fleet image..." -Tags "WARN"

$FleetDockerfilePath = Join-Path $TargetDir "Infrastructure" "fleet.Dockerfile"
$FleetExistingResult = Invoke-NativeCommand { docker image inspect fleet:local --format '{{.Id}}' 2>$null }
$FleetExistingId = if ($FleetExistingResult.Success) { $FleetExistingResult.Output } else { $null }
$FleetExistingVersionLabel = $null
if ($FleetExistingId) {
    $FleetVersionResult = Invoke-NativeCommand { docker image inspect fleet:local --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>$null }
    $FleetExistingVersionLabel = if ($FleetVersionResult.Success) { $FleetVersionResult.Output } else { $null }
}

$FleetSourceHash = Get-ImageSourceHash -DockerfilePath $FleetDockerfilePath -TargetDir $TargetDir -ImageName "fleet"

# Check for force-rebuild flag before source-hash comparison
if ($env:ORCHESTRATOR_FORCE_REBUILD -eq "true") {
    Write-Information -MessageData "  [FORCE] ORCHESTRATOR_FORCE_REBUILD set — rebuilding fleet image." -Tags "WARN"
    $Rebuild = "fleet"
}

$FleetExistingHash = $null
if ($FleetExistingId -and $Rebuild -ne "fleet") {
    $FleetHashResult = Invoke-NativeCommand { docker image inspect fleet:local --format '{{index .Config.Labels "org.SalmonRun.fleet.source-hash"}}' 2>$null }
    $FleetExistingHash = if ($FleetHashResult.Success) { $FleetHashResult.Output } else { $null }
}

if ($Rebuild -ne "fleet") { $Rebuild = $false }
if ($FleetExistingId) {
    if ($FleetExistingHash -and $FleetSourceHash -and $FleetExistingHash -eq $FleetSourceHash) {
        Write-Information -MessageData "  [OK] fleet:local image found (source hash matched)." -Tags "INFO"
        Write-Information -MessageData "  [SKIP] Using existing fleet:local image." -Tags "INFO"
        if (-not [string]::IsNullOrWhiteSpace($FleetExistingVersionLabel)) {
            $ImageVersion = $FleetExistingVersionLabel
            Write-Information -MessageData "  [INFO] Using existing fleet image version: $ImageVersion" -Tags "INFO"
        }
    }
    else {
        $Reason = if (-not $FleetExistingHash) { "no source-hash label (pre-auto-rebuild image)" } else { "source files changed" }
        Write-Information -MessageData "  [STALE] fleet:local image is stale ($Reason)." -Tags "WARN"
        Write-SetupLog "Fleet image stale: $Reason (old=$FleetExistingHash new=$FleetSourceHash)"
        $Rebuild = "fleet"
    }
}
else {
    Write-Information -MessageData "  [BUILD] fleet image not found. Building..." -Tags "WARN"
    $Rebuild = "fleet"
}

if ($Rebuild -eq "fleet" -or $Rebuild -eq "true") {
    if (-not (Test-Path $FleetDockerfilePath)) {
        Write-SetupLog "FAIL: Fleet Dockerfile not found" -Level ERROR
        Write-Information -MessageData "  [FAIL] No fleet Dockerfile found at $FleetDockerfilePath." -Tags "ERROR"
        throw "No fleet Dockerfile found at $FleetDockerfilePath."
    }

        try {
            Push-Location $TargetDir
            # Remove old tags before rebuild to avoid dangling <none> images
            $null = Invoke-DockerWithLogging -Command { docker image rm -f fleet:latest 2>&1 } -OperationLabel "Removing old fleet:latest"
            $null = Invoke-DockerWithLogging -Command { docker image rm -f fleet:local 2>&1 } -OperationLabel "Removing old fleet:local"
        $savedPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $buildOutput = docker build --progress=plain -f $FleetDockerfilePath `
            -t "fleet:$ImageVersion" `
            -t "fleet:local" `
            --label "org.opencontainers.image.version=$ImageVersion" `
            --label "org.SalmonRun.fleet.source-hash=$FleetSourceHash" `
            --cache-from "fleet:local" `
            . 2>&1
        $PSNativeCommandUseErrorActionPreference = $savedPreference
        $buildOutput | Write-Information -Tags "INFO"
        if ($LASTEXITCODE -ne 0) {
            throw "Docker build exited with code $LASTEXITCODE"
        }
        Write-Information -MessageData "  [OK] fleet:$ImageVersion built successfully." -Tags "INFO"
        Write-SetupLog "fleet image built: $ImageVersion"
    }
    catch {
        Write-SetupLog "FAIL: fleet Docker build failed: $($_.Exception.Message)" -Level ERROR
        Write-Information -MessageData "  [FAIL] Fleet Docker build failed: see log for details" -Tags "ERROR"
        throw
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }
}
}


