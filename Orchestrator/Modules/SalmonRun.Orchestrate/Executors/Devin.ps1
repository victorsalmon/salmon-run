# Executors/Devin.ps1
# Devin Local harness for salmon-orchestrator. Spawns `devin acp` via the
# dsh-adapter JSON-RPC stdio bridge so the salmon scheduler can run plans
# through the local SWE-1-7 model.

$script:DevinPath = $null
$script:AdapterCli = $null

function Initialize-Executor {
    $provider = if ($script:HarnessConfig -and $script:HarnessConfig.Provider) { $script:HarnessConfig.Provider } else { 'devin' }
    $model = if ($script:HarnessConfig -and $script:HarnessConfig.Model) { $script:HarnessConfig.Model } else { 'swe-1-7' }
    $effort = if ($script:HarnessConfig -and $script:HarnessConfig.Effort) { $script:HarnessConfig.Effort } else { 'medium' }
    if ($provider -ne 'devin') {
        throw "Devin executor only supports provider 'devin'; got '$provider'"
    }
    $devin = (Get-Command devin -ErrorAction SilentlyContinue)
    if (-not $devin) {
        throw "Devin executor: devin CLI not found in PATH"
    }
    $script:DevinPath = $devin.Source
    $script:AdapterCli = if ($env:DEVIN_MCP_DSH_ADAPTER) {
        $env:DEVIN_MCP_DSH_ADAPTER
    } else {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
        Join-Path $repoRoot "Public\devin-mcp\packages\dsh-adapter\dist\cli.js"
    }
    if (-not (Test-Path $script:AdapterCli)) {
        throw "Devin executor: dsh-adapter CLI not found at '$($script:AdapterCli)'"
    }
    if ($env:DEVIN_API_KEY -and -not $env:DSO_ACP_AUTH_API_KEY) {
        $env:DSO_ACP_AUTH_API_KEY = $env:DEVIN_API_KEY
    }
    Write-OrchestratorLog "DEVIN_EXECUTOR_READY path='$script:DevinPath' adapter='$script:AdapterCli' provider=$provider model=$model effort=$effort"
    return $script:DevinPath
}

function Test-ExecutorPreflight {
    param([string]$AgentPath)
    if (-not $AgentPath) { return $true }
    $version = & $AgentPath --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠ Devin preflight failed: 'devin --version' returned exit $LASTEXITCODE" -ForegroundColor Red
        Write-OrchestratorLog "DEVIN_PREFLIGHT_FAILED exit=$LASTEXITCODE output='$($version -join '|')'" -Level ERROR
        return $false
    }
    return $true
}

function Get-DevinEffort {
    $effort = $env:DEVIN_EFFORT
    if (-not $effort -and $script:HarnessConfig -and $script:HarnessConfig.Effort) { $effort = $script:HarnessConfig.Effort }
    if (-not $effort) { $effort = 'medium' }
    if ($effort -notin @('medium','max')) { $effort = 'medium' }
    return $effort
}

function Get-DevinModel {
    $model = $env:DEVIN_MODEL
    if (-not $model -and $script:HarnessConfig -and $script:HarnessConfig.Model) { $model = $script:HarnessConfig.Model }
    if (-not $model) { $model = 'swe-1-7' }
    return $model
}

