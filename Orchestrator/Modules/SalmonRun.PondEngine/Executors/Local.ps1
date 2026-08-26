# Executors/Local.ps1
# Active executor for the opencode-go provider. Loaded by the PondEngine executor registry.

function Initialize-Executor {
    $provider = if ($script:HarnessConfig -and $script:HarnessConfig.Provider) { $script:HarnessConfig.Provider } else { 'opencode-go' }
    $model = if ($script:HarnessConfig -and $script:HarnessConfig.Model) { $script:HarnessConfig.Model } else { 'opencode-go/ox-alpha-free' }
    $effort = if ($script:HarnessConfig -and $script:HarnessConfig.Effort) { $script:HarnessConfig.Effort } else { 'max' }
    if ($provider -ne 'opencode-go') {
        throw "Opencode executor only supports provider 'opencode-go'; got '$provider'"
    }
    $script:OpencodePath = Test-OpenCodeAvailable
    if (-not $script:OpencodePath) {
        throw "Opencode executor: opencode CLI not found. Install it with: npm install -g @opencode-ai/opencode"
    }
    Get-OpenCodeGoApiKey | Out-Null
    Write-OrchestratorLog "OPENCODE_EXECUTOR_READY path='$script:OpencodePath' provider=$provider model=$model effort=$effort"
    return $script:OpencodePath
}

function Test-ExecutorPreflight {
    param([string]$AgentPath)
    if (-not $AgentPath -or $AgentPath -eq "docker") { return $true }
    try {
        $helpText = & $AgentPath run --command work-stream --help 2>&1
    } catch {
        # Detached PowerShell hosts may not expose redirected native stdout.
        # OpenCode then throws before returning its help text; treat that as a
        # non-fatal preflight limitation and let the real stream invocation
        # establish its redirected process handles.
        Write-OrchestratorLog "STREAM_PREFLIGHT_NONFATAL error='$($_.Exception.Message)'" -Level WARN
        return $true
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠ Stream dispatch preflight failed: 'opencode run --command' not supported" -ForegroundColor Red
        Write-OrchestratorLog "STREAM_PREFLIGHT_FAILED opencode='$AgentPath' exit=$LASTEXITCODE output='$($helpText -join '|')'" -Level ERROR
        $interclawDir = $script:RepoRoot
        $diagPath = Join-Path $interclawDir "Tasks/Logs/orch-stream-preflight-failure.log"
        $diagMsg = "opencode run --command test failed`nPath: $AgentPath`nExit code: $LASTEXITCODE`nOutput: $($helpText -join '; ')`nTimestamp: $(Get-Date -Format 'o')"
        $diagMsg | Out-File -FilePath $diagPath -Encoding utf8 -Force
        return $false
    }
    return $true
}

