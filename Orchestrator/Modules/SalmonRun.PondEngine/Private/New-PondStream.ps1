<#
.SYNOPSIS
    Creates a new PondStream (worktree branch) with the default lane layout.
.DESCRIPTION
    A PondStream is a worktree branch that can run one or more roles in parallel.
    The default Salmon-Run template creates one stream with 3 coders, 1 reviewer,
    1 auditor, and 1 qa lane.
#>
function New-PondStream {
    [CmdletBinding()]
    [OutputType([PondStream])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$Branch,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$TaskRoot = (Get-SalmonTaskRoot),
        [hashtable]$RoleCounts = @{
            'coder'           = 3
            'reviewer'        = 1
            'auditor'         = 1
            'qa'              = 1
            'project-planner' = 2
            'project-reviewer' = 1
            'archiver'        = 1
        }
    )

    $stream = [PondStream]::new()
    $stream.Id = $Id
    $stream.Branch = $Branch
    $stream.Path = $Path
    $stream.Lanes = @{}
    $stream.Idle = $true

    $laneIndex = 1
    foreach ($role in $RoleCounts.Keys) {
        $count = $RoleCounts[$role]
        for ($i = 1; $i -le $count; $i++) {
            $lane = [PondLane]::new()
            $lane.Id = "lane-$role-$laneIndex"
            $lane.Role = $role
            $lane.StreamId = $Id
            $lane.Path = Join-Path $TaskRoot 'Working' $lane.Id
            $lane.Idle = $true
            $stream.Lanes[$lane.Id] = $lane
            $laneIndex++
        }
    }

    return $stream
}
