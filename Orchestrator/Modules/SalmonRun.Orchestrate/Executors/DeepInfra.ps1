# Executors/DeepInfra.ps1
# Codex CLI executor backed by the local DeepInfra Responses relay.
#
# The relay owns the DeepInfra credential and translates Responses requests to
# DeepInfra Chat Completions. This executor owns only the local Codex process,
# its per-stream configuration, and the salmon stream lifecycle contract.

$script:DeepInfraCodexPath = $null
$script:DeepInfraRelayUrl = $null

. (Join-Path $PSScriptRoot '..\..\..\Orchestration\Resolve-CodexCliPath.ps1')

function Get-DeepInfraModel {
    param($HarnessConfig = $script:HarnessConfig)
    if ($HarnessConfig -and $HarnessConfig.Model) { return [string]$HarnessConfig.Model }
    if ($env:DEEPINFRA_MODEL) { return $env:DEEPINFRA_MODEL }
    return 'deepseek-ai/DeepSeek-V4-Flash-0731'
}

function Get-DeepInfraEffort {
    param($HarnessConfig = $script:HarnessConfig)
    $effort = if ($HarnessConfig -and $HarnessConfig.Effort) { [string]$HarnessConfig.Effort } elseif ($env:DEEPINFRA_EFFORT) { $env:DEEPINFRA_EFFORT } else { 'medium' }
    if ($effort -notin @('low', 'medium', 'high', 'xhigh')) { return 'medium' }
    return $effort
}

function Get-DeepInfraRelayUrl {
    $url = if ($env:DEEPINFRA_RELAY_URL) { $env:DEEPINFRA_RELAY_URL } else { 'http://127.0.0.1:8787' }
    return $url.TrimEnd('/')
}

function Get-DeepInfraCodexPath {
    try {
        return Resolve-CodexCliPath -ConfiguredPath $env:CODEX_CLI_PATH
    } catch {
        throw "DeepInfra executor: $($_.Exception.Message)"
    }
}

function Test-DeepInfraRelay {
    param([string]$RelayUrl, [string]$Model)
    try {
        $health = Invoke-RestMethod -Uri "$RelayUrl/health" -Method Get -TimeoutSec 5 -ErrorAction Stop
    } catch {
        Write-OrchestratorLog "DEEPINFRA_RELAY_UNHEALTHY url='$RelayUrl' error='$($_.Exception.Message)'" -Level ERROR
        return $false
    }
    if (-not $health.ok) {
        Write-OrchestratorLog "DEEPINFRA_RELAY_UNHEALTHY url='$RelayUrl' reason='health endpoint returned ok=false'" -Level ERROR
        return $false
    }
    if ($health.model -and $health.model -ne $Model) {
        Write-OrchestratorLog "DEEPINFRA_RELAY_MODEL_MISMATCH configured='$($health.model)' requested='$Model'" -Level WARN
    }
    return $true
}

function Initialize-Executor {
    $provider = if ($script:HarnessConfig -and $script:HarnessConfig.Provider) { $script:HarnessConfig.Provider } else { 'deepinfra' }
    if ($provider -ne 'deepinfra') {
        throw "DeepInfra executor only supports provider 'deepinfra'; got '$provider'"
    }
    $script:DeepInfraCodexPath = Get-DeepInfraCodexPath
    $script:DeepInfraRelayUrl = Get-DeepInfraRelayUrl
    $model = Get-DeepInfraModel
    if (-not (Test-ExecutorPreflight -AgentPath $script:DeepInfraCodexPath)) {
        throw "DeepInfra executor: Codex CLI preflight failed for '$script:DeepInfraCodexPath'. Set CODEX_CLI_PATH to a standalone executable or command wrapper."
    }
    if (-not (Test-DeepInfraRelay -RelayUrl $script:DeepInfraRelayUrl -Model $model)) {
        throw "DeepInfra executor: relay is unavailable at '$script:DeepInfraRelayUrl'. Start the deepinfra-codex-relay before starting the orchestrator."
    }
    Write-OrchestratorLog "DEEPINFRA_EXECUTOR_READY codex='$script:DeepInfraCodexPath' relay='$script:DeepInfraRelayUrl' provider=$provider model=$model effort=$(Get-DeepInfraEffort)"
    return $script:DeepInfraCodexPath
}

function Test-ExecutorPreflight {
    param([string]$AgentPath)
    if (-not $AgentPath) { return $false }
    try {
        $version = & $AgentPath --version 2>&1
    } catch {
        Write-OrchestratorLog "DEEPINFRA_CODEX_PREFLIGHT_FAILED error='$($_.Exception.Message)'" -Level ERROR
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-OrchestratorLog "DEEPINFRA_CODEX_PREFLIGHT_FAILED exit=$LASTEXITCODE output='$($version -join '|')'" -Level ERROR
        return $false
    }
    return $true
}

