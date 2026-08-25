# Queue.ps1 — queue/workload introspection for the orchestrator.
# Error-swallowing convention (2026-08-04 alignment): all -ErrorAction SilentlyContinue
# uses here are probe/read-only operations (Get-ChildItem/Get-Content/Get-Process) where
# absence of a file or process is a valid state; no state-changing call is suppressed.
function Get-AgentFleetStatus {
    param(
        [string]$LogDir = (Join-Path $script:RepoRoot "Tasks/Logs"),
        [string]$ArchiveDir = (Join-Path $script:RepoRoot "Tasks/Complete/PID")
    )
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem "$LogDir\orchestrator-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-structured.log' }) {
        $procPid = 0
        $pidStr = ($f.BaseName -replace 'orchestrator-', '')
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $alive = Get-Process -Id $procPid -ErrorAction SilentlyContinue
        $header = Get-Content $f.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        $instanceId  = ($header | Select-String '# InstanceId:' | ForEach-Object { $_ -replace '# InstanceId: ', '' })
        $startRaw    = ($header | Select-String '# StartTime:' | ForEach-Object { $_ -replace '# StartTime: ', '' })
        $elapsed = if ($alive -and $startRaw) {
            $s = $startRaw -as [datetime]
            if ($s) { [math]::Round(((Get-Date).ToUniversalTime() - $s.ToUniversalTime()).TotalSeconds) } else { $null }
        }
        $modeFile = Join-Path $LogDir "orchestrator-$procPid.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }
        $results.Add([PSCustomObject]@{ AgentId = if ($instanceId) { "orchestrator-$instanceId" } else { "orchestrator-?" }; PID = $procPid; Role = "orchestrator"; Mode = $mode; Status = if ($alive) { "RUNNING" } else { "STALE" }; Elapsed = if ($elapsed) { "$($elapsed)s" } else { "-" }; LogFile = $f.FullName })
    }
    $recentCutoff = (Get-Date).AddDays(-7)
    foreach ($f in Get-ChildItem "$ArchiveDir\orchestrator-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-structured.log' -and $_.LastWriteTime -gt $recentCutoff }) {
        $procPid = 0
        $pidStr = ($f.BaseName -replace 'orchestrator-', '')
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $header = Get-Content $f.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        $instanceId = ($header | Select-String '# InstanceId:' | ForEach-Object { $_ -replace '# InstanceId: ', '' })
        $modeFile = Join-Path $ArchiveDir "orchestrator-$procPid.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }
        $results.Add([PSCustomObject]@{ AgentId = if ($instanceId) { "orchestrator-$instanceId" } else { "orchestrator-?" }; PID = $procPid; Role = "orchestrator"; Mode = $mode; Status = "COMPLETE"; Elapsed = "-"; LogFile = $f.FullName })
    }
    $agentDir = Join-Path $LogDir "agents"
    foreach ($pidFile in Get-ChildItem "$agentDir\*.pid" -ErrorAction SilentlyContinue) {
        $agentId = $pidFile.BaseName
        $rawContent = Get-Content $pidFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $rawContent) { continue }
        $procPid = 0
        $pidStr = $rawContent.Trim()
        if (-not [int]::TryParse($pidStr, [ref]$procPid)) { continue }
        $alive = Get-Process -Id $procPid -ErrorAction SilentlyContinue
        $role = if ($agentId -match '^coder-') { "coder" } elseif ($agentId -match '^reviewer-') { "reviewer" } elseif ($agentId -match '^watchdog-') { "watchdog" } else { "agent" }
        $modeFile = Join-Path $agentDir "$agentId.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }
        $heartbeatFile = Join-Path $agentDir "$agentId.heartbeat"
        $elapsed = if ($alive -and (Test-Path $heartbeatFile)) {
            $hb = (Get-Content $heartbeatFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
            if ($hb) { [math]::Round(((Get-Date).ToUniversalTime() - $hb.ToUniversalTime()).TotalSeconds) } else { $null }
        }
        $logFile = Join-Path $agentDir "$agentId.log"
        $results.Add([PSCustomObject]@{ AgentId=$agentId; PID=$procPid; Role=$role; Mode=$mode; Status=if ($alive){"RUNNING"}else{"STALE"}; Elapsed=if ($elapsed){"$($elapsed)s"}else{"-"}; LogFile=$logFile })
    }
    return $results | Sort-Object Status, Role, AgentId
}

