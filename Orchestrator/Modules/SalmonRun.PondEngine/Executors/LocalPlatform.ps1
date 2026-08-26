<#
.DEPRECATED: This file is not loaded by the module loader and has zero callers in the codebase.
Kept for reference per Script Deprecation Protocol.
#>

$script:platformServerProcess = $null
$script:platformServerPort = 0
$script:platformServerReady = $false

function Initialize-Executor {
    $script:platformServerPort = Get-Random -Minimum 22000 -Maximum 22999
    $repoRoot = $script:RepoRoot
    $logDir = Join-Path $repoRoot "Tasks/Logs"
    $serverOut = Join-Path $logDir "opencode-platform-server.stdout"
    $serverErr = Join-Path $logDir "opencode-platform-server.stderr"
    Write-Host "  Starting opencode-platform server on port $($script:platformServerPort)..." -ForegroundColor Yellow

    $script:platformServerProcess = Start-Process -FilePath "opencode" `
        -ArgumentList "serve", "--port", $script:platformServerPort.ToString(), "--hostname", "127.0.0.1" `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:platformServerPort)/api/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        } catch { Write-OrchestratorLog "HEALTH_CHECK_FAILED opencode-platform server at port $($script:platformServerPort) not reachable" -Level WARN }
    }
    if (-not $ready) {
        Write-Warning "opencode-platform server did not become ready within 60s"
    }
    $script:platformServerReady = $ready
    Write-OrchestratorLog "PLATFORM_SERVER_START port=$($script:platformServerPort) ready=$ready pid=$($script:platformServerProcess.Id)"
}

function Invoke-ExecutorTask {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$OpencodePath,
        [int]$InstanceId, [ValidateSet("coder", "reviewer")][string]$Role = "coder",
        [switch]$UseWorktrees, [string]$Namespace = ""
    )
    $env:OC_STREAM_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $RepoDir
    $env:OC_CANONICAL_TASK_ROOT = Join-Path $RepoDir 'Tasks\Code'

    $command = if ($Role -eq "reviewer") { "work-review" } else { "work-stream" }

    $useWorktreeDir = $UseWorktrees -and (Test-Path "$RepoDir/Tasks/worktrees/$StreamId")
    $targetDir = if ($useWorktreeDir) { "$RepoDir/Tasks/worktrees/$StreamId" } else { $RepoDir }

    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "${StreamId}.stdout"
    $errFile = Join-Path $agentDir "${StreamId}.stderr"

    $serverUrl = "http://127.0.0.1:$($script:platformServerPort)"
    $attachArgs = "attach", $serverUrl, "--command", $command, "--session-name", $StreamId

    $proc = Start-Process -FilePath $OpencodePath `
        -ArgumentList $attachArgs `
        -NoNewWindow -PassThru -WorkingDirectory $targetDir `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value $proc.Id.ToString() -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline

    return New-ExecutorTask -Handle $proc -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task.Handle) { return }
    $Task.HasExited = $Task.Handle.HasExited
    if ($Task.HasExited -and $null -eq $Task.ExitCode) {
        Start-Sleep -Seconds 3
        $Task.ExitCode = $Task.Handle.ExitCode
        $repoRoot = $script:RepoRoot
        $agentDir = Join-Path $repoRoot "Tasks/Logs/agents"
        $outFile = Join-Path $agentDir "${Task.StreamId}.stdout"
        $errFile = Join-Path $agentDir "${Task.StreamId}.stderr"
        $output = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        $Task.Output = ($output, $stderr) | Where-Object { $_ } | Out-String
    }
}

function Stop-ExecutorTask {
    param($Task)
    if (-not $Task.Handle) { return }
    try { Stop-ProcessTree -ProcessId $Task.Handle.Id -Force } catch { Write-OrchestratorLog "EXECUTOR_STOP_FAILED StreamId=$($Task.StreamId) pid=$($Task.Handle.Id)" -Level WARN }
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $env:OC_WORKTREE_PATH = $WorktreePath
    $env:OC_BRANCH_NAME = $BranchName
    $env:OC_MERGE_PLAN = $MergePlan
    $env:OC_PROJECT_ROOT = $RepoDir

    $opencodeCmd = Test-OpenCodeAvailable
    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $outFile = Join-Path $agentDir "merge-$(Split-Path $BranchName -Leaf).stdout"
    $errFile = Join-Path $agentDir "merge-$(Split-Path $BranchName -Leaf).stderr"

    $proc = Start-Process -FilePath $opencodeCmd -ArgumentList "run --command merge" `
        -NoNewWindow -PassThru -WorkingDirectory $RepoDir `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $proc.WaitForExit(600000)
    $output = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    return @{ ExitCode = $proc.ExitCode; Output = $output }
}

function Disconnect-Executor {
    if ($script:platformServerProcess -and -not $script:platformServerProcess.HasExited) {
        Write-Host "  Stopping opencode-platform server (PID $($script:platformServerProcess.Id))..." -ForegroundColor DarkGray
        try { Stop-ProcessTree -ProcessId $script:platformServerProcess.Id -Force } catch { Write-OrchestratorLog "EXECUTOR_DISCONNECT_FAILED pid=$($script:platformServerProcess.Id)" -Level WARN }
        $script:platformServerProcess = $null
        $script:platformServerReady = $false
    }
}
