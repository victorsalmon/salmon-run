# Executors/Dsh.ps1
# Salmon-owned DSH executor. ACP wire handling stays in dsh-adapter; this file
# adapts the normalized JSONL protocol to the salmon stream contract.

$dshModuleManifest = Join-Path $PSScriptRoot "..\..\DeepSeek.Orchestrator\DeepSeek.Orchestrator.psd1"
if (-not (Get-Command Get-DshRuntime -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $dshModuleManifest)) {
    Import-Module -Name $dshModuleManifest -Force -DisableNameChecking
}

$script:DshRuntime = $null
$script:DshAdapterCli = $null

function Initialize-Executor {
    $script:DshRuntime = Get-DshRuntime -OrchestratorRoot $script:RepoRoot
    Test-DshRuntime -Runtime $script:DshRuntime | Out-Null
    $script:DshAdapterCli = $script:DshRuntime.AdapterCli
    Write-OrchestratorLog "DSH_EXECUTOR_READY adapter='$script:DshAdapterCli' acp='$($script:DshRuntime.AcpCommand)' version=$($script:DshRuntime.DshVersion)"
    return $script:DshRuntime.DshPath
}

function Test-ExecutorPreflight {
    param([string]$AgentPath)
    if ($AgentPath -and (Test-Path -LiteralPath $AgentPath)) {
        $version = & $AgentPath --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-OrchestratorLog "DSH_PREFLIGHT_FAILED exit=$LASTEXITCODE output='$($version -join '|')'" -Level ERROR
            return $false
        }
    }
    return $true
}

function Get-DshEffort {
    $effort = if ($env:DSH_EFFORT) { $env:DSH_EFFORT } elseif ($script:HarnessConfig -and $script:HarnessConfig.Effort) { $script:HarnessConfig.Effort } else { 'max' }
    if ($effort -notin @('medium', 'high', 'max')) { return 'max' }
    return $effort
}

function Get-DshModel {
    if ($env:DSH_MODEL) { return $env:DSH_MODEL }
    if ($script:HarnessConfig -and $script:HarnessConfig.Model) { return $script:HarnessConfig.Model }
    return 'deepseek-v4-flash'
}

function Get-DshPrompt {
    param([string]$Role, [string]$Namespace, [string]$ProjectRoot, [string]$BranchName, [string]$WorktreePath)
    $template = Join-Path $PSScriptRoot "..\Templates\devin-$Role-prompt.md"
    if (-not (Test-Path -LiteralPath $template)) { throw "DSH prompt template not found: $template" }
    $text = Get-Content -LiteralPath $template -Raw
    $canonicalPlanQueue = if ($env:OC_CANONICAL_TASK_ROOT) { $env:OC_CANONICAL_TASK_ROOT } else { Join-Path $ProjectRoot 'Tasks\Code' }
    $text = $text -replace '\{\{Namespace\}\}', $Namespace
    $text = $text -replace '\{\{ProjectRoot\}\}', $ProjectRoot
    $text = $text -replace '\{\{CanonicalPlanQueue\}\}', $canonicalPlanQueue
    $text = $text -replace '\{\{BranchBlock\}\}', $(if ($BranchName) { "Branch: $BranchName" } else { '' })
    $text = $text -replace '\{\{WorktreeBlock\}\}', $(if ($WorktreePath) { "Worktree: $WorktreePath" } else { '' })
    return $text.TrimEnd()
}

function Build-DshPrompt {
    param([string]$Role, [string]$StreamDir, [string]$Namespace, [string]$RepoDir)
    $files = @(Get-ChildItem -LiteralPath $StreamDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files) { throw "No plan file in stream dir '$StreamDir'" }
    $header = Get-DshPrompt -Role $Role -Namespace $Namespace -ProjectRoot $RepoDir -BranchName $env:OC_BRANCH_NAME -WorktreePath $env:OC_WORKTREE_PATH
    $body = $files | ForEach-Object { "## Plan: $($_.Name)`n$((Get-Content -LiteralPath $_.FullName -Raw))" } | Join-String -Separator "`n`n---`n`n"
    return "$header`n`n$body"
}

function New-DshInput {
    param([string]$TaskId, [string]$Lane, [string]$Model, [string]$Effort, [string]$Cwd, [string]$Prompt)
    $start = @{ v = 1; type = 'start'; runId = "salmon-dsh-$TaskId"; taskId = $TaskId; lane = $Lane; profile = 'dsh'; model = $Model; effort = $Effort; cwd = $Cwd; transport = 'acp' }
    $promptRecord = @{ v = 1; type = 'prompt'; id = 'p-1'; text = $Prompt }
    $shutdown = @{ v = 1; type = 'shutdown' }
    return Invoke-DeepSeekJsonLFilter -Records @($start, $promptRecord, $shutdown) -Model $Model
}

