<#
.SYNOPSIS
    Dynamic capacity allocation functions for orchestrator dispatch.
#>

function Get-DynamicCapacity {
    <#
    .SYNOPSIS
        Allocates capacity using a shared pool of $CodeParallelCount total streams,
        with a minimum guarantee for each role to prevent starvation.
        Total concurrent streams never exceed $CodeParallelCount.
        New streams per iteration are capped to prevent thrashing.
    .PARAMETER CodeParallelCount
        Max total stream slots (shared between coders and reviewers).
    .PARAMETER ReviewerParallelCount
        Max reviewer-specific slots (secondary cap).
    .PARAMETER CoderWorkload
        Number of pending coder tasks.
    .PARAMETER ReviewerWorkload
        Number of pending reviewer tasks.
    .PARAMETER ActiveCoder
        Number of currently active coder streams.
    .PARAMETER ActiveReviewer
        Number of currently active reviewer streams.
    .PARAMETER MaxNewStreamsPerIteration
        Max new streams to create per iteration (prevents thrashing). Default 10.
    #>
    param(
        [int]$CodeParallelCount,
        [int]$ReviewerParallelCount,
        [int]$CoderWorkload,
        [int]$ReviewerWorkload,
        [int]$ActiveCoder = 0,
        [int]$ActiveReviewer = 0,
        [int]$MaxNewStreamsPerIteration = 10
    )

    $minCoderGuarantee = 1
    $minReviewerGuarantee = 1
    $totalActive = $ActiveCoder + $ActiveReviewer
    $availableSlots = [math]::Max(0, $CodeParallelCount - $totalActive)

    if ($CoderWorkload -le 0 -and $ReviewerWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = 0; CapacityReviewer = 0 }
    }

    if ($CoderWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = 0; CapacityReviewer = [math]::Min($availableSlots, $ReviewerParallelCount - $ActiveReviewer) }
    }

    if ($ReviewerWorkload -le 0) {
        return [PSCustomObject]@{ CapacityCoder = $availableSlots; CapacityReviewer = 0 }
    }

    # Both roles have work: fulfill minimum guarantees first
    $needCoder = [math]::Max(0, $minCoderGuarantee - $ActiveCoder)
    $needReviewer = [math]::Max(0, $minReviewerGuarantee - $ActiveReviewer)

    $coderCapacity = [math]::Min($needCoder, $availableSlots)
    $remaining = $availableSlots - $coderCapacity
    $reviewerCapacity = [math]::Min($needReviewer, $remaining)
    $remaining -= $reviewerCapacity

    # Split remaining slots proportionally by workload
    if ($remaining -gt 0) {
        $totalWork = $CoderWorkload + $ReviewerWorkload
        $extraCoder = [math]::Round($remaining * $CoderWorkload / $totalWork)
        $extraCoder = [math]::Max(0, [math]::Min($extraCoder, $remaining))
        $coderCapacity += $extraCoder
        $reviewerCapacity += ($remaining - $extraCoder)
    }

    $reviewerCapacity = [math]::Min($reviewerCapacity, $ReviewerParallelCount - $ActiveReviewer)

    if ($availableSlots -eq 0 -and $totalActive -gt 0) {
        $zombieStreams = 0
        if ($script:activeStreams) {
            foreach ($__ns in $script:activeStreams.Keys) {
                $__s = $script:activeStreams[$__ns]
                if ($__s.Process -and $__s.Process.HasExited) { $zombieStreams++ }
                elseif (-not $__s.Process) { $zombieStreams++ }
            }
        }
        if ($zombieStreams -gt 0) {
            Write-OrchestratorLog "DYNAMIC_CAPACITY_ZOMBIE zombieStreams=$zombieStreams availableSlots=$availableSlots forcing=$zombieStreams"
            # Force all zombie slots free — previously only forced 1, which bottlenecked
            # dispatch when multiple lanes had crashed/completed without cleanup.
            $availableSlots = $zombieStreams
            # Recompute capacity with the forced slot — without this, coderCapacity
            # and reviewerCapacity remain 0 (computed above when availableSlots was 0)
            # and no work is dispatched even though a slot was freed.
            $needCoder = [math]::Max(0, $minCoderGuarantee - $ActiveCoder)
            $needReviewer = [math]::Max(0, $minReviewerGuarantee - $ActiveReviewer)
            $coderCapacity = [math]::Min($needCoder, $availableSlots)
            $remaining = $availableSlots - $coderCapacity
            $reviewerCapacity = [math]::Min($needReviewer, $remaining)
            $remaining -= $reviewerCapacity
            # If min guarantees are met but slots remain, give to whichever role has work
            if ($remaining -gt 0) {
                if ($CoderWorkload -gt 0 -and $ReviewerWorkload -le 0) {
                    $coderCapacity += $remaining
                } elseif ($ReviewerWorkload -gt 0 -and $CoderWorkload -le 0) {
                    $reviewerCapacity += $remaining
                } elseif ($CoderWorkload -gt 0 -and $ReviewerWorkload -gt 0) {
                    # Give to coder by default (coders produce work for reviewers)
                    $coderCapacity += $remaining
                }
            }
        }
    }

    # Cap new streams per iteration to prevent thrashing
    # Only count already-created streams from THIS iteration, not total active
    # (total active is already enforced by availableSlots above)
    $newSlotBudget = $MaxNewStreamsPerIteration
    $coderCapacity = [math]::Min($coderCapacity, $newSlotBudget)
    $remaining = $newSlotBudget - $coderCapacity
    $reviewerCapacity = [math]::Min($reviewerCapacity, $remaining)

    return [PSCustomObject]@{
        CapacityCoder    = [math]::Max(0, $coderCapacity)
        CapacityReviewer = [math]::Max(0, $reviewerCapacity)
    }
}