function Get-DevinPrompt {
    param(
        [string]$Role,
        [string]$Namespace,
        [string]$ProjectRoot,
        [string]$BranchName,
        [string]$WorktreePath
    )
    $templateDir = Join-Path $PSScriptRoot "..\Templates"
    $templateFile = Join-Path $templateDir "devin-$Role-prompt.md"
    if (-not (Test-Path $templateFile)) {
        throw "Devin prompt template not found: $templateFile"
    }
    $template = Get-Content $templateFile -Raw
    $branchBlock = if ($BranchName) { "Branch: $BranchName" } else { '' }
    $worktreeBlock = if ($WorktreePath) { "Worktree: $WorktreePath" } else { '' }
    $canonicalPlanQueue = if ($env:OC_CANONICAL_TASK_ROOT) { $env:OC_CANONICAL_TASK_ROOT } else { Join-Path $ProjectRoot 'Tasks\Code' }
    $rendered = $template `
        -replace '\{\{Namespace\}\}', $Namespace `
        -replace '\{\{ProjectRoot\}\}', $ProjectRoot `
        -replace '\{\{CanonicalPlanQueue\}\}', $canonicalPlanQueue `
        -replace '\{\{BranchBlock\}\}', $branchBlock `
        -replace '\{\{WorktreeBlock\}\}', $worktreeBlock
    $rendered = [regex]::Replace($rendered, '(?m)^[ \t]*$(\r?\n|$)', '')
    return $rendered.TrimEnd()
}

function Build-DevinPrompt {
    param(
        [string]$Role,
        [string]$StreamDir,
        [string]$Namespace,
        [string]$RepoDir
    )
    $planFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.complete' } | Sort-Object Name)
    if (-not $planFiles) { throw "No plan file in stream dir '$StreamDir'" }

    $branchName = $env:OC_BRANCH_NAME
    $worktreePath = $env:OC_WORKTREE_PATH
    $header = Get-DevinPrompt -Role $Role -Namespace $Namespace -ProjectRoot $RepoDir -BranchName $branchName -WorktreePath $worktreePath

    $body = $planFiles | ForEach-Object {
        "## Plan: $($_.Name)`n" + (Get-Content $_.FullName -Raw) + "`n"
    } | Join-String -Separator "`n---`n"

    return "$header`n`n$body"
}

function Build-DevinMergePrompt {
    param(
        [string]$MergePlan,
        [string]$BranchName,
        [string]$WorktreePath,
        [string]$RepoDir
    )
    if (-not (Test-Path $MergePlan)) { throw "Merge plan not found: $MergePlan" }
    $planText = Get-Content $MergePlan -Raw -ErrorAction SilentlyContinue
    $header = @(
        "Start Devin in BYPASS execution mode."
        "Role: merge"
        "Branch: $BranchName"
        "Worktree: $WorktreePath"
        "Project root: $RepoDir"
        "Resolve the merge conflict described in the attached merge feedback."
        "Use git to merge branch '$BranchName' into the base branch in the worktree."
        "Follow the plan's acceptance and verification sections."
        "Use the orchestrator's completion checklist before stopping."
        ""
    ) -join "`n"
    return "$header`n## Merge feedback:`n$planText"
}

