<#
.SYNOPSIS
    Filesystem state reading and reconciliation for orchestrator recovery.
#>

function Get-StreamModuleId {
    <#
    .SYNOPSIS
        Derive the worktree module id for a stream directory path.
    #>
    param(
        [string]$StreamPath,
        [string]$RepoDir
    )
    $relative = $StreamPath -replace [regex]::Escape($RepoDir), ''
    if ($relative -match '[\\/]Tasks[\\/]Worktrees[\\/]([^\\/]+)') {
        return $Matches[1]
    }
    return 'main'
}

function Invoke-ReadFilesystemState {
    param(
        [string]$RepoDir,
        [hashtable]$ExistingActiveStreams = $null
    )
    $workingDir = Join-Path $RepoDir "Tasks/Working"
    $streamDirs = @()
    $streamDirs += @(Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue)
    $streamDirs += @(Get-ChildItem "$workingDir/lane-*" -Directory -ErrorAction SilentlyContinue)
    $recovered = @{ activeStreams = @{}; busyNamespaces = @{}; orphanStreams = @{} }
    foreach ($sd in $streamDirs) {
        $streamJson = Join-Path $sd.FullName "stream.json"
        if (-not (Test-Path $streamJson)) {
            # Exclude lane.json and stream.log — these are lane metadata, not
            # evidence of an active stream. Only plan files (.md), sentinels
            # (.complete, .pid, .heartbeat), and agent artifacts matter.
            $hasFiles = (Get-ChildItem "$($sd.FullName)/*" -File -Exclude "lane.json","stream.log" -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $hasFiles) {
                Remove-Item -LiteralPath $sd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) removed_empty_zombie_dir"
                continue
            }
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) missing_stream_json" -Level WARN
            continue
        }
        try {
            $meta = Get-Content $streamJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) invalid_stream_json" -Level WARN
            continue
        }
        $hasComplete = Test-Path (Join-Path $sd.FullName ".complete")
        $hasPlanFiles = (Get-ChildItem "$($sd.FullName)/*.md" -ErrorAction SilentlyContinue).Count -gt 0
        $moduleId = if ($meta.Module) { $meta.Module } else { Get-StreamModuleId -StreamPath $sd.FullName -RepoDir $RepoDir }
        $nsKey = "$moduleId|$($meta.Namespace)|$($meta.Role)"
        $isLive = $false
        try {
            $alive = Test-AgentAlive -AgentId $meta.Id
            $isLive = $alive.ProcessAlive -or ($alive.HasHeartbeat -and -not $alive.HeartbeatStale)
        } catch { $isLive = $false }
        if ($hasComplete -or -not $hasPlanFiles) {
            if ($isLive) {
                Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) module=$moduleId ns=$nsKey skip_live_agent complete=$hasComplete planFiles=$hasPlanFiles"
            } else {
                Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) module=$moduleId ns=$nsKey completed_or_empty complete=$hasComplete planFiles=$hasPlanFiles"
            }
            continue
        }
        if ($ExistingActiveStreams -and $ExistingActiveStreams.ContainsKey($nsKey)) {
            Write-OrchestratorLog "FILESYSTEM_STATE stream_dir=$($sd.Name) module=$moduleId ns=$nsKey already_tracked_in_memory"
            continue
        }
        $recovered.activeStreams[$nsKey] = @{
            Id        = $meta.Id
            Path      = $sd.FullName
            Namespace = $meta.Namespace
            Role      = $meta.Role
            Module    = $moduleId
            Created   = $meta.Created
            Status    = "recovered"
            StartTime = Get-Date
        }
    }
    if ($recovered.activeStreams.Count -gt 0) {
        Write-OrchestratorLog "FILESYSTEM_STATE recovered=$($recovered.activeStreams.Count) streams"
    }
    return $recovered
}

function Clear-UsedNamepacesForFiles {
    param(
        [string]$RepoDir,
        [hashtable]$UsedNamespaces,
        [string]$NamespaceFilter = $null
    )
    if (-not $UsedNamespaces) { return }
    $removed = 0
    $dirs = @((Join-Path $RepoDir "Tasks/Review"), (Join-Path $RepoDir "Tasks/Code"))
    foreach ($dir in $dirs) {
        $files = Get-ChildItem "$dir/*.md" -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Name -eq '.gitkeep') { continue }
            if ($NamespaceFilter -and (Get-FileNamespace -FileName $f.Name) -ne $NamespaceFilter) { continue }
            if ($UsedNamespaces.ContainsKey($f.Name)) {
                $UsedNamespaces.Remove($f.Name)
                $removed++
                Write-OrchestratorLog "USEDNS_CLEARED file='$($f.Name)' dir='$(Split-Path $dir -Leaf)' ns='$NamespaceFilter'" -Level INFO
            }
        }
    }
    if ($removed -gt 0) {
        Write-OrchestratorLog "USEDNS_CLEARED_TOTAL count=$removed ns='$NamespaceFilter'"
    }
}

