<#
.SYNOPSIS
    Worker process management for LocalOrchestrator.ps1.
#>

<#
.SYNOPSIS
    Captures a snapshot of files in Working/ with their agent IDs.
.DESCRIPTION
    Scans the Working/ directory for .md files and extracts agent IDs
    from Lock Headers via regex. Used by Watch-WorkingDirectory to detect
    file-level changes between poll intervals.
.PARAMETER WorkingDir
    Path to the Tasks/Working directory.
.PARAMETER Role
    Fallback role label if agent ID cannot be parsed.
#>
function Get-WorkingSnapshot {
    param([string]$WorkingDir, [string]$Role)
    $result = @{}
    # Scan per-agent subdirectories instead of flat files (Phase B — partitioned Working/)
    foreach ($agentDir in (Get-ChildItem "$WorkingDir\*" -Directory -ErrorAction SilentlyContinue)) {
        $agentId = $agentDir.Name  # subdirectory name is the agent ID
        foreach ($f in (Get-ChildItem "$($agentDir.FullName)\*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })) {
            $result[$f.Name] = @{ Agent = $agentId }
        }
    }
    return $result
}

<#
.SYNOPSIS
    Checks an agent log for completion markers (TEST_RESULT, COMMIT_CREATED, PUSH_RESULT).
.DESCRIPTION
    Reads the agent's log files and checks for the presence of structured
    completion markers used by the orchestrator's post-exit validation.
.PARAMETER AgentId
    Agent identifier in the format role-NNN-SS.
.PARAMETER OrchestratorDir
    Root of the ORCHESTRATOR repository.
#>
function Test-AgentCompletion {
    param([string]$AgentId, [string]$OrchestratorDir)
    $agentDir = Join-Path $OrchestratorDir "Tasks/Logs/agents"
    $logFile    = Join-Path $agentDir "$AgentId.log"
    $stdoutFile = Join-Path $agentDir "$AgentId.stdout"
    $stderrFile = Join-Path $agentDir "$AgentId.stderr"

    $result = @{ Tests = $false; Commit = $false; Push = $false }
    $sources = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $logFile)    { $sources.Add($logFile) }
    if (Test-Path $stdoutFile) { $sources.Add($stdoutFile) }
    if (Test-Path $stderrFile) { $sources.Add($stderrFile) }

    foreach ($src in $sources) {
        $content = Get-Content $src -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'TEST_RESULT')    { $result.Tests  = $true }
        if ($content -match 'COMMIT_CREATED')  { $result.Commit = $true }
        if ($content -match 'PUSH_RESULT')     { $result.Push   = $true }
    }

    return $result
}

<#
.SYNOPSIS
    Handles an orphaned lock file — releases the lock and moves to Review/.
.DESCRIPTION
    Reads the file's Lock Header. If Status is locked, releases it, sets a
    Released timestamp, then moves to Tasks/Review/. If already released,
    moves directly to Review/. Called by Rescue-OrphanedLocks for each
    stalled file whose agent heartbeat has expired.
.PARAMETER File
    FileInfo object for the orphaned plan file.
.PARAMETER Agent
    Agent ID that held the lock.
.PARAMETER ORCHESTRATORDir
    Root of the ORCHESTRATOR repository.
.PARAMETER RescueKind
    Label for log output (RESCUE or RESCUE_STALE).