function Get-DeepInfraPrompt {
    param([string]$Role, [string]$Namespace, [string]$ProjectRoot, [string]$BranchName, [string]$WorktreePath)
    $template = Join-Path $PSScriptRoot "..\Templates\devin-$Role-prompt.md"
    if (-not (Test-Path -LiteralPath $template)) { throw "DeepInfra prompt template not found: $template" }
    $text = Get-Content -LiteralPath $template -Raw
    $canonicalPlanQueue = if ($env:OC_CANONICAL_TASK_ROOT) { $env:OC_CANONICAL_TASK_ROOT } else { Join-Path $ProjectRoot 'Tasks\Code' }
    $text = $text -replace '\{\{Namespace\}\}', $Namespace
    $text = $text -replace '\{\{ProjectRoot\}\}', $ProjectRoot
    $text = $text -replace '\{\{CanonicalPlanQueue\}\}', $canonicalPlanQueue
    $text = $text -replace '\{\{BranchBlock\}\}', $(if ($BranchName) { "Branch: $BranchName" } else { '' })
    $text = $text -replace '\{\{WorktreeBlock\}\}', $(if ($WorktreePath) { "Worktree: $WorktreePath" } else { '' })
    return $text.TrimEnd()
}

function Build-DeepInfraPrompt {
    param([string]$Role, [string]$StreamDir, [string]$Namespace, [string]$RepoDir)
    $files = @(Get-ChildItem -LiteralPath $StreamDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files) { throw "No plan file in stream dir '$StreamDir'" }
    $header = Get-DeepInfraPrompt -Role $Role -Namespace $Namespace -ProjectRoot $RepoDir -BranchName $env:OC_BRANCH_NAME -WorktreePath $env:OC_WORKTREE_PATH
    $body = $files | ForEach-Object { "## Plan: $($_.Name)`n$((Get-Content -LiteralPath $_.FullName -Raw))" } | Join-String -Separator "`n`n---`n`n"
    return "$header`n`n$body"
}

function Build-DeepInfraMergePrompt {
    param([string]$MergePlan, [string]$BranchName, [string]$WorktreePath, [string]$RepoDir)
    if (-not (Test-Path -LiteralPath $MergePlan)) { throw "Merge plan not found: $MergePlan" }
    $header = @"
You are the merge agent for salmon-orchestrator.
Role: merge
Project root: $RepoDir
Branch: $BranchName
Worktree: $WorktreePath
Resolve the supplied merge feedback in the worktree. Inspect the actual conflict
state, preserve completed work, validate the result, and commit only the merge
resolution. Do not ask for routine confirmation; stop only for a genuinely
irreversible or missing-authority decision.
"@.Trim()
    return "$header`n`n## Merge plan`n$((Get-Content -LiteralPath $MergePlan -Raw))"
}

function New-DeepInfraCodexConfig {
    param([string]$Model, [string]$Effort, [string]$RelayUrl)
    return @"
model = "$Model"
model_provider = "deepinfra-relay"
model_reasoning_effort = "$Effort"
approval_policy = "never"
sandbox_mode = "workspace-write"

[model_providers.deepinfra-relay]
name = "DeepInfra via local relay"
base_url = "$RelayUrl/v1"
wire_api = "responses"
requires_openai_auth = false
"@
}

function Start-DeepInfraProcess {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Lane,
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$RepoDir,
        [string]$Model = (Get-DeepInfraModel),
        [string]$Effort = (Get-DeepInfraEffort)
    )
    if (-not $script:DeepInfraCodexPath) { Initialize-Executor | Out-Null }
    $agentDir = Join-Path $RepoDir 'Tasks\Logs\agents'
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $codexHome = Join-Path $agentDir "$TaskId-codex-home"
    $null = New-Item -ItemType Directory -Path $codexHome -Force
    $outFile = Join-Path $agentDir "$TaskId.stdout"
    $errFile = Join-Path $agentDir "$TaskId.stderr"
    $inFile = Join-Path $agentDir "$TaskId.stdin"
    $configFile = Join-Path $codexHome 'config.toml'
    New-DeepInfraCodexConfig -Model $Model -Effort $Effort -RelayUrl $script:DeepInfraRelayUrl | Set-Content -LiteralPath $configFile -Encoding utf8
    $Prompt | Set-Content -LiteralPath $inFile -Encoding utf8 -NoNewline
    $previousCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHome, 'Process')
    try {
        $arguments = @('exec', '--json', '--skip-git-repo-check', '--sandbox', 'workspace-write', '--model', $Model, '-')
        $proc = Start-Process -FilePath $script:DeepInfraCodexPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodexHome, 'Process')
    }
    Register-SpawnedPid -ProcessId $proc.Id -AgentId $TaskId
    Set-Content -LiteralPath (Join-Path $agentDir "$TaskId.pid") -Value $proc.Id.ToString() -Encoding utf8 -NoNewline
    Set-Content -LiteralPath (Join-Path $agentDir "$TaskId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8 -NoNewline
    Write-OrchestratorLog "DEEPINFRA_PROCESS_SPAWN task=$TaskId pid=$($proc.Id) lane=$Lane model=$Model effort=$Effort relay=$script:DeepInfraRelayUrl"
    return $proc
}