function Start-StreamCoder {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$AgentPath,
        [int]$InstanceId, [ValidateSet("coder", "reviewer")][string]$Role = "coder",
        [switch]$UseWorktrees, [string]$Namespace = "", [string]$BranchName = "", $HarnessConfig, [switch]$PlanProfileOverride
    )
    if ([string]::IsNullOrWhiteSpace($StreamId)) {
        throw "AGENT_ID_EMPTY: refusing to spawn stream with an empty agent ID (role=$Role)"
    }
    if ($StreamId -notmatch '^(module-\d+/)?lane-(coder|reviewer)-\d+$' -and $StreamId -notmatch '^stream-\d+$' -and $StreamId -notmatch '^[a-z]+-\d+-\d+$') {
        throw "AGENT_ID_INVALID: stream agent ID '$StreamId' does not match the expected format"
    }

    $targetDir = $RepoDir
    if ($UseWorktrees) {
        $branchName = if ($BranchName) { $BranchName } else { "wt/$StreamId" }
        $wtPath = Join-Path $RepoDir "Tasks/worktrees" $StreamId
        . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) "Git\Invoke-WorktreeSetup.ps1")
        $wtResult = New-AgentWorktree -BranchName $branchName -WorktreePath $wtPath -Resume
        if ($wtResult -and -not $wtResult.Error) {
            $targetDir = $wtResult.WorktreePath
            $env:OC_WORKTREE_PATH = $targetDir
            $env:OC_BRANCH_NAME = $branchName
        }
    }

    $env:OC_STREAM_ID = $StreamId
    $env:OC_RESERVATION_AGENT_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $targetDir
    $env:OC_CANONICAL_TASK_ROOT = Join-Path $RepoDir 'Tasks\Code'

    $model = if ($HarnessConfig -and $HarnessConfig.Model) { $HarnessConfig.Model } else { Get-DevinModel }
    $effort = if ($HarnessConfig -and $HarnessConfig.Effort) { $HarnessConfig.Effort } else { Get-DevinEffort }

    $streamFiles = @(Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Prepend-StreamLog -StreamDir $StreamDir -Entry "[$(Get-Date -Format 'o')] [orchestrator-$InstanceId] STREAM_START role=$Role files=$([string]::Join(',', $streamFiles))"
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $agentLogDir = Split-Path (Join-Path $agentDir "$StreamId.pid") -Parent
    if ($agentLogDir -ne $agentDir) { $null = New-Item -ItemType Directory -Path $agentLogDir -Force }
    $outFile = Join-Path $agentDir "${StreamId}.stdout"
    $errFile = Join-Path $agentDir "${StreamId}.stderr"
    $inFile = Join-Path $agentDir "${StreamId}.stdin"

    $prompt = Build-DevinPrompt -Role $Role -StreamDir $StreamDir -Namespace $Namespace -RepoDir $RepoDir

    $startRecord = @{
        v = 1
        type = 'start'
        runId = "salmon-devin-$StreamId"
        taskId = $StreamId
        lane = $Role
        profile = 'devin'
        model = $model
        effort = $effort
        cwd = $targetDir
        transport = 'acp'
    } | ConvertTo-Json -Compress

    $promptRecord = @{
        v = 1
        type = 'prompt'
        id = 'p-1'
        text = $prompt
    } | ConvertTo-Json -Compress

    $shutdownRecord = @{
        v = 1
        type = 'shutdown'
    } | ConvertTo-Json -Compress

    # dsh-adapter expects newline-delimited JSON records on stdin.
    $inputLines = "$startRecord`n$promptRecord`n$shutdownRecord"
    $inputLines | Out-File -FilePath $inFile -Encoding utf8 -NoNewline

    $env:DSO_DSH_ACP_COMMAND = "devin acp --model $model"

    $node = (Get-Command node -ErrorAction SilentlyContinue)
    if (-not $node) { throw "Node.js is required for the Devin executor" }

    $proc = Start-Process -FilePath $node.Source -ArgumentList $script:AdapterCli `
        -NoNewWindow -PassThru -WorkingDirectory $targetDir `
        -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Register-SpawnedPid -ProcessId $proc.Id -AgentId $StreamId
    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline
    Write-OrchestratorLog "SUBAGENT_SPAWN stream=$StreamId pid=$($proc.Id) role=$Role files=$($streamFiles.Count) model=$model effort=$effort ns=$Namespace targetDir=$targetDir"
    return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace -RepoDir $RepoDir
}

function New-ExecutorTask {
    param([System.Diagnostics.Process]$Handle, [string]$StreamId, [datetime]$StartTime, [string]$Role, [string]$Namespace, [string]$RepoDir = '')
    return [PSCustomObject]@{
        Handle      = $Handle
        Pid         = if ($Handle) { $Handle.Id } else { $null }
        StreamId    = $StreamId
        StartTime   = $StartTime
        Role        = $Role
        Namespace   = $Namespace
        RepoDir = $RepoDir
        HasExited   = $Handle.HasExited
        ExitCode    = if ($Handle.HasExited) { $Handle.ExitCode } else { $null }
    }
}