function Write-FleetStatusTable {
    $fleet = Get-AgentFleetStatus
    if (-not $fleet) { return }
    $running = $fleet | Where-Object { $_.Status -eq "RUNNING" }
    if (-not $running) { return }
    Write-Host "  Active Agents:" -ForegroundColor Cyan
    foreach ($a in $running) {
        $roleIcon = switch ($a.Role) { "orchestrator" { "o" } "coder" { "c" } "reviewer" { "r" } default { "-" } }
        Write-Host "  $roleIcon $($a.AgentId) (PID $($a.PID)) - $($a.Role), $($a.Elapsed)" -ForegroundColor DarkGray
    }
}

function Reset-PlanLockHeader {
    <#
    .SYNOPSIS
        Strips the **Lock** header block from a plan file so a re-dispatched
        plan starts with a clean claim state. Prevents the STREAM_STATUS scan
        from seeing stale "Status: released" headers and sweeping freshly
        dispatched files back to Code/ (the released-header redispatch loop).
    #>
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
        # Remove the **Lock** block through the next --- separator (inclusive)
        $reset = $content -replace '(?ms)^\*\*Lock\*\*.*?\n---\s*\n', ''
        # Fallback: if no --- follows, remove just the **Lock** block lines
        if ($reset -eq $content) {
            $reset = $content -replace '(?ms)^\*\*Lock\*\*\n.*?(?=\n[A-Z#]|\n\*\*[A-Z])', ''
        }
        if ($reset -ne $content) {
            $reset | Set-Content $FilePath -Encoding utf8 -NoNewline -ErrorAction Stop
        }
    } catch {
        Write-OrchestratorLog "RESET_LOCK_HEADER_FAILED file='$(Split-Path $FilePath -Leaf)' error='$($_.Exception.Message)'" -Level WARN
    }
}

function Test-PlanHeaderContent {
    <#
    .SYNOPSIS
        Recognizes current, legacy, and metadata-backed plain-title plan forms.
    #>
    param([AllowEmptyString()][string]$Content)
    if (-not $Content) { return $false }
    if ($Content -match '(?m)^\s*#\s+(?:Session\s+Plan|Session|Plan):\s+.+$') { return $true }
    if ($Content -match '(?m)^\s*#\s+Scheduled Task:\s+.+$' -and
        $Content -match '(?m)^\s*\*\*Type\*\*:\s*scheduled-task\b' -and
        $Content -match '(?m)^\s*\*\*Schedule ID\*\*:\s*\S+') { return $true }

    # Older plan-mode output used a plain H1 title, often after an Attempts
    # line. Require plan metadata as well so ordinary Markdown headings are
    # not mistaken for queue work.
    $plainTitle = $Content -match '(?m)^\s*#\s+[^#\r\n].+$'
    if (-not $plainTitle) { return $false }
    $metadataSignals = @(
        ($Content -match '(?m)^\s*\*\*Repo:?\*\*:?\s*.+$'),
        ($Content -match '(?m)^\s*\*\*Date:?\*\*:?\s*.+$'),
        ($Content -match '(?m)^\s*\*\*Origin:?\*\*:?\s*Plan-mode session\b'),
        ($Content -match '(?m)^\s*##\s+(?:Context|Overview|Task(?:s)?)\b')
    ) | Where-Object { $_ }
    return $metadataSignals.Count -ge 2
}