#>
function Handle-OrphanStatus {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Handle semantics not expressible with approved verbs')]
    param([System.IO.FileInfo]$File, [string]$Agent, [Alias('ORCHESTRATORDir')][string]$InterclawDir, [string]$RescueKind = "RESCUE")
    $content = Get-Content $File.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return }

    $now = [datetime]::UtcNow.ToString('o')

    # Live-agent guard: never stamp Released: on a file whose worker process is
    # still alive. A live agent with an old file is busy, not orphaned — the
    # hard-timeout rescue and the stale sweep must not release its lock.
    $agentProcessAlive = $false
    if ($Agent) {
        try {
            $aliveInfo = Test-AgentAlive -AgentId $Agent
            if ($aliveInfo) {
                if ($null -ne $aliveInfo.ProcessAlive) { $agentProcessAlive = [bool]$aliveInfo.ProcessAlive }
                elseif ($null -ne $aliveInfo.Alive) { $agentProcessAlive = [bool]$aliveInfo.Alive }
            }
        } catch { }
    }
    if ($agentProcessAlive -and $content -match '(?m)^(-\s*Status:\s*)locked$') {
        Write-OrchestratorLog "LANE_HOLD file='$($File.Name)' reason=locked_live_agent agent=$Agent kind=$RescueKind"
        return
    }

    if ($content -match '(?m)^(-\s*Status:\s*)locked$') {
        $updated = $content -replace '(?m)^(-\s*Status:\s*)locked(\s*)$', "`$1released`$2"
        $updated = $updated -replace '(?m)(^(-\s*Status:\s*)released\s*$)', "`$1`n- Released: $now"
        Set-Content -Path $File.FullName -Value $updated -Encoding utf8 -NoNewline
        $dest = Join-Path "$InterclawDir/Tasks/Review" $File.Name
        Move-Item -LiteralPath $File.FullName -Destination $dest -Force
        Write-Output "[$RescueKind] instance=$InstanceId agent=$Agent file=$($File.Name) action=released"
        Write-OrchestratorLog "$RescueKind agent=$Agent file=$($File.Name) action=released"
        Write-OrchestratorLog "FILE_MOVED file='$($File.Name)' from=$($File.Directory.Name)/ to=Review/ reason=$RescueKind"
        Write-Host "  ↪ Released orphaned lock on $($File.Name) → Review/" -ForegroundColor Yellow
    } elseif ($content -match '(?m)^(-\s*Status:\s*)released$') {
        $dest = Join-Path "$InterclawDir/Tasks/Review" $File.Name
        Move-Item -LiteralPath $File.FullName -Destination $dest -Force
        Write-OrchestratorLog "$RescueKind agent=$Agent file=$($File.Name) action=moved-released"
        Write-OrchestratorLog "FILE_MOVED file='$($File.Name)' from=$($File.Directory.Name)/ to=Review/ reason=$RescueKind"
        Write-Host "  ↪ Moved stalled released file: $($File.Name) → Review/" -ForegroundColor Yellow
    }
    if ($script:usedNamespaces) { $script:usedNamespaces.Remove($File.Name) | Out-Null }
}

<#
.SYNOPSIS
    Rescues orphaned locks in Working/ where agents have stalled or crashed.
.DESCRIPTION
    Scans Working/ for files with Lock Headers. Checks agent aliveness via
    PID file and heartbeat. For stale locks, releases and moves to Review/.
    Skips files locked by agents not spawned by this orchestrator. Also
    cleans up the reservations file.
.PARAMETER ORCHESTRATORDir
    Root of the ORCHESTRATOR repository.
.PARAMETER SpawnedAgentIds
    Array of agent IDs spawned by this orchestrator instance.
