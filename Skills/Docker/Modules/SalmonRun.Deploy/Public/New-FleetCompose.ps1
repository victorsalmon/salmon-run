<#
.SYNOPSIS
    Generates the fleet Docker Compose YAML configuration for Swarm stack deployment.
.DESCRIPTION
    Produces a docker-compose.interclaw.yml file with is-fleet
    and the configured sidecars. Validates image sources, bundle manifests, and
    compose structure before writing output.
.PARAMETER Agents
    Array of agent configuration hashtables with Role, Index, InstanceId.
.PARAMETER ProjectCode
    Project code used for service naming and secret prefixes.
.PARAMETER BundleManifest
    Secret bundle manifest defining per-service secret naming conventions.
.PARAMETER OutputPath
    Path to write the generated compose YAML file.
.EXAMPLE
    New-FleetCompose -Agents @(@{Role='BASE';Index=0;InstanceId='1'}) -ProjectCode FRAD
    Generates a compose file for a single BASE agent with default sidecars.
#>
function New-FleetCompose {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Agents,
        [Parameter(Mandatory = $true)]
        [string]$ProjectCode,
        [switch]$PreserveFleet,
        [string]$InstallTailscale = "false",
        [string]$InstallFleet = "true",
        [string]$OutputPath,
        [string]$SovereigntyTier = "canada",
        [string]$InstallWorkspaceRepos = "",
        [string]$InstallBrowserless = "false",
        [string]$InstallBookkeeping = "false",
        [string]$InstallAqe = "false",
        [string]$InstallFunnel = "false",
        [string]$InstallMonitoring = "false",
        [string]$InstallMarketer = "false",
        [string]$InstallHermes = "false",
        [hashtable]$BundleManifest,
        [string]$BundleNameFleet,
        [string]$BookkeepingBundleName,
        [string]$BookkeepingBundleSuffix
    )
    # Backward-compatible fallback: read from module if not provided
    if (-not $BundleManifest) { $BundleManifest = Get-BundleManifest }
    if (-not $BundleNameFleet -and $BundleManifest) { $BundleNameFleet = $BundleManifest.Fleet.BundleName }
    if (-not $BookkeepingBundleName -and $BundleManifest -and $BundleManifest.Bookkeeper) { $BookkeepingBundleName = $BundleManifest.Bookkeeper.BundleName }
    if (-not $BookkeepingBundleSuffix -and $BundleManifest -and $BundleManifest.Bookkeeper) { $BookkeepingBundleSuffix = $BundleManifest.Bookkeeper.Suffix }
    $MarketerBundleName = if ($BundleManifest.Marketer) { $BundleManifest.Marketer.BundleName } else { "" }
    $HermesBundleName = if ($BundleManifest.Hermes) { $BundleManifest.Hermes.BundleName } else { "" }
    $AgentSuffix = $BundleManifest.Agent.Suffix
    $ProxyBundleName = $BundleManifest.Proxy.BundleName
    $CodingReadBundleName = $BundleManifest.CodingRead.BundleName
    $CodingWriteBundleName = $BundleManifest.CodingWrite.BundleName

    if (-not $OutputPath) {
        $OutputPath = Join-Path $PWD "Infrastructure/docker-compose.interclaw.yml"
    }

    $HasMultiple = $Agents.Count -gt 1
    $FleetEnabled = ($InstallFleet -eq "true")
    $MonitoringEnabled = ($InstallMonitoring -eq "true")

    if (-not (Get-Command Get-ServicePort -ErrorAction SilentlyContinue)) {
        $null = Import-Module -Name SalmonRun.Ports -Force -DisableNameChecking -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 2>&1
    }
    # Validate image source before generating services
    $__ocConstants = Get-InterclawConstants
    if (-not $__ocConstants -or [string]::IsNullOrWhiteSpace($__ocConstants.InterclawImage)) {
        throw "New-FleetCompose: Get-InterclawConstants returned null or empty InterclawImage - cannot generate agent service definitions"
    }

    # Verify referenced images exist locally before generating compose
    $imagesToCheck = @($__ocConstants.InterclawImage)
    $missingImages = [System.Collections.Generic.List[string]]::new()
    foreach ($img in $imagesToCheck) {
        $inspectResult = Invoke-NativeCommand { docker image inspect $img 2>&1 }
        if (-not $inspectResult.Success) {
            $missingImages.Add($img)
        }
    }
    if ($missingImages.Count -gt 0) {
        Write-Warning "New-FleetCompose: $($missingImages.Count) image(s) not found locally: $($missingImages -join ', '). Auto-pulling..."
        foreach ($img in $missingImages) {
            Write-Information -MessageData "  Pulling $img..." -Tags "INFO"
            $pullResult = Invoke-NativeCommand { docker pull $img 2>&1 }
            if (-not $pullResult.Success) {
                throw "New-FleetCompose: failed to pull required image '$img': $($pullResult.Output)"
            }
            Write-Information -MessageData "  [OK] $img pulled successfully." -Tags "INFO"
        }
    }

    $Compose = [ordered]@{
        version  = "3.8"
        services = [ordered]@{}
        networks = [ordered]@{}
        volumes  = [ordered]@{}
        secrets  = [ordered]@{}
        configs  = [ordered]@{}
    }

    $Compose = Add-AgentServiceToCompose -Compose $Compose -Agents $Agents -ProjectCode $ProjectCode -SovereigntyTier $SovereigntyTier -InstallWorkspaceRepos $InstallWorkspaceRepos -BundleManifest $BundleManifest -AgentSuffix $AgentSuffix -HasMultiple $HasMultiple
    $Compose = Add-FleetServiceToCompose -Compose $Compose -Agents $Agents -ProjectCode $ProjectCode -BundleNameFleet $BundleNameFleet -InstallWorkspaceRepos $InstallWorkspaceRepos -PreserveFleet:$PreserveFleet -FleetEnabled $FleetEnabled
    $sidecarParams = @{
        Compose = $Compose; ProjectCode = $ProjectCode; InstallWorkspaceRepos = $InstallWorkspaceRepos; ProxyBundleName = $ProxyBundleName; CodingReadBundleName = $CodingReadBundleName; CodingWriteBundleName = $CodingWriteBundleName; BookkeepingBundleName = $BookkeepingBundleName; BookkeepingBundleSuffix = $BookkeepingBundleSuffix; InstallTailscale = $InstallTailscale; InstallBrowserless = $InstallBrowserless; InstallBookkeeping = $InstallBookkeeping; InstallAqe = $InstallAqe; InstallFunnel = $InstallFunnel; InstallMarketer = $InstallMarketer; InstallHermes = $InstallHermes; MonitoringEnabled = $MonitoringEnabled
    }
    $Compose = Add-SidecarServicesToCompose @sidecarParams
    $Compose = Add-ComposeNetworksAndVolumes -Compose $Compose -Agents $Agents -InstallFunnel $InstallFunnel -InstallWorkspaceRepos $InstallWorkspaceRepos -HasMultiple $HasMultiple
    $Compose = Add-ComposeSecrets -Compose $Compose -Agents $Agents -ProjectCode $ProjectCode -BundleManifest $BundleManifest -ProxyBundleName $ProxyBundleName -CodingReadBundleName $CodingReadBundleName -CodingWriteBundleName $CodingWriteBundleName -BundleNameFleet $BundleNameFleet -BookkeepingBundleName $BookkeepingBundleName -MarketerBundleName $MarketerBundleName -HermesBundleName $HermesBundleName -InstallBookkeeping $InstallBookkeeping -InstallMarketer $InstallMarketer -InstallHermes $InstallHermes -FleetEnabled $FleetEnabled
    return Compile-FleetComposeOutput -Compose $Compose -Agents $Agents -OutputPath $OutputPath
}