function Invoke-ExecutorTask {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$OpencodePath,
        [int]$InstanceId, [ValidateSet("coder", "reviewer")][string]$Role = "coder", [switch]$UseWorktrees
    )
    $env:OC_STREAM_ID = $StreamId
    $env:OC_RESERVATION_AGENT_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $RepoDir
    $env:OC_CANONICAL_TASK_ROOT = Join-Path $RepoDir 'Tasks\Code'
    $targetDir = $RepoDir
    $useWorktreeDir = $false
    if ($UseWorktrees) {
        $branchName = "wt/$StreamId"
        $wtPath = Join-Path $RepoDir "Tasks/worktrees" $StreamId
        . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) "Git\Invoke-WorktreeSetup.ps1")
        $wtResult = New-AgentWorktree -BranchName $branchName -WorktreePath $wtPath -Resume
        if ($wtResult -and -not $wtResult.Error) {
            $targetDir = $wtResult.WorktreePath
            $useWorktreeDir = $true
            $env:OC_WORKTREE_PATH = $targetDir
            $env:OC_BRANCH_NAME = $branchName
        }
    }
    $streamFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Prepend-StreamLog -StreamDir $StreamDir -Entry "[$(Get-Date -Format 'o')] [orchestrator-$InstanceId] STREAM_START role=$Role files=$([string]::Join(',', $streamFiles))"
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "${StreamId}.stdout"
    $errFile = Join-Path $agentDir "${StreamId}.stderr"
    $command = if ($Role -eq "reviewer") { "work-review" } elseif ($useWorktreeDir) { "stream" } else { "work-stream" }
    $policy = @{
        permission = @{
            "*"        = "ask"
            "read"     = "allow"
            "edit"     = "allow"
            "glob"     = "allow"
            "grep"     = "allow"
            "webfetch" = "allow"
            "websearch" = "allow"
            "task"     = "allow"
            "todowrite" = "allow"
            "skill"    = "allow"
            "lsp"      = "allow"
            "bash"     = @{
                "*"            = "ask"
                "git *"        = "allow"
                "npm *"        = "allow"
                "node *"       = "allow"
                "npx *"        = "allow"
                "tsc *"        = "allow"
                "cd *"         = "allow"
                "ls *"         = "allow"
                "cat *"        = "allow"
                "pwsh *"       = "ask"
                "rm *"         = "deny"
                "del *"        = "deny"
                "rmdir *"      = "deny"
                "mkfs*"        = "deny"
                "fdisk*"       = "deny"
                "format *"     = "deny"
                "reg delete*"  = "deny"
                "net user*"    = "deny"
                "taskkill *"   = "deny"
                "Stop-Process*" = "deny"
            }
        }
    } | ConvertTo-Json -Compress
    $env:OPENCODE_CONFIG_CONTENT = $policy

    $spawn = Invoke-OpenCodeSpawnCommand -OpenCodeScriptPath $OpencodePath -Command $command
    $proc = Start-Process -FilePath $spawn.FilePath -ArgumentList $spawn.ArgumentList `
        -WindowStyle Hidden -PassThru -WorkingDirectory $targetDir `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Register-SpawnedPid -ProcessId $proc.Id -AgentId $StreamId
    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline
    return $proc
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $env:OC_WORKTREE_PATH = $WorktreePath
    $env:OC_BRANCH_NAME = $BranchName
    $env:OC_MERGE_PLAN = $MergePlan
    $env:OC_MERGE_TIMEOUT_SECONDS = "300"
    $mergePolicy = @{
        permission = @{
            "*"        = "allow"
            "bash"     = @{ "*" = "ask"; "git *" = "allow"; "cd *" = "allow"; "ls *" = "allow" }
        }
    } | ConvertTo-Json -Compress
    $env:OPENCODE_CONFIG_CONTENT = $mergePolicy
    $opencodePath = Test-OpenCodeAvailable
    $outFile = Join-Path $RepoDir "Tasks/Logs/agents/merge-$BranchName.stdout"
    $errFile = Join-Path $RepoDir "Tasks/Logs/agents/merge-$BranchName.stderr"
    $null = New-Item -ItemType Directory -Path (Split-Path $outFile -Parent) -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path (Split-Path $errFile -Parent) -Force -ErrorAction SilentlyContinue
    $spawn = Invoke-OpenCodeSpawnCommand -OpenCodeScriptPath $opencodePath -Command "merge"
    $proc = Start-Process -FilePath $spawn.FilePath -ArgumentList $spawn.ArgumentList `
        -WindowStyle Hidden -PassThru -WorkingDirectory $WorktreePath `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Register-SpawnedPid -ProcessId $proc.Id -AgentId "merge-$BranchName"
    return $proc
}

function New-ExecutorTask {
    param([System.Diagnostics.Process]$Handle, [string]$StreamId, [datetime]$StartTime, [string]$Role, [string]$Namespace)
    return [PSCustomObject]@{
        Handle     = $Handle
        Pid        = if ($Handle) { $Handle.Id } else { $null }
        StreamId   = $StreamId
        StartTime  = $StartTime
        Role       = $Role
        Namespace  = $Namespace
        HasExited  = $Handle.HasExited
        ExitCode   = if ($Handle.HasExited) { $Handle.ExitCode } else { $null }
    }
}