function Stop-ExecutorTask {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    try { Stop-ProcessTree -ProcessId $Task.Handle.Id -Force } catch { Write-OrchestratorLog "DEVIN_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN }
}

function Get-DevinAcpExitCode {
    param([string]$OutFile, [int]$Default = 0)
    if (-not (Test-Path $OutFile)) { return $Default }
    $lastError = $null
    $lastStop = $null
    foreach ($line in (Get-Content $OutFile -ErrorAction SilentlyContinue)) {
        try {
            $record = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($record.type -eq 'error') { $lastError = $record.message }
            if ($record.type -eq 'result') { $lastStop = $record.stopReason }
        } catch {}
    }
    if ($lastError) { return 1 }
    if ($lastStop -and $lastStop -ne 'end_turn' -and $lastStop -ne 'success') { return 1 }
    return 0
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    $Task.HasExited = $Task.Handle.HasExited
    if ($Task.HasExited -and $null -eq $Task.ExitCode) {
        Start-Sleep -Seconds 3
        $Task.ExitCode = $Task.Handle.ExitCode
    }
    # dsh-adapter exits 0 even when the session reports an error; parse stdout
    # for a result/error record and override the exit code so the orchestrator
    # routes the plan correctly.
    if ($Task.HasExited -and $Task.ExitCode -eq 0) {
        $outFile = $null
        if ($Task.RepoDir) {
            $outFile = Join-Path $Task.RepoDir "Tasks/Logs/agents/$($Task.StreamId).stdout"
        }
        if (-not (Test-Path $outFile)) {
            $repoRoot = $script:RepoRoot
            $outFile = Join-Path $repoRoot "Tasks/Logs/agents/$($Task.StreamId).stdout"
        }
        if (Test-Path $outFile) {
            $Task.ExitCode = Get-DevinAcpExitCode -OutFile $outFile -Default $Task.ExitCode
        }
    }
}

function New-MergeProcessWrapper {
    param([System.Diagnostics.Process]$Process, [string]$OutFile)
    $wrapper = [PSCustomObject]@{
        Process   = $Process
        OutFile   = $OutFile
        HasExited = $false
        ExitCode  = $null
    }
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value {
        param([int]$Timeout = -1)
        try {
            if ($this.Process -and -not $this.Process.HasExited) {
                if ($Timeout -gt 0) { Wait-Process -InputObject $this.Process -Timeout $Timeout -ErrorAction Stop }
                else { $this.Process.WaitForExit() }
            }
        } catch [System.TimeoutException] {
            Write-OrchestratorLog "MERGE_DEVIN_WAIT_TIMEOUT merge=$($this.Process.Id) timeout=$Timeout" -Level WARN
        } catch {}
        $this.HasExited = $this.Process.HasExited
        if ($this.HasExited) {
            Start-Sleep -Seconds 2
            $this.ExitCode = Get-DevinAcpExitCode -OutFile $this.OutFile -Default $this.Process.ExitCode
        }
    } -Force
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value {
        try { Stop-Process -Id $this.Process.Id -Force -ErrorAction SilentlyContinue } catch {}
    } -Force
    return $wrapper
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $env:OC_WORKTREE_PATH = $WorktreePath
    $env:OC_BRANCH_NAME = $BranchName
    $env:OC_MERGE_PLAN = $MergePlan
    $env:OC_PROJECT_ROOT = $WorktreePath

    $mergeId = "merge-" + ($BranchName -replace '[/\\]', '-')
    $model = Get-DevinModel
    $effort = Get-DevinEffort

    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "${mergeId}.stdout"
    $errFile = Join-Path $agentDir "${mergeId}.stderr"
    $inFile = Join-Path $agentDir "${mergeId}.stdin"

    $prompt = Build-DevinMergePrompt -MergePlan $MergePlan -BranchName $BranchName -WorktreePath $WorktreePath -RepoDir $RepoDir

    $startRecord = @{
        v = 1
        type = 'start'
        runId = "salmon-devin-$mergeId"
        taskId = $mergeId
        lane = 'merge'
        profile = 'devin'
        model = $model
        effort = $effort
        cwd = $WorktreePath
        transport = 'acp'
    } | ConvertTo-Json -Compress

    $promptRecord = @{
        v = 1
        type = 'prompt'
        id = 'p-1'
        text = $prompt
    } | ConvertTo-Json -Compress

    $shutdownRecord = @{
        v = 1
        type = 'shutdown'
    } | ConvertTo-Json -Compress

    $inputLines = "$startRecord`n$promptRecord`n$shutdownRecord"
    $inputLines | Out-File -FilePath $inFile -Encoding utf8 -NoNewline

    $env:DSO_DSH_ACP_COMMAND = "devin acp --model $model"

    $node = (Get-Command node -ErrorAction SilentlyContinue)
    if (-not $node) { throw "Node.js is required for the Devin executor" }

    $proc = Start-Process -FilePath $node.Source -ArgumentList $script:AdapterCli `
        -NoNewWindow -PassThru -WorkingDirectory $WorktreePath `
        -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Register-SpawnedPid -ProcessId $proc.Id -AgentId $mergeId
    Set-Content -Path (Join-Path $agentDir "$mergeId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$mergeId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline
    Write-OrchestratorLog "MERGE_DEVIN_SPAWN merge=$mergeId pid=$($proc.Id) branch=$BranchName worktree=$WorktreePath"
    return New-MergeProcessWrapper -Process $proc -OutFile $outFile
}

function Clear-AgentArtifacts {
    param([string]$AgentId, [string]$RepoDir)
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    foreach ($ext in @('.pid', '.heartbeat', '.mode', '.stdout', '.stderr', '.log', '.stdin')) {
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
