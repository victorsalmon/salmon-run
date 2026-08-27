<#
.SYNOPSIS
    Validates that the Docker host has sufficient resources for the planned fleet.
.DESCRIPTION
    Calls Measure-DockerResources to profile host memory/disk, computes total
    requested memory based on agent count and sidecar flags, and throws if
    disk is below 10GB or total requested exceeds available memory. Returns the
    resource measurement with a Passed property added.
.PARAMETER AgentCount
    Number of fleet agents to reserve memory for (4GB each).
.PARAMETER InstallFleet
    Whether to include Fleet memory reservation. Default "true".
.PARAMETER InstallTailscale
    Whether to include Tailscale reservation. Default "false".
.PARAMETER InstallBrowserless
    Whether to include Browserless reservation. Default "false".
.PARAMETER IncludeDiskCheck
    If set, runs an Alpine container to measure free disk.
.OUTPUTS
    PSCustomObject from Measure-DockerResources with additional Passed and
    TotalRequestedGB properties.
#>
function Test-ResourceBudget {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [int]$AgentCount,
        [string]$InstallFleet = "true",
        [string]$InstallTailscale = "false",
        [string]$InstallBrowserless = "false",
        [switch]$IncludeDiskCheck
    )
    $DockerResources = Measure-DockerResources -AgentCount $AgentCount -InstallFleet $InstallFleet -InstallTailscale $InstallTailscale -InstallBrowserless $InstallBrowserless -IncludeDiskCheck:$IncludeDiskCheck

    $diskGB = $DockerResources.AvailableDiskGB
    if ($null -eq $diskGB -or $diskGB -lt 10) {
        $display = if ($null -eq $diskGB) { 'unknown' } else { $diskGB }
        throw "Insufficient free disk: ${display}GB (need >= 10GB)"
    }

    $TotalRequested = $AgentCount * 4
    if ($InstallFleet -eq "true") { $TotalRequested += if ($env:FLEET_MEMORY_LIMIT -match '^(\d+)G$') { [int]$Matches[1] } else { 1 } }
    if ($InstallTailscale -eq "true") { $TotalRequested += 1 }
    if ($InstallBrowserless -eq "true") { $TotalRequested += 0.5 }

    if ($TotalRequested -gt $DockerResources.TotalGB) {
        throw "Total memory ${TotalRequested}GB exceeds Docker total $($DockerResources.TotalGB)GB. Reduce agents or disable sidecars."
    }

    $result = $DockerResources
    $result | Add-Member -NotePropertyName Passed -NotePropertyValue $true
    $result | Add-Member -NotePropertyName TotalRequestedGB -NotePropertyValue $TotalRequested
    return $result
}
