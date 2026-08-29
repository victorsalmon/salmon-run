#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the salmon-run workflow as a pipeline of generalizable ponds.
.DESCRIPTION
    Start-PondEngine is the next-generation orchestrator entry point.
    It reads a list of Pond objects, dispatches each through its configured
    task pipeline, and transitions plans between ponds on success or failure.
    Agentic ponds run in background child processes, each in its own git
    worktree branch, so different namespaces do not clobber one another.
.PARAMETER Ponds
    Optional. An array of Pond objects. Defaults to Get-SalmonRunPonds.
.PARAMETER RepoDir
    Optional. Repository root. Defaults to the salmon-run repo root.
.PARAMETER MaxIterations
    Maximum main-loop iterations. Default 20. Use 0 to run until stopped.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes a single agent subprocess may run. Default 30.
.PARAMETER PollIntervalSeconds
    Seconds to sleep when no work is available. Default 300.
.PARAMETER Streams
    Optional. An array of PondStream objects. Defaults to worktree streams
    discovered from the agentic queues.
.PARAMETER NamespaceRepoMap
    Optional hashtable mapping plan namespace to the target repository path
    the agent should work in.
.PARAMETER ConfigPath
    Optional path to an orchestrator config JSON. Defaults to
    ~/.salmon/orchestrator.config.json.
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
        [hashtable]$NamespaceRepoMap = @{},
        [string]$ConfigPath = ''
    )

    $context = [PondContext]::new()
    $context.RepoDir = $RepoDir
    $context.TaskRoot = $TaskRoot
    $context.ActiveStreams = @{}
    $context.UsedNamespaces = @{}
    $context.BusyNamespaces = @{}
    $context.Streams = [System.Collections.ArrayList]::new()
    $context.CrashHistory = [System.Collections.Generic.List[datetime]]::new()
    $context.Iteration = 0
    $context.Counts = $null
    $context.Config = [PSCustomObject]@{
        TimeoutMinutes   = $SubprocessTimeoutMinutes
        NamespaceRepoMap = $NamespaceRepoMap
    }
    $context.Continue = $true
    $context.Success = $false

    $activeLanes = [System.Collections.ArrayList]::new()
    $laneScript = Join-Path $RepoDir 'Tools' 'Start-PondLane.ps1'

    # Validate all string-based task references before a plan can be claimed.
    foreach ($configuredPond in $Ponds) {
        Invoke-PondLanePipeline -Pond $configuredPond -ValidateOnly
    }

    function Add-WorktreeStreams {
        param([PondContext]$Ctx, [string]$Workdir, [string]$Repo, [string]$Cfg)
        $newStreams = @()
        try {
            $newStreams = @(Get-PondWorktreeStreams -TaskRoot $Workdir -RepoDir $Repo -ConfigPath $Cfg)
        } catch {
            Write-Verbose "PondEngine: Get-PondWorktreeStreams failed: $_"
        }
        if ($newStreams.Count -eq 0) { return }
        $existingIds = @{}
        foreach ($s in $Ctx.Streams) { $existingIds[$s.Id] = $true }
        foreach ($s in $newStreams) {
            if ($existingIds.ContainsKey($s.Id)) { continue }
            $null = $Ctx.Streams.Add($s)
            $Ctx.ActiveStreams[$s.Id] = $s
        }
    }

    if ($Streams.Count -gt 0) {
        foreach ($s in $Streams) { $null = $context.Streams.Add($s) }
    } else {
        Add-WorktreeStreams -Ctx $context -Workdir $TaskRoot -Repo $RepoDir -Cfg $ConfigPath

        if ($context.Streams.Count -eq 0) {
            $streamPath = if ([string]::IsNullOrWhiteSpace($RepoDir)) { Get-SalmonRunRepoRoot } else { $RepoDir }
            $null = $context.Streams.Add((New-PondStream -Id 'stream-1' -Branch 'main' -Path $streamPath -TaskRoot $TaskRoot))
        }
    }

    Write-Host "Starting PondEngine for $RepoDir" -ForegroundColor Cyan

    function Get-StreamForGroup {
        param([PondGroup]$Group, [PondContext]$Ctx)
        $byId = $Ctx.Streams | Where-Object { $_.Id -eq $Group.Namespace } | Select-Object -First 1
        if ($byId) { return $byId }
        return $null
    }

    function Invoke-PondReapLane {
        param(
            [Pond]$Pond,
            [PondLane]$Lane,
            [PondStream]$Stream,
            [int]$ExitCode,
            [PondContext]$Ctx,
            [string]$Workdir
        )

        $lanePath = $Lane.Path
        $didReapWork = $false

        if (Test-Path -LiteralPath $lanePath) {
            $files = @(Get-ChildItem -LiteralPath $lanePath -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            $hasComplete = Test-Path -LiteralPath (Join-Path $lanePath '.complete')
            $hasFailed = Test-Path -LiteralPath (Join-Path $lanePath '.failed')

            $reapGroup = [PondGroup]::new()
            $reapGroup.Role = $Pond.Role
            $reapGroup.Files = $files
            $reapGroup.LaneId = $Lane.Id
            $reapGroup.StreamPath = $lanePath
            $reapGroup.Stream = $Stream
            $reapGroup.RepoPath = if ($Stream) { $Stream.Path } else { $Ctx.RepoDir }

            if ($files.Count -gt 0 -and $files[0].Name -match '^\d{4}[-.]?\d{2}[-.]?\d{2}[-.]([^-]+)') {
                $reapGroup.Namespace = $Matches[1]
            } elseif ($files.Count -gt 0) {
                $reapGroup.Namespace = $files[0].BaseName
            } else {
                $reapGroup.Namespace = $Lane.Id
            }

            if ($files.Count -gt 0) {
                if ($hasComplete -or $hasFailed -or $ExitCode -eq 0) {
                    $reapContext = [PondContext]::new()
                    $reapContext.TaskRoot = $Workdir
                    $reapContext.RepoDir = $Ctx.RepoDir
                    $reapContext.Streams = $Ctx.Streams
                    $reapContext.Config = $Ctx.Config
                    $reapContext.ActiveStreams = $Ctx.ActiveStreams
                    $reapContext.UsedNamespaces = @{}
                    $reapContext.BusyNamespaces = @{}
                    $reapContext.CurrentPond = $Pond
                    $reapContext.CurrentGroup = $reapGroup
                    $reapContext.Success = ($hasComplete -or ($ExitCode -eq 0 -and -not $hasFailed))
                    $reapContext.Continue = $true

                    $transitionTask = [PondTask]@{
                        Name     = 'Transition'
                        Type     = 'Group'
                        Function = 'Invoke-PondTaskTransition'
                    }

                    try {
                        $null = Invoke-PondTaskTransition -Pond $Pond -Task $transitionTask -Context $reapContext
                        $didReapWork = $true
                    } catch {
                        Write-Warning "PondEngine: transition during reap for $($Lane.Id) failed: $_"
                    }
                }

                $remaining = @(Get-ChildItem -LiteralPath $lanePath -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -gt 0) {
                    $onFailure = if ($Pond.OnFailure -and $Pond.OnFailure.MoveTo) { $Pond.OnFailure.MoveTo } else { 'Code' }
                    $targetDir = Join-Path $Workdir $onFailure
                    $rescue = Invoke-PondRescue -SourceDir $lanePath -TargetDir $targetDir -StaleThresholdSeconds 0
                    if ($rescue.Rescued -gt 0) {
                        $sourcePaths = @($files | ForEach-Object { $_.FullName })
                        $destFiles = @()
                        foreach ($f in $files) {
                            $dest = Join-Path $targetDir $f.Name
                            if (Test-Path -LiteralPath $dest) { $destFiles += (Get-Item -LiteralPath $dest) }
                        }
                        if ($destFiles.Count -gt 0) {
                            $rescueContext = [PondContext]::new()
                            $rescueContext.TaskRoot = $Workdir
                            $rescueContext.RepoDir = $Ctx.RepoDir
                            $rescueContext.Config = $Ctx.Config
                            $rescueContext.Streams = $Ctx.Streams
                            $rescueContext.CurrentPond = $Pond
                            $rescueContext.CurrentGroup = $reapGroup
                            $commitMsg = "rescue: $($destFiles[0].Name) from $($Pond.Name)"
                            Push-PondRepos -Pond $Pond -Context $rescueContext -FinalDest $onFailure -SourcePaths $sourcePaths -DestFiles $destFiles -CommitMessage $commitMsg -TaskRepoOnly
                        }
                        $didReapWork = $true
                    }
                    Remove-Item -LiteralPath $lanePath -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Remove-Item -LiteralPath $lanePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $Lane.Idle = $true
        return $didReapWork
    }

    $iterationLimit = if ($MaxIterations -le 0) { [int]::MaxValue } else { $MaxIterations }
    for ($context.Iteration = 1; $context.Iteration -le $iterationLimit; $context.Iteration++) {
        $didWork = $false

        # Refresh worktree streams periodically so new namespaces get a lane.
        if ($context.Iteration % 5 -eq 0 -or $context.Streams.Count -eq 0) {
            Add-WorktreeStreams -Ctx $context -Workdir $TaskRoot -Repo $RepoDir -Cfg $ConfigPath
        }

        # Recover orphaned per-role lanes from a previous engine process. Live
        # PIDs are never touched, and each plan returns to its actual source pond.
        $laneRecovery = Invoke-PondLaneRecovery -WorkingDir (Join-Path $TaskRoot 'Working') -TaskRoot $TaskRoot -StaleThresholdSeconds $PollIntervalSeconds
        if ($laneRecovery.Rescued -gt 0) {
            Write-Verbose "PondEngine: recovered $($laneRecovery.Rescued) orphaned lane plan(s)"
            $didWork = $true
        }

        # Rescue legacy root-level in-progress files before scanning ponds.
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

        # Reap completed or failed child lanes.
        for ($i = $activeLanes.Count - 1; $i -ge 0; $i--) {
            $entry = $activeLanes[$i]
            $proc = $entry.Process
            if ($proc -and -not $proc.HasExited) { continue }

            $exitCode = if ($proc) { $proc.ExitCode } else { 1 }
            $reapDidWork = Invoke-PondReapLane -Pond $entry.Pond -Lane $entry.Lane -Stream $entry.Stream -ExitCode $exitCode -Ctx $context -Workdir $TaskRoot
            if ($reapDidWork) { $didWork = $true }

            $null = $context.UsedNamespaces.Remove($entry.Namespace)
            if ($entry.Pond.Role -in @('coder','auditor','qa') -and -not [string]::IsNullOrWhiteSpace($entry.RepoPath)) {
                $null = $context.BusyNamespaces.Remove("repo:$($entry.RepoPath.ToLowerInvariant())")
            }
            $null = $activeLanes.RemoveAt($i)

            Write-Verbose "PondEngine: lane $($entry.Lane.Id) for namespace '$($entry.Namespace)' exited with code $exitCode"
        }

        foreach ($pond in $Ponds) {
            $context.CurrentPond = $pond
            if (-not $pond.Entry.Enabled) { continue }

            $candidates = @(Get-PondCandidates -Pond $pond -Context $context)
            if ($candidates.Count -eq 0) { continue }

            $groups = @(Group-PondFiles -Pond $pond -Files $candidates -Context $context)
            if ($groups.Count -eq 0) { continue }

            foreach ($candidateGroup in $groups) {
                Resolve-PondGroupRepo -Group $candidateGroup -Context $context
            }

            $selected = @(Select-PondGroups -Pond $pond -Groups $groups -Context $context)
            if ($selected.Count -eq 0) { continue }

            $isAgentic = [bool]($pond.Tasks | Where-Object { $_.Name -eq 'Spawn' -and $_.Type -eq 'Agent' })

            foreach ($group in $selected) {
                $context.CurrentGroup = $group
                $context.Continue = $true
                $context.Success = $false
                $usesLocalExecutor = $isAgentic -and (Test-PondGroupUsesLocalExecutor -Group $group)

                Resolve-PondGroupRepo -Group $group -Context $context

                if (-not (Get-PondCapacity -CrashHistory $context.CrashHistory)) {
                    Write-Verbose "PondEngine: throttled by crash capacity"
                    Start-Sleep -Milliseconds (Get-PondCrashThrottleDelay -CrashHistory $context.CrashHistory)
                    continue
                }

                if ($isAgentic -and -not $usesLocalExecutor) {
                    $stream = Get-StreamForGroup -Group $group -Ctx $context
                    if (-not $stream) {
                        Add-WorktreeStreams -Ctx $context -Workdir $TaskRoot -Repo $RepoDir -Cfg $ConfigPath
                        $stream = Get-StreamForGroup -Group $group -Ctx $context
                        if (-not $stream) {
                            Write-Verbose "POND_NO_STREAM pond=$($pond.Name) ns=$($group.Namespace)"
                            continue
                        }
                    }

                    $group.Stream = $stream
                    $group.RepoPath = $stream.Path

                    $lane = Get-FreePondLane -Pond $pond -Context $context -RepoPath $group.RepoPath
                    if (-not $lane) {
                        Write-Verbose "POND_NO_FREE_LANE pond=$($pond.Name) ns=$($group.Namespace)"
                        continue
                    }

                    $worktreeReady = Initialize-PondWorktree -Stream $stream -BaseRepo $stream.BaseRepo
                    if (-not $worktreeReady) {
                        Write-Warning "POND_WORKTREE_NOT_READY pond=$($pond.Name) ns=$($group.Namespace) path=$($stream.Path)"
                        $lane.Idle = $true
                        $null = $context.UsedNamespaces.Remove($group.Namespace)
                        continue
                    }
                    $group.RepoPath = $stream.Path
                    $group.LaneId = $lane.Id
                    $group.StreamPath = $lane.Path

                    $claimTask = $pond.Tasks | Where-Object { $_.Name -eq 'Claim' } | Select-Object -First 1
                    if (-not $claimTask) {
                        $lane.Idle = $true
                        Write-Warning "PondEngine: agentic pond '$($pond.Name)' has no Claim task"
                        continue
                    }

                    try {
                        $context = Invoke-PondTaskClaim -Pond $pond -Task $claimTask -Context $context
                    } catch {
                        Write-Warning "PondEngine: claim failed for $($group.Namespace) in $($pond.Name): $_"
                        $lane.Idle = $true
                        continue
                    }

                    if (-not (Test-Path -LiteralPath $laneScript)) {
                        Write-Warning "PondEngine: lane runner not found at $laneScript"
                        $lane.Idle = $true
                        continue
                    }

                    $startArgs = @{
                        FilePath         = 'pwsh'
                        ArgumentList     = @(
                            '-NoProfile'
                            '-NonInteractive'
                            '-File', $laneScript
                            $TaskRoot
                            $RepoDir
                            $pond.Name
                            $lane.Id
                            $stream.Id
                            $stream.Path
                            $group.Namespace
                            $group.RepoPath
                            $SubprocessTimeoutMinutes
                            $ConfigPath
                        )
                        WorkingDirectory = $group.RepoPath
                        PassThru         = $true
                        NoNewWindow      = $true
                    }

                    $proc = $null
                    try {
                        $proc = Start-Process @startArgs
                    } catch {
                        Write-Warning "PondEngine: failed to spawn lane for $($group.Namespace): $_"
                        $lane.Idle = $true
                        $context.UsedNamespaces.Remove($group.Namespace)
                        continue
                    }

                    $null = $activeLanes.Add([PSCustomObject]@{
                        Process    = $proc
                        Pond       = $pond
                        Lane       = $lane
                        Namespace  = $group.Namespace
                        StartTime  = Get-Date
                        Stream     = $stream
                        StreamPath = $stream.Path
                        RepoPath   = $group.RepoPath
                        Group      = $group
                    })

                    $context.UsedNamespaces[$group.Namespace] = $true
                    if ($pond.Role -in @('coder','auditor','qa') -and -not [string]::IsNullOrWhiteSpace($group.RepoPath)) {
                        $context.BusyNamespaces["repo:$($group.RepoPath.ToLowerInvariant())"] = $true
                    }
                    $didWork = $true
                    Write-Verbose "PondEngine: spawned lane $($lane.Id) for namespace '$($group.Namespace)' on stream '$($stream.Id)' ($($stream.Path))"
                } else {
                    $lane = Get-FreePondLane -Pond $pond -Context $context -RepoPath $group.RepoPath
                    if (-not $lane) {
                        Write-Verbose "POND_NO_FREE_LANE pond=$($pond.Name) ns=$($group.Namespace)"
                        continue
                    }
                    $group.LaneId = $lane.Id
                    $group.StreamPath = $lane.Path
                    $group.Stream = $null
                    foreach ($s in $context.Streams) { if ($s.Id -eq $lane.StreamId) { $group.Stream = $s; break } }

                    try {
                        $context = Invoke-PondLanePipeline -Pond $pond -Context $context
                    } finally {
                        if ($lane) { $lane.Idle = $true }
                        $context.UsedNamespaces.Remove($group.Namespace)
                    }

                    $didWork = $true
                }
            }
        }

        if ($activeLanes.Count -gt 0) {
            Start-Sleep -Seconds 5
            $didWork = $true
        } elseif (-not $didWork) {
            Write-Verbose "PondEngine: no work, sleeping ${PollIntervalSeconds}s"
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    if ($MaxIterations -le 0) {
        Write-Host "PondEngine stopped after $($context.Iteration) unlimited iterations" -ForegroundColor Cyan
    } else {
        Write-Host "PondEngine finished after $($context.Iteration) iterations" -ForegroundColor Cyan
    }
}