function New-ExecutorTask {
    param($Handle, [string]$StreamId, [datetime]$StartTime, [string]$Role, [string]$Namespace, [string]$RepoDir = '')
    return [PSCustomObject]@{
        Handle = $Handle
        Pid = if ($Handle) { $Handle.Id } else { $null }
        StreamId = $StreamId
        StartTime = $StartTime
        Role = $Role
        Namespace = $Namespace
        RepoDir = $RepoDir
        HasExited = if ($Handle) { $Handle.HasExited } else { $true }
        ExitCode = if ($Handle -and $Handle.HasExited) { $Handle.ExitCode } else { $null }
    }
}

function Start-StreamCoder {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$AgentPath,
        [int]$InstanceId, [ValidateSet('coder','reviewer')][string]$Role = 'coder',
        [switch]$UseWorktrees, [string]$Namespace = '', [string]$BranchName = '', $HarnessConfig, [switch]$PlanProfileOverride
    )
    if ([string]::IsNullOrWhiteSpace($StreamId)) { throw 'AGENT_ID_EMPTY: refusing to spawn DeepInfra stream' }
    $target = $RepoDir
    if ($UseWorktrees) {
        $BranchName = if ($BranchName) { $BranchName } else { "wt/$StreamId" }
        $wtPath = Join-Path $RepoDir "Tasks\worktrees\$StreamId"
        . (Join-Path (Get-SkillsRoot -RepoRoot $RepoDir) 'Git\Invoke-WorktreeSetup.ps1')
        $result = New-AgentWorktree -BranchName $BranchName -WorktreePath $wtPath -Resume
        if ($result -and -not $result.Error) { $target = $result.WorktreePath; $env:OC_WORKTREE_PATH = $target; $env:OC_BRANCH_NAME = $BranchName }
    }
    $env:OC_STREAM_ID = $StreamId
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $target
    $env:OC_CANONICAL_TASK_ROOT = Join-Path $RepoDir 'Tasks\Code'
    $prompt = Build-DeepInfraPrompt -Role $Role -StreamDir $StreamDir -Namespace $Namespace -RepoDir $target
    $activeConfig = if ($HarnessConfig) { $HarnessConfig } else { $script:HarnessConfig }
    $model = Get-DeepInfraModel -HarnessConfig $activeConfig
    $effort = Get-DeepInfraEffort -HarnessConfig $activeConfig
    $proc = Start-DeepInfraProcess -TaskId $StreamId -Lane $Role -Cwd $target -Prompt $prompt -RepoDir $RepoDir -Model $model -Effort $effort
    return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace -RepoDir $RepoDir
}

function Stop-ExecutorTask {
    param($Task)
    if ($Task -and $Task.Handle) {
        try { Stop-ProcessTree -ProcessId $Task.Handle.Id -Force } catch { Write-OrchestratorLog "DEEPINFRA_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN }
    }
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    $Task.HasExited = $Task.Handle.HasExited
    if ($Task.HasExited -and $null -eq $Task.ExitCode) { $Task.ExitCode = $Task.Handle.ExitCode }
    return $Task
}

function Clear-AgentArtifacts {
    param([string]$AgentId, [string]$RepoDir)
    $agentDir = Join-Path $RepoDir 'Tasks\Logs\agents'
    foreach ($ext in @('.pid', '.heartbeat', '.mode', '.stdout', '.stderr', '.log', '.stdin')) {
        Remove-Item -LiteralPath (Join-Path $agentDir "$AgentId$ext") -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $agentDir "$AgentId-codex-home") -Recurse -Force -ErrorAction SilentlyContinue
    Write-OrchestratorLog "AGENT_CLEANUP agent=$AgentId"
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $prompt = Build-DeepInfraMergePrompt -MergePlan $MergePlan -BranchName $BranchName -WorktreePath $WorktreePath -RepoDir $RepoDir
    $taskId = "merge-$($BranchName -replace '[^a-zA-Z0-9._-]', '-')"
    return Start-DeepInfraProcess -TaskId $taskId -Lane 'merge' -Cwd $WorktreePath -Prompt $prompt -RepoDir $RepoDir -Model (Get-DeepInfraModel) -Effort (Get-DeepInfraEffort)
}