function Get-ActiveStreamsCount {
    <#
    .SYNOPSIS
        Returns the count of currently active streams.
    .PARAMETER ActiveStreams
        The script:activeStreams hashtable.
    #>
    param([hashtable]$ActiveStreams)
    return @($ActiveStreams.Keys).Count
}

function Get-QueuedNamespacesCount {
    <#
    .SYNOPSIS
        Returns the count of files not yet assigned to any stream.
    .PARAMETER CodeDir
        Path to Tasks/Code/.
    .PARAMETER ReviewDir
        Path to Tasks/Review/.
    .PARAMETER UsedNamespaces
        The script:usedNamespaces hashtable tracking already-assigned files.
    #>
    param([string]$CodeDir, [string]$ReviewDir, [hashtable]$UsedNamespaces)
    $all = @(Get-ChildItem "$CodeDir/*.md" -ErrorAction SilentlyContinue) +
           @(Get-ChildItem "$ReviewDir/*.md" -ErrorAction SilentlyContinue)
    $unused = $all | Where-Object { -not $UsedNamespaces.ContainsKey($_.Name) }
    return $unused.Count
}

function Get-CrashThrottleCapacity {
    param([System.Collections.Generic.List[datetime]]$CrashHistory, [int]$DefaultCapacity)
    if (-not $CrashHistory -or $CrashHistory.Count -eq 0) { return $DefaultCapacity }
    $window = (Get-Date).AddSeconds(-60)
    $recentCrashes = 0
    $CrashHistory.ForEach({ if ($_ -gt $window) { $recentCrashes++ } })
    if ($recentCrashes -ge 5) { return [math]::Max(1, [math]::Floor($DefaultCapacity / 3)) }
    if ($recentCrashes -ge 3) { return [math]::Max(1, [math]::Floor($DefaultCapacity / 2)) }
    if ($recentCrashes -ge 1) { return [math]::Max(1, [math]::Floor($DefaultCapacity * 0.75)) }
    return $DefaultCapacity
}

function Get-CrashBackoffDelay {
    <#
    .SYNOPSIS
        Returns exponential backoff delay in seconds for agent crash restart.
        Uses $script:streamCrashHistory to count recent crashes and compute delay.
    #>
    param(
        [System.Collections.Generic.List[datetime]]$CrashHistory,
        [int]$MaxDelaySeconds = 120,
        [int]$BaseExponent = 2
    )
    if (-not $CrashHistory -or $CrashHistory.Count -eq 0) { return 0 }
    $window = (Get-Date).AddSeconds(-300)
    $recentCrashes = 0
    foreach ($__crash in $CrashHistory) { if ($__crash -gt $window) { $recentCrashes++ } }
    if ($recentCrashes -le 1) { return 0 }
    $delay = [math]::Pow($BaseExponent, $recentCrashes - 1)
    return [math]::Min($delay, $MaxDelaySeconds)
}
