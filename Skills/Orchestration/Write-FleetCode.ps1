<#
.DEPRECATED
    Write-FleetCode is deprecated — use Write-TempoSchedule instead.
#>
Write-Warning "Write-FleetCode is deprecated — use Write-TempoSchedule"
& (Join-Path $PSScriptRoot "Write-TempoSchedule.ps1") @PSBoundParameters
