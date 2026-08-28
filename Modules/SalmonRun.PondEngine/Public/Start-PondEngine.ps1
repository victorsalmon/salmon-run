#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the salmon-run workflow as a pipeline of generalizable ponds.
.DESCRIPTION
    Start-PondEngine is the next-generation orchestrator entry point.
    It reads a list of Pond objects, dispatches each through its configured
    task pipeline, and transitions plans between ponds on success or failure.
    This function is the primary orchestrator entry point for salmon-run.
.PARAMETER Ponds
    Optional. An array of Pond objects. Defaults to Get-SalmonRunPonds.
.PARAMETER RepoDir
    Optional. Repository root. Defaults to the salmon-run repo root.
.PARAMETER MaxIterations
    Maximum main-loop iterations. Default 20.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes a single agent subprocess may run. Default 30.
.PARAMETER PollIntervalSeconds
    Seconds to sleep when no work is available. Default 300.
.PARAMETER Streams
    Optional. An array of PondStream objects. Defaults to a single main-branch
    stream with the default operator layout.
#>
function Start-PondEngine {
    [CmdletBinding()]
    param(
        [Pond[]]$Ponds = (Get-SalmonRunPonds),
        [string]$RepoDir = (Get-SalmonRunRepoRoot),
        [string]$TaskRoot = (Get-SalmonTaskRoot),
        [int]$MaxIterations = 20,
        [int]$SubprocessTimeoutMinutes = 30,
        [int]$PollIntervalSeconds = 300,
        [PondStream[]]$Streams = @(),
        [hashtable]$NamespaceRepoMap = @{}
    )

    $context = [PondContext]::new()
    $context.RepoDir = $RepoDir
    $context.TaskRoot = $TaskRoot
    $context.ActiveStreams = @{}
    $context.UsedNamespaces = @{}
    $context.BusyNamespaces = @{}
    $context.Streams = [System.Collections.ArrayList]::new()
    if ($Streams.Count -eq 0) {
        $streamPath = if ([string]::IsNullOrWhiteSpace($RepoDir)) { Get-SalmonRunRepoRoot } else { $RepoDir }
        $null = $context.Streams.Add((New-PondStream -Id 'stream-1' -Branch 'main' -Path $streamPath -TaskRoot $TaskRoot))
    } else {
        foreach ($s in $Streams) { $null = $context.Streams.Add($s) }
    }
    $context.CrashHistory = [System.Collections.Generic.List[datetime]]::new()
    $context.Iteration = 0
    $context.Counts = $null
    $context.Config = [PSCustomObject]@{
        TimeoutMinutes    = $SubprocessTimeoutMinutes
        NamespaceRepoMap  = $NamespaceRepoMap
    }
    $context.Continue = $true
    $context.Success = $false

    Write-Host "Starting PondEngine for $RepoDir" -ForegroundColor Cyan

    for ($context.Iteration = 1; $context.Iteration -le $MaxIterations; $context.Iteration++) {
        $didWork = $false

        # Rescue stale in-progress files before scanning ponds
        $rescue = Invoke-PondRescue -SourceDir (Join-Path $TaskRoot 'Working') -TargetDir (Join-Path $TaskRoot 'Code') -StaleThresholdSeconds $PollIntervalSeconds
        if ($rescue.Rescued -gt 0) {
            Write-Verbose "PondEngine: rescued $($rescue.Rescued) stale working file(s)"
            $didWork = $true
        }

        # Rescue failed plans after a longer cool-down so they can be retried.
        $failedRescueThreshold = [math]::Max($PollIntervalSeconds * 2, 60)
        $failedRescue = Invoke-PondRescue -SourceDir (Join-Path $TaskRoot 'Failed') -TargetDir (Join-Path $TaskRoot 'Code') -StaleThresholdSeconds $failedRescueThreshold
        if ($failedRescue.Rescued -gt 0) {
            Write-Verbose "PondEngine: rescued $($failedRescue.Rescued) failed file(s)"
            $didWork = $true
        }

        foreach ($pond in $Ponds) {
            $context.CurrentPond = $pond
            if (-not $pond.Entry.Enabled) { continue }

            $candidates = @(Get-PondCandidates -Pond $pond -Context $context)
            if ($candidates.Count -eq 0) { continue }

            $groups = @(Group-PondFiles -Pond $pond -Files $candidates -Context $context)
            if ($groups.Count -eq 0) { continue }

            $selected = @(Select-PondGroups -Pond $pond -Groups $groups -Context $context)
            if ($selected.Count -eq 0) { continue }

            foreach ($group in $selected) {
                $context.CurrentGroup = $group
                $context.Continue = $true
                $context.Success = $false

                Resolve-PondGroupRepo -Group $group -Context $context

                if (-not (Get-PondCapacity -CrashHistory $context.CrashHistory)) {
                    Write-Verbose "PondEngine: throttled by crash capacity"
                    Start-Sleep -Milliseconds (Get-PondCrashThrottleDelay -CrashHistory $context.CrashHistory)
                    continue
                }

                $lane = Get-FreePondLane -Pond $pond -Context $context
                if (-not $lane) {
                    Write-Verbose "POND_NO_FREE_LANE pond=$($pond.Name) ns=$($group.Namespace)"
                    continue
                }
                $group.LaneId = $lane.Id
                $group.StreamPath = $lane.Path
                $group.Stream = $null
                foreach ($s in $context.Streams) { if ($s.Id -eq $lane.StreamId) { $group.Stream = $s; break } }

                try {
                    foreach ($task in $pond.Tasks) {
                        if (-not $context.Continue) { break }
                        $taskFunction = Get-Command $task.Function -ErrorAction SilentlyContinue
                        if (-not $taskFunction) {
                            Write-Verbose "POND_TASK_NOT_FOUND pond=$($pond.Name) task=$($task.Name) function=$($task.Function)"
                            $context.Continue = $false
                            break
                        }
                        $context = & $task.Function -Pond $pond -Task $task -Context $context
                    }
                } finally {
                    # Release the lane; the Transition task is responsible for moving files out.
                    # If the pipeline aborted early, free the lane here.
                    if ($lane) {
                        $lane.Idle = $true
                    }
                    $context.UsedNamespaces.Remove($group.Namespace)
                }

                $didWork = $true
            }
        }

        if (-not $didWork) {
            Write-Verbose "PondEngine: no work, sleeping ${PollIntervalSeconds}s"
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    Write-Host "PondEngine finished after $($context.Iteration) iterations" -ForegroundColor Cyan
}
