param(
    [Parameter(Mandatory)]
    [string]$TaskDirectory,

    [Parameter(Mandatory)]
    [string]$RoleName,

    [int]$MaxIdleCycles = 10,

    [int]$PollIntervalSeconds = 120,

    [string]$SignalDir = "Tasks",

    [string]$AgentId = $script:agentId,

    [string]$Pattern = "*.md"
)

Write-Host "[POLL] Entering drain queue — polling $TaskDirectory (${Pattern}) every ${PollIntervalSeconds}s for $MaxIdleCycles cycles ($($MaxIdleCycles * $PollIntervalSeconds / 60) min total)"

for ($cycle = 1; $cycle -le $MaxIdleCycles; $cycle++) {
    Start-Sleep -Seconds $PollIntervalSeconds

    # Check for stop signal before each poll cycle
    $stopScript = Join-Path $PSScriptRoot "Invoke-StopSignalCheck.ps1"
    if (Test-Path -LiteralPath $stopScript) {
        . $stopScript -Mode $RoleName -AgentId $AgentId -SignalDir $SignalDir
        if (Invoke-StopSignalCheck -Mode $RoleName -AgentId $AgentId -SignalDir $SignalDir) {
            Write-Host "[POLL] Stop signal received — exiting poll cycle $cycle/$MaxIdleCycles"
            return $false
        }
    }

    # Scan for new files matching the pattern, excluding .gitkeep
    $files = Get-ChildItem -LiteralPath $TaskDirectory -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    if ($files) {
        Write-Host "[POLL] Cycle $cycle/$MaxIdleCycles — $($files.Count) file(s) arrived in $TaskDirectory"
        if (Get-Command Write-WorkflowEvent -ErrorAction SilentlyContinue) {
            Write-WorkflowEvent -Type RELEASE -Detail "poll-cycle-${cycle}: $($files.Count) files arrived" -Phase $RoleName
        }
        return $true
    }

    Write-Host "[POLL] Cycle $cycle/$MaxIdleCycles — empty, sleeping ${PollIntervalSeconds}s"
}

Write-Host "[POLL] Polling exhausted — no $RoleName tasks arrived in $($MaxIdleCycles * $PollIntervalSeconds / 60) min"
return $false
