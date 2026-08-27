<#
.SYNOPSIS
    Writes a PID file for the current agent process.
.DESCRIPTION
    Creates the Tasks/Logs/agents/ directory if missing, writes the current
    process ID to <AgentId>.pid, and registers an engine event to clean up
    the file on session exit.
.PARAMETER AgentId
    Unique agent identifier used as the PID filename stem.
.OUTPUTS
    The full path to the created PID file.
#>
function Write-AgentPidFile {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId
    )
    $taskRoot = Get-SalmonTaskRoot
    $agentDir = Join-Path $taskRoot "Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $pidPath = Join-Path $agentDir "$AgentId.pid"
    $PID.ToString() | Write-AtomicFile -Path $pidPath -Encoding utf8

    $eventName = "SalmonRun.PidCleanup_$AgentId"
    $null = Register-EngineEvent -SourceIdentifier $eventName -Action {
        Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    } -SupportEvent -ErrorAction SilentlyContinue

    return $pidPath
}


