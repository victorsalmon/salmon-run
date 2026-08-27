<#
.SYNOPSIS
    Adds external secret declarations to the fleet compose object.
.DESCRIPTION
    Registers agent bundle secrets, proxy bundles, fleet API tokens, and gateway
    password as external Swarm secrets in the compose definition.
#>
function Add-ComposeSecrets {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Compose,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Agents,
        [Parameter(Mandatory = $true)]
        [string]$ProjectCode,
        [Parameter(Mandatory = $true)]
        [hashtable]$BundleManifest,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBundleName,
        [Parameter(Mandatory = $true)]
        [string]$CodingReadBundleName,
        [Parameter(Mandatory = $true)]
        [string]$CodingWriteBundleName,
        [Parameter(Mandatory = $true)]
        [string]$BundleNameFleet,
        [Parameter(Mandatory = $true)]
        [string]$BookkeepingBundleName,
        [string]$MarketerBundleName,
        [string]$HermesBundleName,
        [Parameter(Mandatory = $true)]
        [string]$InstallBookkeeping,
        [string]$InstallMarketer = "false",
        [string]$InstallHermes = "false",
        [Parameter(Mandatory = $true)]
        [bool]$FleetEnabled
    )
    $AgentSuffix = $BundleManifest.Agent.Suffix

    if (-not $BundleManifest) { throw "Add-ComposeSecrets: BundleManifest not provided" }
    for ($i = 0; $i -lt $Agents.Count; $i++) {
        $Agent = $Agents[$i]
        $svcSecretPrefix = Get-AgentSecretPrefix -Project $ProjectCode -Role $Agent.Role -Index $Agent.Index
        $BundleName = "${svcSecretPrefix}_$AgentSuffix"
        $Compose.secrets[$BundleName] = [ordered]@{ external = $true }
    }

    if ($FleetEnabled) {
        $Compose.secrets[$BundleNameFleet] = [ordered]@{ external = $true }
    }

    $Compose.secrets["gateway_password"] = [ordered]@{
        external = $true
        name     = "$ProjectCode-gateway_password"
    }

    $Compose.secrets[$ProxyBundleName] = [ordered]@{ external = $true }
    $Compose.secrets[$CodingReadBundleName] = [ordered]@{ external = $true }
    $Compose.secrets[$CodingWriteBundleName] = [ordered]@{ external = $true }

    if ($InstallBookkeeping -eq "true") {
        $Compose.secrets[$BookkeepingBundleName] = [ordered]@{ external = $true }
    }

    if ($InstallMarketer -eq "true" -and $MarketerBundleName) {
        $Compose.secrets[$MarketerBundleName] = [ordered]@{ external = $true }
    }

    if ($InstallHermes -eq "true" -and $HermesBundleName) {
        $Compose.secrets[$HermesBundleName] = [ordered]@{ external = $true }
    }

    $Compose.secrets["ATTIO_READ_KEY"] = [ordered]@{ external = $true }

    $FleetTokenNames = @(
        "FLEET_API_TOKEN_BROWSERLESS", "FLEET_API_TOKEN_IS_BOOKKEEPING", "FLEET_API_TOKEN_FLEET", "FLEET_API_TOKEN_MONITOR",
        "FLEET_API_TOKEN_MONITORING",
        "FLEET_API_TOKEN_MARKETER", "FLEET_API_TOKEN_HERMES"
        )
    foreach ($ft in $FleetTokenNames) {
        $Compose.secrets[$ft] = [ordered]@{ external = $true }
    }

    return $Compose
}
