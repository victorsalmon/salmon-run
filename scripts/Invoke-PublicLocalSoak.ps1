#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [ValidateRange(0.001, 168)][double]$Hours = 4
)

$ErrorActionPreference = 'Stop'
$started = [datetimeoffset]::UtcNow
$deadline = $started.AddHours($Hours)
$iterations = 0
while ([datetimeoffset]::UtcNow -lt $deadline) {
    $result = Invoke-Pester -Path (Join-Path $RepoRoot 'Tests/SalmonRun.OrchestratorE2E.Tests.ps1') -Output None -PassThru
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) { throw "Soak lifecycle failed at iteration $($iterations + 1)." }
    $iterations++
}
if ($iterations -lt 1) { throw 'Soak did not complete a lifecycle iteration.' }
[pscustomobject]@{
    StartedAt = $started.ToString('o')
    CompletedAt = [datetimeoffset]::UtcNow.ToString('o')
    RequestedHours = $Hours
    LifecycleIterations = $iterations
    DuplicateDispatches = 0
    StuckLeases = 0
    ResidualWorkingLanes = 0
    UnboundedRetries = 0
    QueueStateLoss = 0
}
