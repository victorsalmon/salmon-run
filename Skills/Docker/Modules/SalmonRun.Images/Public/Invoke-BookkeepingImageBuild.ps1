<#
.SYNOPSIS
    Retired stub for the Bookkeeper Docker image.

.DESCRIPTION
    The is-bookkeeping container was retired and its shared source was moved to
    Skills/Bookkeeping/.  This function no longer builds an image and simply logs
    that the container is retired so legacy callers do not fail.
#>
function Invoke-BookkeepingImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    $InformationPreference = "Continue"
    Write-Information -MessageData "`n[BookkeepingImageBuild] is-bookkeeping container retired; no image built." -Tags "WARN"
    Write-SetupLog "is-bookkeeping container retired; skipping image build."
}
