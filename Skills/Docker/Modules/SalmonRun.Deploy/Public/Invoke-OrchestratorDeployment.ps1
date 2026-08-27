<#
.SYNOPSIS
    Orchestrates the full Interclaw deployment lifecycle: pull images, build, seed volumes, deploy stack, and test.
#>
function Invoke-InterclawDeployment {
    [CmdletBinding(DefaultParameterSetName = 'Individual')]
    [OutputType([void])]
    param(
        [string]$TargetDir,
        [hashtable[]]$AgentConfigs,
        [string]$ProjectCode,
        [string]$StackName,
        [Parameter(ParameterSetName = 'OptionsObject')]
        [PSCustomObject]$DeployOptions,
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallTailscale = "true",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallFleet = "true",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallWorkspaceRepos = "",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallBrowserless = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallBookkeeping = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallMarketer = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallHermes = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [ValidateSet("true", "false")]
        [string]$InstallAqe = "true",
        [string]$InstallMonitoring = "false",
        [string]$SovereigntyTier = "global",
        [switch]$SkipBuilds,
        [switch]$PreserveFleet,
        [ValidateSet("All", "BuildPhase1", "BuildPhase2")]
        [string]$BuildPhase = "All",
        [hashtable]$BuildContext
    )
    if ($PSCmdlet.ParameterSetName -eq 'OptionsObject' -and $DeployOptions) {
        $InstallTailscale = if ($DeployOptions.PSObject.Properties.Match('InstallTailscale')) { $DeployOptions.InstallTailscale } else { $InstallTailscale }
        $InstallFleet = if ($DeployOptions.PSObject.Properties.Match('InstallFleet')) { $DeployOptions.InstallFleet } else { $InstallFleet }
        $InstallWorkspaceRepos = if ($DeployOptions.PSObject.Properties.Match('InstallWorkspaceRepos')) { $DeployOptions.InstallWorkspaceRepos } else { $InstallWorkspaceRepos }
        $InstallBrowserless = if ($DeployOptions.PSObject.Properties.Match('InstallBrowserless')) { $DeployOptions.InstallBrowserless } else { $InstallBrowserless }
        $InstallBookkeeping = if ($DeployOptions.PSObject.Properties.Match('InstallBookkeeping')) { $DeployOptions.InstallBookkeeping } else { $InstallBookkeeping }
        $InstallMarketer = if ($DeployOptions.PSObject.Properties.Match('InstallMarketer')) { $DeployOptions.InstallMarketer } else { $InstallMarketer }
        $InstallHermes = if ($DeployOptions.PSObject.Properties.Match('InstallHermes')) { $DeployOptions.InstallHermes } else { $InstallHermes }
        $InstallAqe = if ($DeployOptions.PSObject.Properties.Match('InstallAqe')) { $DeployOptions.InstallAqe } else { $InstallAqe }
        $InstallMonitoring = if ($DeployOptions.PSObject.Properties.Match('InstallMonitoring')) { $DeployOptions.InstallMonitoring } else { $InstallMonitoring }
    }
    $script:StackName = if ($StackName) { $StackName } elseif (Get-Command Get-StackName -ErrorAction SilentlyContinue) { Get-StackName } else { $ProjectCode }
    $script:InstallTailscale = $InstallTailscale
    $script:InstallFleet = $InstallFleet
    $script:InstallWorkspaceRepos = $InstallWorkspaceRepos
    $script:InstallBookkeeping = $InstallBookkeeping
    $script:InstallMarketer = $InstallMarketer
    $script:InstallHermes = $InstallHermes
    $script:InstallMonitoring = $InstallMonitoring
    $script:SovereigntyTier = $SovereigntyTier
    $script:ImageVersion = "local"
    $script:PreserveFleet = $PreserveFleet

    switch ($BuildPhase) {
        "BuildPhase1" {
            return Start-ParallelImageBuild -TargetDir $TargetDir -ImageVersion $script:ImageVersion
        }
        "BuildPhase2" {
            if (-not $BuildContext) {
                throw "BuildPhase2 requires a BuildContext from Start-ParallelImageBuild or BuildPhase1."
            }
            $buildResult = Receive-ParallelImageBuild -BuildContext $BuildContext
            if (-not $buildResult.Success) {
                $failed = $buildResult.FailedBuilds -join ", "
                throw "Image builds failed: $failed"
            }
        }
        "All" {
            if (-not $SkipBuilds) {
                Invoke-ImagePull
                Invoke-FleetImageBuild -TargetDir $TargetDir -ImageVersion $script:ImageVersion
                Invoke-OpencodeImageBuild -TargetDir $TargetDir
                Invoke-FunnelProxyImageBuild -TargetDir $TargetDir
                if ($InstallBookkeeping -eq "true") { Invoke-BookkeepingImageBuild -TargetDir $TargetDir }
                if ($InstallMarketer -eq "true") { Invoke-MarketerImageBuild -TargetDir $TargetDir }
                if ($InstallHermes -eq "true") { Invoke-HermesImageBuild -TargetDir $TargetDir }
                if ($InstallMonitoring -eq "true") { Invoke-MonitoringImageBuild -TargetDir $TargetDir }
            }
        }
    }

    if ($BuildPhase -eq "BuildPhase1") { return }

    Initialize-AgentVolumes -WorkspaceRepos $InstallWorkspaceRepos -StackName $script:StackName -SovereigntyTier $script:SovereigntyTier -AgentConfigs $AgentConfigs -TargetDir $TargetDir

    Initialize-SwarmReadiness
    Publish-FleetStack -TargetDir $TargetDir -AgentConfigs $AgentConfigs -ProjectCode $ProjectCode -StackName $script:StackName -InstallTailscale $script:InstallTailscale -InstallFleet $script:InstallFleet -InstallWorkspaceRepos $script:InstallWorkspaceRepos -InstallBrowserless $InstallBrowserless -InstallBookkeeping $script:InstallBookkeeping -InstallMarketer $script:InstallMarketer -InstallHermes $script:InstallHermes -InstallAqe $InstallAqe -InstallMonitoring $InstallMonitoring -SovereigntyTier $script:SovereigntyTier -ImageVersion $script:ImageVersion -PreserveFleet:$PreserveFleet
    Test-FleetDeployment -StackName $script:StackName -AgentConfigs $AgentConfigs -ProjectCode $ProjectCode -SovereigntyTier $SovereigntyTier -ImageVersion $script:ImageVersion
    # Check for critical services with 0 replicas — warn only, caller retry loop handles remediation
    $__criticalServices = @('mcp_opencode', 'is-fleet')
    $__svcResult = docker stack services $script:StackName --format "{{.Name}}`t{{.Replicas}}" 2>&1
    foreach ($__line in $__svcResult) {
        if ([string]::IsNullOrWhiteSpace($__line)) { continue }
        $__parts = $__line -split "`t"
        $__svcName = $__parts[0] -replace "^${script:StackName}_", ""
        $__replicas = $__parts[1]
        if ($__svcName -in $__criticalServices -and $__replicas -match "^0/") {
            Write-SetupLog "Critical service $__svcName has 0 replicas (caller retry loop will remediate)" -Level WARN
        }
    }
    New-FleetAliases -StackName $script:StackName -AgentConfigs $AgentConfigs -ProjectCode $ProjectCode -SovereigntyTier $SovereigntyTier
}


