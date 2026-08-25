<#
.SYNOPSIS
    Removes stale PID, heartbeat, and optional log files for dead agents.
.DESCRIPTION
    Scans Tasks/Logs/agents/ for .pid and .heartbeat files belonging to agents
    that are no longer alive (determined by Test-AgentAlive). Removes orphaned
    heartbeat files where no corresponding PID file exists.
.PARAMETER HeartbeatStaleThresholdSeconds
    Age threshold in seconds for considering a heartbeat stale. Default 120.
.PARAMETER RemoveLogs
    If set, also removes .log files for agents with no PID file.
.OUTPUTS
    PSCustomObject with RemovedCount (int) and RemovedFiles (string[]).
#>
function Clear-StaleAgentFiles {
    [OutputType([PSCustomObject])]
    param(
        [int]$HeartbeatStaleThresholdSeconds = 120,
        [switch]$RemoveLogs
    )
    $repoRoot = Get-InterclawRepoRoot
    $agentDir = Join-Path $repoRoot "Tasks/Logs/agents"
    if (-not (Test-Path $agentDir)) { return [PSCustomObject]@{ RemovedCount = 0; RemovedFiles = @() } }

    $removedFiles = [System.Collections.Generic.List[string]]::new()

    Get-ChildItem "$agentDir/*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
        $agentId = $_.BaseName
        $alive = Test-AgentAlive -AgentId $agentId -HeartbeatStaleThresholdSeconds $HeartbeatStaleThresholdSeconds
        if ($alive.Stale) {
            $reason = if (-not $alive.ProcessAlive) { "process-dead" } else { "heartbeat-stale" }
            $pidPath = $_.FullName
            $hbPath = Join-Path $agentDir "$agentId.heartbeat"
            Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
            $removedFiles.Add("agent=$agentId type=pid reason=$reason")
            if (Test-Path $hbPath) {
                Remove-Item $hbPath -Force -ErrorAction SilentlyContinue
                $removedFiles.Add("agent=$agentId type=heartbeat reason=$reason")
            }
            if ($RemoveLogs) {
                $logPath = Join-Path $agentDir "$agentId.log"
                if (Test-Path $logPath) {
                    Remove-Item $logPath -Force -ErrorAction SilentlyContinue
                    $removedFiles.Add("agent=$agentId type=log reason=$reason")
                }
            }
            foreach ($ext in @('.mode', '.stdout', '.stderr')) {
                $artPath = Join-Path $agentDir "$agentId$ext"
                if (Test-Path $artPath) {
                    Remove-Item $artPath -Force -ErrorAction SilentlyContinue
                    $removedFiles.Add("agent=$agentId type=$ext reason=$reason")
                }
            }
        }
    }

    Get-ChildItem "$agentDir/*.heartbeat" -ErrorAction SilentlyContinue | ForEach-Object {
        $agentId = $_.BaseName
        $pidPath = Join-Path $agentDir "$agentId.pid"
        if (-not (Test-Path $pidPath)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            $removedFiles.Add("agent=$agentId type=heartbeat reason=orphan")
        }
    }

    if ($RemoveLogs) {
        Get-ChildItem "$agentDir/*.log" -ErrorAction SilentlyContinue | ForEach-Object {
            $agentId = $_.BaseName
            $pidPath = Join-Path $agentDir "$agentId.pid"
            if (-not (Test-Path $pidPath)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                $removedFiles.Add("agent=$agentId type=log reason=orphan-no-pid")
            }
        }
    }

    $summary = [PSCustomObject]@{
        RemovedCount = $removedFiles.Count
        RemovedFiles = $removedFiles.ToArray()
    }
    Write-SetupLog "STALE_AGENT_CLEANUP count=$($summary.RemovedCount)" -Level INFO -Agent core -Phase cleanup
    return $summary
}


