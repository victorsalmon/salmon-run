function Invoke-AgentPollingLoop {
    <#
    .SYNOPSIS
        Polls a task directory for incoming files, sleeping between cycles.
        Shared primitive used by both Coder and Reviewer Drain Queue.
    .DESCRIPTION
        Implements the standard polling loop defined in workflow-primitives.md Ã‚Â§ Drain Queue:
        - Sleeps $PollIntervalSeconds between each check
        - Up to $MaxIdleCycles consecutive empty cycles (counter resets on each entry)
        - Returns $true if files appear during polling (caller returns to dispatch)
        - Returns $false if all cycles exhaust with no files (caller reports and stops)
        - Outputs formatted cycle status with role context
    .PARAMETER TaskDirectory
        Relative path from repo root to the directory to watch (e.g. "Tasks/Code", "Tasks/Review").
    .PARAMETER RoleName
        Role label for status messages (e.g. "coder", "reviewer").
    .PARAMETER PollIntervalSeconds
        Seconds to sleep between cycles. Default 120.
    .PARAMETER MaxIdleCycles
        Max consecutive empty cycles before stopping. Default 10.
    .PARAMETER Pattern
        File glob pattern to match. Default "*.md". Note: -Filter accepts a single pattern only
        (e.g. "*.md"). For multiple patterns, the caller must iterate or use -Pattern with a
        wildcard that covers both (e.g. "*" and filter in the loop body).
    .EXAMPLE
        Invoke-AgentPollingLoop -TaskDirectory "Tasks/Code" -RoleName "coder"
    .EXAMPLE
        Invoke-AgentPollingLoop -TaskDirectory "Tasks/Review" -RoleName "reviewer" -Pattern "*.md"
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskDirectory,

        [Parameter(Mandatory)]
        [string]$RoleName,

        [int]$PollIntervalSeconds = 120,
        [int]$MaxIdleCycles = 10,
        [string]$Pattern = "*.md"
    )

    $repoRoot = Get-SalmonRunRepoRoot
    $watchPath = Join-Path -Path $repoRoot -ChildPath $TaskDirectory

    for ($cycle = 1; $cycle -le $MaxIdleCycles; $cycle++) {
        Write-Information -MessageData "Polling cycle $cycle/$MaxIdleCycles - sleeping ${PollIntervalSeconds}s..."
        Start-Sleep -Seconds $PollIntervalSeconds

        try { $files = Get-ChildItem -Path "$watchPath" -Filter $Pattern -ErrorAction Stop } catch { Write-Warning "Invoke-AgentPollingLoop: failed to list $watchPath : $_"; $files = @() }
        if ($files.Count -gt 0) {
            Write-Information -MessageData "Tasks found! $($files.Count) file(s) in $TaskDirectory"
            return $true
        }

        Write-Information -MessageData "No files found. Cycle $cycle/$MaxIdleCycles complete."
    }

    $totalMinutes = [math]::Round(($MaxIdleCycles * $PollIntervalSeconds) / 60, 0)
    Write-Information -MessageData "Polling exhausted - no $RoleName tasks arrived in $totalMinutes min"
    return $false
}