function ConvertTo-CanonicalPlanHeader {
    param([AllowEmptyString()][string]$Content)
    if (-not $Content) { return $Content }
    # Normalize Windows line endings so .NET ^/$ anchors match whole lines cleanly.
    $normalized = $Content -replace "`r`n", "`n"
    $normalized = $normalized -replace '(?m)^\s*#\s+(?:Session\s+Plan|Session|Plan):\s+(.+)$', '# Session Plan: $1'
    if ($normalized -match '(?m)^\s*#\s+Session\s+Plan:\s+.+$') { return $normalized }
    $isScheduledTask = (Test-PlanHeaderContent -Content $normalized) -and
        ($normalized -match '(?m)^\s*#\s+Scheduled Task:\s+.+$')
    if ($isScheduledTask) {
        # A failed scheduler write can displace `ready` from Status onto the
        # Attempts line. Repair only this strongly identified scheduled-task
        # shape; never infer readiness from arbitrary Markdown.
        if ($normalized -match '(?m)^\s*\*\*Status\*\*:\s*$' -and
            $normalized -match '(?m)^\s*\*\*Attempts\*\*:\s*\d+\s+ready\s*$') {
            $normalized = $normalized -replace '(?m)^\s*(\*\*Status\*\*):\s*$', '**Status**: ready'
            $normalized = $normalized -replace '(?m)^\s*(\*\*Attempts\*\*:\s*\d+)\s+ready\s*$', '${1}'
        }
        return $normalized
    }
    $title = [regex]::Match($normalized, '(?m)^\s*#\s+([^#\r\n].+?)\s*$')
    if ($title.Success -and (Test-PlanHeaderContent -Content $normalized)) {
        $canonical = '# Session Plan: ' + $title.Groups[1].Value.Trim()
        return $normalized.Substring(0, $title.Index) + $canonical + $normalized.Substring($title.Index + $title.Length)
    }
    return $normalized
}

