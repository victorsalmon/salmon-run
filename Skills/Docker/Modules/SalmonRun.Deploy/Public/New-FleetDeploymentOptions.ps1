<#
.SYNOPSIS
    Creates a FleetDeploymentOptions parameter object grouping all Install* toggles.
.DESCRIPTION
    Used by Publish-FleetStack and Invoke-InterclawDeployment to reduce parameter count.
    All values default to "false" unless otherwise specified.
.OUTPUTS
    PSCustomObject with Install* properties.
#>
function New-FleetDeploymentOptions {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$InstallTailscale = "true",
        [string]$InstallFleet = "true",
        [string]$InstallGithubToken = "false",
        [string]$InstallWorkspaceRepos = "",
        [string]$InstallBrowserless = "false",
        [string]$InstallBookkeeping = "false",
        [string]$InstallMarketer = "false",
        [string]$InstallHermes = "false"
    )
    return [PSCustomObject]@{
        InstallTailscale     = $InstallTailscale
        InstallFleet        = $InstallFleet
        InstallGithubToken   = $InstallGithubToken
        InstallWorkspaceRepos = $InstallWorkspaceRepos
        InstallBrowserless   = $InstallBrowserless
        InstallBookkeeping    = $InstallBookkeeping
        InstallMarketer      = $InstallMarketer
        InstallHermes        = $InstallHermes
    }
}
