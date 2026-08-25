<#
.SYNOPSIS
    Removes a namespace reservation by deleting its reservation file.
.DESCRIPTION
    Removes the reservation file for the specified namespace prefix from Tasks/Locks/.
    Silently continues if the reservation file does not exist.
    Alias: Release-NamespaceReservation
.PARAMETER NamespacePrefix
    The namespace prefix whose reservation to release.
.PARAMETER AgentId
    The agent ID that holds the reservation. Defaults to OC_RESERVATION_AGENT_ID or "unknown".
#>
function Remove-NamespaceReservation {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$NamespacePrefix,

        [string]$AgentId = ($env:OC_RESERVATION_AGENT_ID, "<unknown>" -ne $null -ne "")[0]
    )

    $repoRoot = Get-InterclawRepoRoot
    $reservationPath = Join-Path $repoRoot "Tasks" "Locks" "namespace-$NamespacePrefix.reserved"
    Remove-Item -Path $reservationPath -Force -ErrorAction SilentlyContinue
    Remove-LockHeld -AgentId $AgentId -LockType "namespace" -LockName $NamespacePrefix
}