#>
function Rescue-OrphanedLocks {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Rescue semantics not expressible with approved verbs')]
    param([string]$InterclawDir, [string[]]$SpawnedAgentIds)
    $orphanedFiles = Get-ChildItem "$InterclawDir/Tasks/Working/*/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    # Hard timeout rescue: files in Working/ longer than 30 min get rescued unconditionally
    $now = Get-Date
    $timeoutThresholdMins = 30
    foreach ($file in $orphanedFiles) {
        $ageMins = ($now - $file.LastWriteTime).TotalMinutes
        if ($ageMins -ge $timeoutThresholdMins) {
            $fileAgent = if ((Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }
            Write-OrchestratorLog "RESCUE_HARD_TIMEOUT agent=$fileAgent file=$($file.Name) age=$([math]::Round($ageMins,1))min threshold=${timeoutThresholdMins}min"
            Handle-OrphanStatus -File $file -Agent $fileAgent -InterclawDir $InterclawDir -RescueKind "RESCUE_HARD_TIMEOUT"
        }
    }

    foreach ($file in $orphanedFiles) {
        $fileAgent = if ((Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue) -match 'Agent: (\w+-\d+-\d+)') { $Matches[1] }
        if (-not $fileAgent) { continue }

        $aliveInfo = $null
        try { $aliveInfo = Test-AgentAlive -AgentId $fileAgent } catch { }

        if ($aliveInfo -and $aliveInfo.Stale) {
            Handle-OrphanStatus -File $file -Agent $fileAgent -InterclawDir $InterclawDir -RescueKind "RESCUE_STALE"
            continue
        }

        # Raw PID fallback — check PID file directly when Test-AgentAlive unavailable
        $pidAlive = $null
        $agentPidFile = Join-Path "$InterclawDir/Tasks/Logs/agents" "$fileAgent.pid"
        if (Test-Path $agentPidFile -ErrorAction SilentlyContinue) {
            $agentPid = Get-Content $agentPidFile -Raw -ErrorAction SilentlyContinue
            if ($agentPid -and (Get-Process -Id ([int]$agentPid) -ErrorAction SilentlyContinue)) {
                $pidAlive = $true
            }
        }
        if ($pidAlive -eq $false) {
            # PID file missing or process dead — treat as orphan
            Write-OrchestratorLog "RESCUE_PID_FALLBACK agent=$fileAgent file=$($file.Name) pidAlive=false"
            Handle-OrphanStatus -File $file -Agent $fileAgent -InterclawDir $InterclawDir -RescueKind "RESCUE_PID"
            continue
        }

        if ($SpawnedAgentIds -and $fileAgent -notin $SpawnedAgentIds) {
            Write-Output "[RESCUE] instance=$InstanceId skipping file=$($file.Name) agent=$fileAgent (not spawned by this orchestrator, PID alive)"
            Write-OrchestratorLog "RESCUE_SKIP agent=$fileAgent file=$($file.Name) pidAlive=$pidAlive"
            continue
        }

        Handle-OrphanStatus -File $file -Agent $fileAgent -InterclawDir $InterclawDir
    }

    $resvPath = Join-Path "$InterclawDir/Tasks" "Logs/.reservations.json"
    if (Test-Path $resvPath) { Remove-Item $resvPath -Force -ErrorAction SilentlyContinue }

    # Clean empty agent subdirectories — removed files leave empty dirs behind
    Get-ChildItem "$InterclawDir/Tasks/Working/*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^(code|coder|reviewer)-\d+-\d+|REVIEWER_' } |
        Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Clean stale file locks from Tasks/Locks/ — remove all lock files (they are transient)
    $lockDir = Join-Path $InterclawDir "Tasks" "Locks"
    if (Test-Path $lockDir) {
        Get-ChildItem "$lockDir\*.lock" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        $staleLockDir = Join-Path $InterclawDir "Tasks" "Locks"
        Get-ChildItem "$staleLockDir\*.lock.lock" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-StreamCoder {
    <#
    .SYNOPSIS
        Launches a stream coder/reviewer subprocess with OC_STREAM_ID set.
    .PARAMETER StreamId
        Stream identifier (e.g. "stream-3").
    .PARAMETER StreamDir
        Full path to the stream directory.
    .PARAMETER InterclawDir
        Root of the ORCHESTRATOR repository.
    .PARAMETER OpencodePath
        Path to the opencode CLI executable.
    .PARAMETER InstanceId
        Orchestrator instance identifier for logging.
    .PARAMETER Role
        Agent role: "coder" or "reviewer". Defaults to "coder".
    #>
    param(
        [string]$StreamId,
        [string]$StreamDir,
        [string]$InterclawDir,
        [string]$OpencodePath,
        [int]$InstanceId,
        [ValidateSet("coder", "reviewer")]
        [string]$Role = "coder",
        [switch]$UseWorktrees
    )
    $env:OC_STREAM_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $InterclawDir

    # Worktree setup: each stream gets an isolated branch + worktree
    $targetDir = $InterclawDir
    $useWorktreeDir = $false
    if ($UseWorktrees) {
        $branchName = "wt/$StreamId"
        $wtPath = Join-Path $InterclawDir "Tasks/worktrees" $StreamId
        . (Join-Path $PSScriptRoot "Invoke-WorktreeSetup.ps1")
        $wtResult = New-AgentWorktree -BranchName $branchName -WorktreePath $wtPath -Resume
        if (-not $wtResult.Error) {
            $targetDir = $wtResult.WorktreePath
            $useWorktreeDir = $true
            $env:OC_WORKTREE_PATH = $targetDir
            $env:OC_BRANCH_NAME = $branchName
        } else {
            Write-Warning "[orchestrator-$InstanceId] Worktree setup failed for '$branchName': $($wtResult.Message) — falling back to main repo"
        }
    }

    $streamFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Prepend-StreamLog -StreamDir $StreamDir -Entry "[$(Get-Date -Format 'o')] [orchestrator-$InstanceId] STREAM_START role=$Role files=$([string]::Join(',', $streamFiles))"

    $agentDir = Join-Path $InterclawDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "$StreamId.stdout"
    $errFile = Join-Path $agentDir "$StreamId.stderr"

    $command = if ($Role -eq "reviewer") { "work-review" } elseif ($useWorktreeDir) { "stream" } else { "work-stream" }

    # Direct launch — PowerShell handles .cmd/.exe resolution natively.
    # No cmd.exe wrapper: exit codes propagate directly, no orphan process layer.
    $proc = Start-Process -FilePath $OpencodePath -ArgumentList "run --command $command" `
        -NoNewWindow -PassThru `
        -WorkingDirectory $targetDir `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline

    return $proc}

function Spawn-MergeAgent {
    <#
    .SYNOPSIS
        Launches a merge agent subprocess to resolve conflicts in a worktree branch.
    .PARAMETER MergePlan
        Full path to the merge-plan .md file describing the conflict.
    .PARAMETER WorktreePath
        Full path to the worktree where the conflicted branch lives.
    .PARAMETER BranchName
        Name of the branch to merge (e.g., wt/stream-3).
    .PARAMETER InterclawDir
        Root of the ORCHESTRATOR repository.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Spawn semantics not expressible with approved verbs')]
    param(
        [string]$MergePlan,
        [string]$WorktreePath,
        [string]$BranchName,
        [string]$InterclawDir
    )
    $env:OC_WORKTREE_PATH = $WorktreePath
    $env:OC_BRANCH_NAME = $BranchName
    $env:OC_MERGE_PLAN = $MergePlan
    $env:OC_MERGE_TIMEOUT_SECONDS = "300"

    $outFile = Join-Path $InterclawDir "Tasks/Logs/agents/merge-$BranchName.stdout"
    $errFile = Join-Path $InterclawDir "Tasks/Logs/agents/merge-$BranchName.stderr"

    $opencodePath = Test-OpenCodeAvailable
    $proc = Start-Process -FilePath $opencodePath -ArgumentList "run --command merge" `
        -NoNewWindow -PassThru `
        -WorkingDirectory $WorktreePath `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    return $proc
}

function Clear-AgentArtifacts {
    param([string]$AgentId, [string]$InterclawDir)
    # Remove PID / heartbeat / mode files
    $agentDir = Join-Path $InterclawDir "Tasks/Logs/agents"
    foreach ($ext in @('.pid', '.heartbeat', '.mode', '.stdout', '.stderr', '.log')) {
        $f = Join-Path $agentDir "$AgentId$ext"
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    # Clean data directory
    $dataDir = Join-Path $agentDir "$AgentId-data"
    if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }

    # Rescue any leftover files in Working/<AgentId>/
    $workingDir = Join-Path $InterclawDir "Tasks/Working/$AgentId"
    if (Test-Path $workingDir) {
        $leftover = Get-ChildItem "$workingDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($f in $leftover) {
            Handle-OrphanStatus -File $f -Agent $AgentId -InterclawDir $InterclawDir -RescueKind "AGENT_COMPLETED"
        }
        Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-OrchestratorLog "AGENT_CLEANUP agent=$AgentId"
}
