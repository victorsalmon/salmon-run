<#
.SYNOPSIS
    Verifies Docker Swarm is active; initializes a single-node Swarm if inactive.
.DESCRIPTION
    Checks `docker info` for Swarm status. If the node is not in an active Swarm,
    runs `docker swarm init` with 127.0.0.1 as the advertise address.
.PARAMETER
    This function takes no parameters.
#>
function Initialize-SwarmReadiness {
    [OutputType([void])]
    param()
    Write-SetupLog "Phase 3: Verifying Swarm readiness"
Write-Information -MessageData "`n[SwarmReadiness] Verifying Swarm Readiness..." -Tags "WARN"
$savedPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
$SwarmStatus = docker info --format '{{.Swarm.LocalNodeState}}' 2>$null
$PSNativeCommandUseErrorActionPreference = $savedPreference

if ($SwarmStatus -ne "active") {
    Write-Information -MessageData "  [!] Node is not in a Swarm. Initializing single-node Swarm..." -Tags "WARN"
    $savedPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $initOutput = docker swarm init --advertise-addr 127.0.0.1 2>&1
    $initExitCode = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $savedPreference
    if ($initExitCode -ne 0) {
        $errMsg = "Docker Swarm initialization failed (exit code $initExitCode). Overlay networks require an active Swarm."
        Write-SetupLog $errMsg -Level ERROR
        throw $errMsg
    }
    Write-Information -MessageData "  [OK] Swarm initialized." -Tags "INFO"
}
else {
    Write-Information -MessageData "  [OK] Swarm is active." -Tags "INFO"
}

Write-SetupLog "Phase 3 complete: Swarm is active"
}