function Get-TaskCounts {
    $RepoDir = $script:RepoRoot
    $rootCoderFiles = @(Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $rootCoder = $rootCoderFiles.Count
    $reviewFiles = @(Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $review = $reviewFiles.Count
    $handoff = @(Get-ChildItem "$RepoDir/Tasks/Handoff/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $failed = @(Get-ChildItem "$RepoDir/Tasks/Failed/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $todo = @(Get-ChildItem "$RepoDir/Tasks/ToDo/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $manual = @(Get-ChildItem "$RepoDir/Tasks/Manual/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $paused = @(Get-ChildItem "$RepoDir/Tasks/Paused/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $completeFiles = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $completeDirs = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Directory -ErrorAction SilentlyContinue).Count
    $working = @(Get-ChildItem "$RepoDir/Tasks/Working" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $lockedCoder = 0; $lockedReviewer = 0
    $coderAgents = @{}; $reviewerAgents = @{}
    $streamDirs = @(Get-ChildItem "$RepoDir/Tasks/Working/stream-*" -Directory -ErrorAction SilentlyContinue)
    $activeStreams = $streamDirs.Count
    $blockRe = '(?m)^\*\*Status\*\*:\s*blocked\b'
    $blocked = @($rootCoderFiles | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match $blockRe }).Count +
               @($reviewFiles | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match $blockRe }).Count
    foreach ($f in $working) {
        $agentId = $f.Directory.Name
        if ($agentId -match 'coder-(\d+-\d+)') { $lockedCoder++; $coderAgents[$Matches[1]] = $true }
        if ($agentId -match 'reviewer-(\d+-\d+)') { $lockedReviewer++; $reviewerAgents[$Matches[1]] = $true }
    }
    return [PSCustomObject]@{
        RootCoder = $rootCoder; Review = $review; Handoff = $handoff; Working = $working.Count; Failed = $failed
        ToDo = $todo; Manual = $manual; Paused = $paused; CompleteFiles = $completeFiles; CompleteDirs = $completeDirs
        LockedCoder = $lockedCoder; LockedReviewer = $lockedReviewer
        Blocked = $blocked
        CoderWorkload = $rootCoder + $lockedCoder + $failed; ReviewerWorkload = $review + $lockedReviewer
        CoderAgents = $coderAgents; ReviewerAgents = $reviewerAgents; ActiveStreams = $activeStreams
    }
}

function Rescue-FailedQueue {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Rescue semantics not expressible with approved verbs')]
    param([string]$RepoDir)
    $failedDir = Join-Path $RepoDir "Tasks/Failed"
    $codeDir = Join-Path $RepoDir "Tasks/Code"
    $reviewDir = Join-Path $RepoDir "Tasks/Review"
    $rescued = 0
    if (-not (Test-Path $failedDir)) { return $rescued }
    Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return }
        # If the plan title/body was stripped by a concurrent sweep, try to
        # restore it from git before deciding to skip. This prevents header-stripped
        # released plans from being stuck in Failed/ forever (tempo-quarantine-loop).
        if (-not (Test-PlanHeaderContent -Content $content)) {
            # The header may have been stripped by a concurrent sweep. Search git
            # history across ALL paths the file has ever lived at (Code/, Review/,
            # Working/lane-coder-*/, Failed/) to find the original header-full
            # version. The file may have been committed at a different path before
            # being moved to Failed/.
            $fileName = $_.Name
            $searchPaths = @(
                "Tasks/Failed/$fileName",
                "Tasks/Code/$fileName",
                "Tasks/Review/$fileName"
            )
            # Also search Working/lane-coder-*/ and Working/lane-reviewer-*/
            $workingDir = Join-Path $RepoDir "Tasks/Working"
            if (Test-Path $workingDir) {
                Get-ChildItem $workingDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $searchPaths += "Tasks/Working/$($_.Name)/$fileName"
                }
            }
            $restored = $null
            foreach ($searchPath in $searchPaths) {
                if ($restored) { break }
                $candidates = git -C $RepoDir log --all --format='%H' -- "$searchPath" 2>$null
                foreach ($candidate in $candidates) {
                    if (-not $candidate) { continue }
                    $candidateContent = git -C $RepoDir show "${candidate}:$searchPath" 2>$null
                    if ($candidateContent -and (Test-PlanHeaderContent -Content $candidateContent)) {
                        $restored = $candidateContent
                        Write-OrchestratorLog "FAILED_QUEUE_RESCUE_RESTORED file=$fileName source_path=$searchPath commit=$($candidate.Substring(0,8))" -Level INFO
                        break
                    }
                }
            }
            if ($restored -and (Test-PlanHeaderContent -Content $restored)) {
                $content = $restored
                Set-Content -Path $_.FullName -Value $content -Encoding utf8 -NoNewline
            } else {
                # Cannot restore header — move to Archive/Unrecoverable/ so the file
                # is preserved for inspection but not retried every iteration. Without
                # this, permanently unrecoverable files stay in Failed/ and produce
                # FAILED_QUEUE_RESCUE_SKIP warnings every ~3 min forever (wasted
                # git log/show calls).
                $archiveDir = Join-Path $RepoDir "Tasks/Archive/Unrecoverable"
                $null = New-Item -ItemType Directory -Path $archiveDir -Force
                $archivePath = Join-Path $archiveDir $_.Name
                if (Test-Path $archivePath) {
                    # Already archived (e.g. a prior rescue moved it) — remove the
                    # duplicate from Failed/ to stop the retry loop.
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -LiteralPath $_.FullName -Destination $archivePath -Force
                }
                Write-OrchestratorLog "FAILED_QUEUE_ARCHIVE file=$($_.Name) reason=header-not-found-in-git-history dest=Tasks/Archive/Unrecoverable/" -Level INFO
                return
            }
        }
        # Normalize legacy titles before the file returns to an active queue so
        # downstream lock/finale guards all see the canonical marker.
        $content = ConvertTo-CanonicalPlanHeader -Content $content
        Set-Content -Path $_.FullName -Value $content -Encoding utf8 -NoNewline

        $destDir = $null
        if ($content -match '(?m)^\*\*Status\*\*:\s*ready\b') {
            $destDir = $codeDir
        } elseif ($content -match '(?m)^\*\*Status\*\*:\s*released\b' -or $content -match '(?m)^-\s*Status:\s*released\b' -or $content -match '(?m)^Status:\s*released\b') {
            $destDir = $reviewDir
        }
        if (-not $destDir) { return }
        $destPath = Join-Path $destDir $_.Name
        if (Test-Path $destPath) { return }
        # Reset Repair passes
        if ($content -match '(?m)^\*\*Repair passes\*\*:\s*\d+') {
            $content = $content -replace '(?m)^(\*\*Repair passes\*\*:\s*)\d+', '${1}0'
        }
        # Remove Lock fence
        if ($content -match '(?m)^```$') {
            $content = $content -replace '(?ms)^```.*?^```\s*\r?\n?', ''
        }
        Set-Content -Path $_.FullName -Value $content -Encoding utf8 -NoNewline
        Move-Item -LiteralPath $_.FullName -Destination $destPath -Force
        $null = Reset-FileRetry -FileName $_.Name
        $rescued++
        Write-OrchestratorLog "FAILED_QUEUE_RESCUE file=$($_.Name) dest=$(Split-Path $destDir -Leaf)"
        Write-Host "  ↪ Rescued from Failed/: $($_.Name) → $(Split-Path $destDir -Leaf)/" -ForegroundColor Yellow
    }
    if ($rescued -gt 0) {
        Write-Host "  Auto-rescued $rescued file(s) from Failed/ queue" -ForegroundColor Yellow
    }
    return $rescued
}

function Sync-WorktreeCodePlansToRoot {
    <#
    .SYNOPSIS
        Promotes valid legacy worktree plans into the canonical root Code queue.

    Worktrees are separate execution checkouts. Their Tasks/Code directories
    are not authoritative, but older agents could still create plans there
    because the plan rule was relative to the worktree project root. Copying a
    valid ready plan (rather than moving it) preserves the branch evidence and
    makes the root queue authoritative without mutating another worktree's
    git checkout.
    #>
    param([string]$RepoDir)
    if (-not $RepoDir) { return 0 }
    $rootCode = Join-Path $RepoDir "Tasks/Code"
    $worktreesRoot = Join-Path $RepoDir "Tasks/Worktrees"
    $todoDir = Join-Path $RepoDir "Tasks/ToDo"
    if (-not (Test-Path -LiteralPath $worktreesRoot)) { return 0 }
    $null = New-Item -ItemType Directory -Path $rootCode -Force -ErrorAction SilentlyContinue
    $promoted = 0
    $candidates = @(Get-ChildItem -Path $worktreesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -Path (Join-Path $_.FullName "Tasks/Code") -File -Filter '*.md' -ErrorAction SilentlyContinue
    })
    foreach ($candidate in $candidates) {
        $content = Get-Content -LiteralPath $candidate.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content -or -not (Test-PlanHeaderContent -Content $content)) { continue }
        if ($content -notmatch '(?m)^\*\*Status\*\*:\s*ready\b') { continue }
        $destination = Join-Path $rootCode $candidate.Name
        if (Test-Path -LiteralPath $destination) {
            $existing = Get-Content -LiteralPath $destination -Raw -ErrorAction SilentlyContinue
            if (-not (Test-PlanHeaderContent -Content $existing)) {
                Write-OrchestratorLog "WORKTREE_PLAN_PROMOTION_CONFLICT file='$($candidate.Name)' source='$($candidate.FullName)' destination='$destination'" -Level WARN
            }
            continue
        }
        try {
            Copy-Item -LiteralPath $candidate.FullName -Destination $destination -Force -ErrorAction Stop
            $promoted++
            Write-OrchestratorLog "WORKTREE_PLAN_RECONCILED file='$($candidate.Name)' source='$($candidate.FullName)' destination='$destination'" -Level WARN
            $placeholder = Join-Path $todoDir $candidate.Name
            if (Test-Path -LiteralPath $placeholder) {
                $placeholderContent = Get-Content -LiteralPath $placeholder -Raw -ErrorAction SilentlyContinue
                if ($placeholderContent -match '(?m)^# Missing dependency placeholder:') {
                    Remove-Item -LiteralPath $placeholder -Force -ErrorAction Stop
                    Write-OrchestratorLog "TODO_PLACEHOLDER_REMOVED file='$($candidate.Name)' reason=worktree-plan-reconciled" -Level INFO
                }
            }
        } catch {
            Write-OrchestratorLog "WORKTREE_PLAN_RECONCILE_FAILED file='$($candidate.Name)' source='$($candidate.FullName)' error='$($_.Exception.Message)'" -Level ERROR
        }
    }
    return $promoted
}

