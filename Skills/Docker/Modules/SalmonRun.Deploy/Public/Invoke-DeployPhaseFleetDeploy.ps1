<#
.SYNOPSIS
    Executes fleet deployment: waits for parallel image builds, then runs
    Invoke-ORCHESTRATORDeployment with agent configurations.
#>
function Invoke-DeployPhaseFleetDeploy {
    param(
        [object]$BuildContext,
        [string]$RepoRoot,
        [array]$AgentConfigs,
        [string]$ProjectCode,
        [string]$InstallTailscale,
        [string]$InstallFleet,
        [string]$InstallWorkspaceRepos,
        [string]$InstallBrowserless,
        [string]$InstallBookkeeping,
        [string]$InstallHermes,
        [string]$SovereigntyTier
    )

    Test-ModuleState
    if ($BuildContext) {
        Write-Information -MessageData "`n[ImageBuild] Waiting for background builds to complete..." -Tags "INFO"
        $buildResult = Receive-ParallelImageBuild -BuildContext $BuildContext
        if (-not $buildResult.Success) {
            $failed = $buildResult.FailedBuilds -join ", "
            Write-SetupLog "FAIL: Background builds failed: $failed" -Level ERROR
            Write-SetupLog -Message "The following image builds failed: $failed" -Level ERROR
            Write-Information -MessageData "  Check build logs:" -Tags "WARN"
            foreach ($fb in $buildResult.FailedBuilds) {
                $logPath = Join-Path $BuildContext.BuildLogDir "$fb.log"
                if (Test-Path $logPath) { Write-Information -MessageData "    $logPath" -Tags "INFO" }
            }
            throw "Parallel image builds failed: $failed"
        }
        Write-Information -MessageData "  [OK] All images built successfully." -Tags "INFO"
    } else {
        Write-Information -MessageData "  [INFO] No background builds were started - running sequential build." -Tags "INFO"
    }

    try {
        Invoke-InterclawDeployment -TargetDir $RepoRoot -AgentConfigs $AgentConfigs -ProjectCode $ProjectCode `
            -InstallTailscale $InstallTailscale -InstallFleet $InstallFleet `
            -InstallWorkspaceRepos $InstallWorkspaceRepos -InstallBrowserless $InstallBrowserless `
            -InstallBookkeeping $InstallBookkeeping `
            -InstallHermes $InstallHermes `
            -SovereigntyTier $SovereigntyTier `
            -SkipBuilds:($BuildContext -ne $null)
    } catch {
        Add-SetupError -Phase "Deploy" -Message "Fleet deployment failed: $_" -Category "Docker"
        throw
    }
}