function Invoke-ReconcileState {
    param(
        [string]$RepoDir,
        [hashtable]$ActiveStreams,
        [hashtable]$BusyNamespaces,
        [hashtable]$UsedNamespaces
    )
    $discrepancies = [System.Collections.Generic.List[string]]::new()
    $workingDir = Join-Path $RepoDir "Tasks/Working"
    $streamDirs = @()
    $streamDirs += @(Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue)
    $streamDirs += @(Get-ChildItem "$workingDir/lane-*" -Directory -ErrorAction SilentlyContinue)
    $fsStreams = @{}
    foreach ($sd in $streamDirs) {
        $streamJson = Join-Path $sd.FullName "stream.json"
        if (Test-Path $streamJson) {
            try {
                $meta = Get-Content $streamJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $moduleId = if ($meta.Module) { $meta.Module } else { Get-StreamModuleId -StreamPath $sd.FullName -RepoDir $RepoDir }
                $nsKey = "$moduleId|$($meta.Namespace)|$($meta.Role)"
                $fsStreams[$nsKey] = @{ Path = $sd.FullName; Namespace = $meta.Namespace; Role = $meta.Role; Module = $moduleId; Id = $meta.Id; Created = $meta.Created }
            } catch { Write-OrchestratorLog "STREAM_JSON_PARSE_FAILED dir='$($sd.Name)' error='$($_.Exception.Message)'" -Level WARN }
        }
    }
    foreach ($ns in $ActiveStreams.Keys) {
        if (-not $fsStreams.ContainsKey($ns)) {
            $stream = $ActiveStreams[$ns]
            $streamDir = $stream.Path
            if (Test-Path $streamDir) {
                $moduleId = if ($stream.Module) { $stream.Module } else { Get-StreamModuleId -StreamPath $streamDir -RepoDir $RepoDir }
                Write-AtomicJson -Path (Join-Path $streamDir "stream.json") -InputObject @{
                    Id        = $stream.Id
                    Namespace = $stream.Namespace
                    Role      = $stream.Role
                    Module    = $moduleId
                    Created   = if ($stream.Created) { $stream.Created } else { (Get-Date -Format 'o') }
                }
                $discrepancies.Add("stream '$ns' tracked in memory — stream.json re-created")
                Write-OrchestratorLog "STATE_REPAIR action=recreated_stream_json ns='$ns' module=$moduleId dir='$streamDir'" -Level INFO
            } else {
                $discrepancies.Add("stream '$ns' tracked in memory but directory missing on disk")
            }
        }
    }
    foreach ($ns in $fsStreams.Keys) {
        if (-not $ActiveStreams.ContainsKey($ns)) {
            $fsStream = $fsStreams[$ns]
            $streamDirPath = $fsStream.Path
            $hasComplete = Test-Path (Join-Path $streamDirPath ".complete")
            $hasPlanFiles = (Get-ChildItem "$streamDirPath/*.md" -ErrorAction SilentlyContinue).Count -gt 0
            $isLive = $false
            try {
                $alive = Test-AgentAlive -AgentId $fsStream.Id
                $isLive = $alive.ProcessAlive -or ($alive.HasHeartbeat -and -not $alive.HeartbeatStale)
            } catch { $isLive = $false }
            if ($isLive) {
                $ActiveStreams[$ns] = @{
                    Id        = $fsStream.Id
                    Path      = $streamDirPath
                    Namespace = $fsStream.Namespace
                    Role      = $fsStream.Role
                    Module    = $fsStream.Module
                    Created   = $fsStream.Created
                    Status    = "recovered"
                    StartTime = Get-Date
                }
                $discrepancies.Add("stream '$ns' has live agent on disk — added to activeStreams")
                Write-OrchestratorLog "STATE_REPAIR action=added_to_memory ns='$ns' module=$($fsStream.Module) dir='$streamDirPath' reason=live_agent" -Level INFO
            } elseif ($hasComplete -or -not $hasPlanFiles) {
                # Completed or empty stream with stream.json on disk and no live agent — clean it up
                # instead of adding it as a zombie to activeStreams.
                Remove-Item -LiteralPath (Join-Path $streamDirPath "stream.json") -Force -ErrorAction SilentlyContinue
                if (-not (Get-ChildItem $streamDirPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })) {
                    Remove-Item -LiteralPath $streamDirPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                $discrepancies.Add("stream '$ns' completed/empty on disk — cleaned up (not added to activeStreams)")
                Write-OrchestratorLog "STATE_REPAIR action=cleaned_completed_stream ns='$ns' module=$($fsStream.Module) dir='$streamDirPath' complete=$hasComplete planFiles=$hasPlanFiles" -Level INFO
            } else {
                $ActiveStreams[$ns] = @{
                    Id        = $fsStream.Id
                    Path      = $streamDirPath
                    Namespace = $fsStream.Namespace
                    Role      = $fsStream.Role
                    Module    = $fsStream.Module
                    Created   = $fsStream.Created
                    Status    = "recovered"
                    StartTime = Get-Date
                }
                $discrepancies.Add("stream '$ns' has stream.json on disk — added to activeStreams")
                Write-OrchestratorLog "STATE_REPAIR action=added_to_memory ns='$ns' module=$($fsStream.Module) dir='$streamDirPath'" -Level INFO
            }
        }
    }
    $reviewFiles = Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue
    foreach ($rf in $reviewFiles) {
        if ($UsedNamespaces -and $UsedNamespaces.ContainsKey($rf.Name)) {
            $discrepancies.Add("file '$($rf.Name)' in Review/ still in usedNamespaces")
            $UsedNamespaces.Remove($rf.Name)
            Write-OrchestratorLog "STATE_REPAIR removed='$($rf.Name)' from usedNamespaces" -Level INFO
        }
    }
    $codeFiles = Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue
    foreach ($cf in $codeFiles) {
        if ($UsedNamespaces -and $UsedNamespaces.ContainsKey($cf.Name)) {
            $discrepancies.Add("file '$($cf.Name)' in Code/ still in usedNamespaces")
            $UsedNamespaces.Remove($cf.Name)
            Write-OrchestratorLog "STATE_REPAIR removed='$($cf.Name)' from usedNamespaces" -Level INFO
        }
    }
    if ($discrepancies.Count -gt 0) {
        foreach ($d in $discrepancies) {
            Write-OrchestratorLog "STATE_DISCREPANCY detail='$d'" -Level WARN
        }
    }
    return $discrepancies
}