function Start-DshProcess {
    param([string]$TaskId, [string]$Lane, [string]$Cwd, [string]$Prompt, [string]$RepoDir)
    if (-not $script:DshRuntime) { Initialize-Executor | Out-Null }
    $model = Get-DshModel
    $effort = Get-DshEffort
    $agentDir = Join-Path $RepoDir 'Tasks\Logs\agents'
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "$TaskId.stdout"
    $errFile = Join-Path $agentDir "$TaskId.stderr"
    $inFile = Join-Path $agentDir "$TaskId.stdin"
    New-DshInput -TaskId $TaskId -Lane $Lane -Model $model -Effort $effort -Cwd $Cwd -Prompt $Prompt | Out-File -LiteralPath $inFile -Encoding utf8 -NoNewline
    $env:DSO_DSH_ACP_COMMAND = $script:DshRuntime.AcpCommand
    $env:DSO_DSH_HEADLESS_COMMAND = $script:DshRuntime.HeadlessCommand
    $proc = Start-Process -FilePath $script:DshRuntime.NodePath -ArgumentList $script:DshAdapterCli -NoNewWindow -PassThru -WorkingDirectory $Cwd -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Register-SpawnedPid -ProcessId $proc.Id -AgentId $TaskId
    Set-Content -LiteralPath (Join-Path $agentDir "$TaskId.pid") -Value $proc.Id.ToString() -Encoding utf8 -NoNewline
    Set-Content -LiteralPath (Join-Path $agentDir "$TaskId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8 -NoNewline
    return $proc
}

function Start-StreamCoder {
    param([string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$AgentPath, [int]$InstanceId, [ValidateSet('coder','reviewer')][string]$Role = 'coder', [switch]$UseWorktrees, [string]$Namespace = '', [string]$BranchName = '')
    if ([string]::IsNullOrWhiteSpace($StreamId)) { throw 'AGENT_ID_EMPTY: refusing to spawn DSH stream' }
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
    $prompt = Build-DshPrompt -Role $Role -StreamDir $StreamDir -Namespace $Namespace -RepoDir $target
    $model = Get-DshModel
    if (Test-IsDeepSeekV4Model -Model $model) {
        $prompt = Invoke-DeepSeekPromptFilter -Prompt $prompt -Role $Role
    }
    $proc = Start-DshProcess -TaskId $StreamId -Lane $Role -Cwd $target -Prompt $prompt -RepoDir $RepoDir
    $files = @(Get-ChildItem -LiteralPath $StreamDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Write-OrchestratorLog "DSH_STREAM_SPAWN stream=$StreamId pid=$($proc.Id) role=$Role files=$($files.Count) model=$(Get-DshModel) effort=$(Get-DshEffort) ns=$Namespace"
    return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace -RepoDir $RepoDir
}

function New-ExecutorTask {
    param($Handle, [string]$StreamId, [datetime]$StartTime, [string]$Role, [string]$Namespace, [string]$RepoDir = '')
    [pscustomobject]@{ Handle = $Handle; Pid = $Handle.Id; StreamId = $StreamId; StartTime = $StartTime; Role = $Role; Namespace = $Namespace; RepoDir = $RepoDir; HasExited = $Handle.HasExited; ExitCode = if ($Handle.HasExited) { $Handle.ExitCode } else { $null } }
}

function Stop-ExecutorTask { param($Task) if ($Task -and $Task.Handle) { try { Stop-ProcessTree -ProcessId $Task.Handle.Id -Force } catch { Write-OrchestratorLog "DSH_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN } } }

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task -or -not $Task.Handle) { return }
    $Task.HasExited = $Task.Handle.HasExited
    if ($Task.HasExited -and $null -eq $Task.ExitCode) { $Task.ExitCode = $Task.Handle.ExitCode }
    if ($Task.HasExited -and $Task.ExitCode -eq 0) {
        $outFile = Join-Path $Task.RepoDir "Tasks\Logs\agents\$($Task.StreamId).stdout"
        $Task.ExitCode = Get-DshAdapterExitCode -OutFile $outFile -Default $Task.ExitCode
    }
    return $Task
}

function Clear-AgentArtifacts {
    param([string]$AgentId, [string]$RepoDir)
    $dir = Join-Path $RepoDir 'Tasks\Logs\agents'
    foreach ($ext in @('.pid','.heartbeat','.mode','.stdout','.stderr','.log','.stdin')) { Remove-Item -LiteralPath (Join-Path $dir "$AgentId$ext") -Force -ErrorAction SilentlyContinue }
    Write-OrchestratorLog "AGENT_CLEANUP agent=$AgentId"
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    throw 'DSH merge dispatch is intentionally not implicit; use the reviewer workflow to produce a verified merge plan.'
}
