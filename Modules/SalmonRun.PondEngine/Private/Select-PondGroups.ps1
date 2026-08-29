<#
.SYNOPSIS
    Selects which pond groups can be dispatched given current stream capacity.
.DESCRIPTION
    Counts free lanes for the pond's role across all streams, applies the
    pond's MinGuarantee, and returns up to ParallelCount groups.
#>
function Select-PondGroups {
    [CmdletBinding()]
    [OutputType([PondGroup[]])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondGroup[]]$Groups,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $freeLanes = 0
    foreach ($stream in $Context.Streams) {
        foreach ($lane in $stream.Lanes.Values) {
            if ($lane.Role -eq $Pond.Role -and $lane.Idle) { $freeLanes++ }
        }
    }

    # Free lanes account for physical capacity. ParallelCount is the global pond
    # policy across all streams; without this bound, adding streams silently
    # multiplies configured concurrency.
    $maxNew = if ($Pond.Operators.MaxNewPerIteration -gt 0) { $Pond.Operators.MaxNewPerIteration } else { $freeLanes }
    $limit = [math]::Min($freeLanes, $maxNew)
    if ($Pond.Operators.ParallelCount -gt 0) {
        $limit = [math]::Min($limit, $Pond.Operators.ParallelCount)
    }
    $limit = [math]::Min($limit, $Groups.Count)

    if ($limit -le 0) { return @() }

    # Prefer groups whose namespace is not already in use. Writer roles get one
    # active group per underlying repository; commit mutexes remain the final
    # safety net, but contention is prevented before expensive agent work starts.
    $available = @($Groups | Where-Object { -not $Context.UsedNamespaces.ContainsKey($_.Namespace) })
    if ($available.Count -eq 0) { return @() }
    $writerRole = $Pond.Role -in @('coder','auditor','qa','investigator')
    # Use a non-generic ArrayList so cross-test module reloads that leave a
    # stale PondGroup type in the session do not cause 'Cannot find an overload
    # for Add' on a generic List<PondGroup>.
    $selected = [System.Collections.ArrayList]::new()
    $selectedRepos = @{}
    $busyRepos = @{}
    if ($Context.BusyNamespaces) {
        foreach ($rawKey in $Context.BusyNamespaces.Keys) {
            $path = if ($rawKey -like 'repo:*') { $rawKey.Substring(5) } else { $rawKey }
            $busyRepos[(Get-PondRepositoryKey -RepoPath $path)] = $true
        }
    }
    foreach ($group in $available) {
        if ($selected.Count -ge $limit) { break }
        if ($writerRole -and -not [string]::IsNullOrWhiteSpace($group.RepoPath)) {
            $repoKey = Get-PondRepositoryKey -RepoPath $group.RepoPath
            if ($selectedRepos.ContainsKey($repoKey) -or $busyRepos.ContainsKey($repoKey)) { continue }
            $selectedRepos[$repoKey] = $true
        }
        $null = $selected.Add($group)
    }
    return $selected.ToArray()
}