function Update-DependencyGapReport {
    param([string]$RepoDir)
    if (-not $RepoDir) { return }
    $reconciled = Sync-WorktreeCodePlansToRoot -RepoDir $RepoDir
    if ($reconciled -gt 0) {
        Write-OrchestratorLog "WORKTREE_PLAN_RECONCILE_SUMMARY promoted=$reconciled" -Level WARN
    }
    $queues = @('Code','Review','Working','Complete','ToDo','Manual','Paused','Failed')
    $known = [System.Collections.Generic.HashSet[string]]::new()
    $knownStems = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($q in $queues) {
        Get-ChildItem (Join-Path $RepoDir "Tasks/$q") -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
            $null = $known.Add($_.Name)
            # Also index stem prefixes (e.g. "complspec-0" from "2026-08-09-complspec-0-compliance-audit-master-methodology.md")
            # so short-form DependsOn references resolve without creating false placeholder files.
            if ($_.BaseName -match '^(\d{4}\.\d{2}\.\d{2}-)?([A-Za-z0-9._\-]+?)-\d') {
                $null = $knownStems.Add($Matches[2])
            }
            # Index the full basename too (e.g. "2026.08.08-currentsbk-1-10-5-recon-gate")
            $null = $knownStems.Add($_.BaseName)
        }
    }
    $gaps = [System.Collections.Generic.List[hashtable]]::new()
    $todoDir = Join-Path $RepoDir "Tasks/ToDo"
    $null = New-Item -ItemType Directory -Path $todoDir -Force -ErrorAction SilentlyContinue
    $candidates = @('Code','Review','Manual','Working') | ForEach-Object {
        Get-ChildItem (Join-Path $RepoDir "Tasks/$_") -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue
    } | Where-Object { $_.Name -ne '.gitkeep' }
    foreach ($c in $candidates) {
        $content = Get-Content $c.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $depMatch = [regex]::Match($content, '^\*\*DependsOn\*\*:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $depMatch.Success) { continue }
        # Strip inline "(status: ...)" annotations before splitting, then split on comma/semicolon only.
        # Splitting on spaces too breaks dependencies like "complspec-0 (status: complete), complwire-0"
        # into fragments ("(status:", "complete)", etc.) that become junk placeholder filenames.
        $depRaw = $depMatch.Groups[1].Value
        $depRaw = $depRaw -replace '\(status:\s*[^)]*\)', '' -replace '\*\*\w+\*\*:\s*[^,;]+', ''
        $deps = $depRaw -split '[,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -match '^[A-Za-z0-9._\-\u2010-\u2015]+$' }
        # Filter out non-references: "none", "n/a", "null", empty
        $deps = $deps | Where-Object { $_ -notmatch '^(none|n/a|na|null|-)$' }
        foreach ($d in $deps) {
            # Check both the exact name and the stem index (short-form references)
            $depFileName = if ($d -notmatch '\.md$') { "$d.md" } else { $d }
            $isKnown = ($d -in $known) -or ($depFileName -in $known) -or ($d -in $knownStems) -or ($depFileName -in $knownStems)
            if (-not $isKnown) {
                $depFileName = if ($d -notmatch '\.md$') { "$d.md" } else { $d }
                $gaps.Add(@{ file = $c.Name; missingDep = $depFileName; sourceQueue = (Split-Path (Split-Path $c.FullName -Parent) -Leaf); sourcePath = $c.FullName })
                $todoPath = Join-Path $todoDir $depFileName
                if (-not (Test-Path $todoPath)) {
                    $placeholder = @"
# Missing dependency placeholder: $depFileName

**Status**: todo
**Source**: Dependency required by $($c.Name)
**Required by**: $($c.Name)

This plan was auto-created by the orchestrator because another plan depends on it and it does not exist in any task queue.
"@
                    try { Set-Content -Path $todoPath -Value $placeholder -Encoding utf8 -NoNewline -ErrorAction Stop } catch { Write-OrchestratorLog "TODO_PLACEHOLDER_WRITE_FAILED file='$depFileName' error='$($_.Exception.Message)'" -Level WARN }
                    Write-OrchestratorLog "TODO_PLACEHOLDER_CREATED file='$depFileName' requiredBy='$($c.Name)'" -Level INFO
                }
            }
        }
    }
    $gapFile = Join-Path $RepoDir "Tasks/Logs/orchestrator-gaps.json"
    $gaps | ConvertTo-Json -Depth 3 | Set-Content $gapFile -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
    if ($gaps.Count -gt 0) {
        Write-OrchestratorLog "DEPENDENCY_GAPS_REPORT count=$($gaps.Count) file='$gapFile'"
    }
}