function Stop-ExecutorTask {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    try { Stop-ProcessTree -ProcessId $Task.Handle.Id -Force } catch { Write-OrchestratorLog "LOCAL_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN }
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    $Task.HasExited = $Task.Handle.HasExited
    if ($Task.HasExited -and $null -eq $Task.ExitCode) {
        Start-Sleep -Seconds 3
        $Task.ExitCode = $Task.Handle.ExitCode
    }
}

function Start-StreamCoder {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$AgentPath,
        [int]$InstanceId, [ValidateSet("coder", "reviewer")][string]$Role = "coder",
        [switch]$UseWorktrees, [string]$Namespace = "", [string]$BranchName = "", $HarnessConfig, [switch]$PlanProfileOverride
    )
    $OpencodePath = if ($AgentPath) { $AgentPath } else { $script:OpencodePath }
    # Agent-ID validation (orchestrator-tooling-2): a blank or malformed Agent:
    # in a lock header defeats ownership, rescue, and safe-pull targeting.
    # The stream/lane ID becomes OC_RESERVATION_AGENT_ID, so validate it BEFORE
    # spawning — the agent must never bootstrap a lock header with an empty
    # Agent:. Accepted shapes: lane IDs (lane-coder-<n>, lane-reviewer-<n>,
    # module-<n>/lane-<role>-<m>), legacy stream-N, and the standalone
    # <mode>-<random>-<filetime> format.
    if ([string]::IsNullOrWhiteSpace($StreamId)) {
        Write-OrchestratorLog "AGENT_ID_EMPTY stream='$StreamId' role=$Role — aborting spawn before lock header write" -Level ERROR
        throw "AGENT_ID_EMPTY: refusing to spawn stream with an empty agent ID (role=$Role)"
    }
    if ($StreamId -notmatch '^(module-\d+/)?lane-(coder|reviewer)-\d+$' -and $StreamId -notmatch '^stream-\d+$' -and $StreamId -notmatch '^[a-z]+-\d+-\d+$') {
        Write-OrchestratorLog "AGENT_ID_INVALID stream='$StreamId' role=$Role — expected lane-<role>-<n> or <mode>-<random>-<filetime>" -Level ERROR
        throw "AGENT_ID_INVALID: stream agent ID '$StreamId' does not match the expected format"
    }
    # Detect worktree module lanes — they live under Tasks/Worktrees/module-N/
    $wtRoot = Join-Path $RepoDir "Tasks/Worktrees"
    $targetDir = $RepoDir
    if ($StreamDir -match [regex]::Escape($wtRoot)) {
        $targetDir = ($StreamDir -replace '\\Tasks\\Working\\.*', '')
        Write-OrchestratorLog "SPAWN_WORKTREE stream=$StreamId worktree=$targetDir"
    }
    $env:OC_STREAM_ID = $StreamId
    $env:OC_RESERVATION_AGENT_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $targetDir
    $env:OC_CANONICAL_TASK_ROOT = Join-Path $RepoDir 'Tasks\Code'
    if ($UseWorktrees) {
        $env:OC_BRANCH_NAME = if ($BranchName) { $BranchName } else { "wt/$StreamId" }
    } else {
        Remove-Item Env:OC_BRANCH_NAME -ErrorAction SilentlyContinue
    }
    $streamFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Prepend-StreamLog -StreamDir $StreamDir -Entry "[$(Get-Date -Format 'o')] [orchestrator-$InstanceId] STREAM_START role=$Role files=$([string]::Join(',', $streamFiles))"
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    # Ensure subdirectory exists for module agent logs (e.g., module-1/lane-coder-1.pid)
    $agentLogDir = Split-Path (Join-Path $agentDir "$StreamId.pid") -Parent
    if ($agentLogDir -ne $agentDir) { $null = New-Item -ItemType Directory -Path $agentLogDir -Force }
    $outFile = Join-Path $agentDir "${StreamId}.stdout"
    $errFile = Join-Path $agentDir "${StreamId}.stderr"
    $command = if ($Role -eq "reviewer") { "work-review" } else { "work-stream" }

    $startupTimeout = 10
    $activeProfile = if ($HarnessConfig) { $HarnessConfig } else { $script:HarnessConfig }
    $harnessModel = if ($activeProfile -and $activeProfile.Model) { $activeProfile.Model } else { 'opencode-go/ox-alpha-free' }
    $harnessEffort = if ($activeProfile -and $activeProfile.Effort) { $activeProfile.Effort } else { 'max' }
    # A profile explicitly named in a plan is authoritative. Do not substitute
    # a cheaper/fallback model: that would defeat the user's plan-level choice.
    if ($PlanProfileOverride) {
        $fallbacks = @(@{ Model = $harnessModel; Variant = $harnessEffort })
    } else {
        $defaultsPath = Join-Path $script:ModuleRoot 'Config/harness-defaults.json'
        try {
            $configuredFailover = @((Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json).providers.modelFailover)
            $configuredModels = @($configuredFailover | ForEach-Object {
                if ($_.model) { @{ Model = [string]$_.model; Variant = if ($_.variant) { [string]$_.variant } else { $harnessEffort } } }
            })
            # An explicit harness model is the requested primary. Keep the
            # configured failover chain behind it, removing duplicate entries.
            $fallbacks = @(@{ Model = $harnessModel; Variant = $harnessEffort })
            $fallbacks += @($configuredModels | Where-Object { $_.Model -ne $harnessModel })
        } catch {
            Write-OrchestratorLog "MODEL_FAILOVER_CONFIG_READ_FAILED path='$defaultsPath' error='$($_.Exception.Message)'" -Level WARN
            $fallbacks = @()
        }
        if ($fallbacks.Count -eq 0) { $fallbacks = @(@{ Model = $harnessModel; Variant = $harnessEffort }) }
    }

    $policy = @{
        permission = @{
            "*"        = "ask"
            "read"     = "allow"
            "edit"     = "allow"
            "glob"     = "allow"
            "grep"     = "allow"
            "webfetch" = "allow"
            "websearch" = "allow"
            "task"     = "allow"
            "todowrite" = "allow"
            "skill"    = "allow"
            "lsp"      = "allow"
            "bash"     = @{
                "*"            = "ask"
                "git *"        = "allow"
                "npm *"        = "allow"
                "node *"       = "allow"
                "npx *"        = "allow"
                "tsc *"        = "allow"
                "cd *"         = "allow"
                "ls *"         = "allow"
                "cat *"        = "allow"
                "pwsh *"       = "ask"
                "rm *"         = "deny"
                "del *"        = "deny"
                "rmdir *"      = "deny"
                "mkfs*"        = "deny"
                "fdisk*"       = "deny"
                "format *"     = "deny"
                "reg delete*"  = "deny"
                "net user*"    = "deny"
                "taskkill *"   = "deny"
                "Stop-Process*" = "deny"
            }
        }
    }
    $policyJson = if (Test-IsDeepSeekV4Model -Model $harnessModel) {
        Invoke-DeepSeekPolicyFilter -Policy $policy -Model $harnessModel
    } else {
        $policy | ConvertTo-Json -Compress
    }
    $env:OPENCODE_CONFIG_CONTENT = $policyJson

    $lastTask = $null
    for ($i = 0; $i -lt $fallbacks.Count; $i++) {
        $model = $fallbacks[$i].Model
        $variant = $fallbacks[$i].Variant
        $spawn = Invoke-OpenCodeSpawnCommand -OpenCodeScriptPath $OpencodePath -Command $command -Model $model -Variant $variant
        $proc = Start-Process -FilePath $spawn.FilePath -ArgumentList $spawn.ArgumentList `
            -WindowStyle Hidden -PassThru -WorkingDirectory $targetDir `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        Register-SpawnedPid -ProcessId $proc.Id -AgentId $StreamId
        Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
        Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline
        Write-OrchestratorLog "SUBAGENT_SPAWN stream=$StreamId pid=$($proc.Id) role=$Role files=$($streamFiles.Count) command=$command model=$model variant=$variant ns=$Namespace targetDir=$targetDir"

        $exited = $false
        try {
            Wait-Process -InputObject $proc -Timeout $startupTimeout -ErrorAction Stop
            $exited = $true
        } catch [System.TimeoutException] {
            $exited = $false
        } catch {
            $exited = $proc.HasExited
        }

        if (-not $exited) {
            # Process is still alive after the startup window — treat this attempt as the winner.
            return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
        }

        if ($proc.ExitCode -eq 0) {
            # Should not happen for work-stream/review, but if it does, consider it a fast no-op.
            return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
        }

        $tail = ''
        if (Test-Path $errFile) {
            $tailLines = Get-Content $errFile -Tail 5 -ErrorAction SilentlyContinue
            $tail = if ($tailLines) { $tailLines -join "`n" } else { '' }
        }
        $isModelError = $tail -match 'AI_APICallError|No such model|not supported|model.*unavailable|provider.*unavailable'
        Write-OrchestratorLog "STREAM_STARTUP_FAILED stream=$StreamId pid=$($proc.Id) model=$model variant=$variant exit=$($proc.ExitCode) isModelError=$isModelError" -Level WARN

        if ($i -lt $fallbacks.Count - 1 -and $isModelError) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-OrchestratorLog "STREAM_FALLBACK stream=$StreamId nextModel=$($fallbacks[$i+1].Model) nextVariant=$($fallbacks[$i+1].Variant)" -Level INFO
        } else {
            # Last fallback or non-model error — return it and let the orchestrator handle the failure.
            return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
        }
    }

    return $lastTask
}


function Clear-AgentArtifacts {
    param([string]$AgentId, [string]$RepoDir)
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    foreach ($ext in @('.pid', '.heartbeat', '.mode', '.stdout', '.stderr', '.log')) {
        $f = Join-Path $agentDir "$AgentId$ext"
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    $dataDir = Join-Path $agentDir "$AgentId-data"
    if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
    $workingDir = Join-Path $RepoDir "Tasks/Working/$AgentId"
    if (Test-Path $workingDir) {
        $leftover = Get-ChildItem "$workingDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($f in $leftover) { Resolve-OrphanStatus -File $f -Agent $AgentId -RepoDir $RepoDir -RescueKind "AGENT_COMPLETED" }
        Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-OrchestratorLog "AGENT_CLEANUP agent=$AgentId"
}
