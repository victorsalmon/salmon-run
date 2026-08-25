function Write-WorkflowEvent {
    <#
    .SYNOPSIS
        Appends a JSONL event to the workflow-events.log notification board.
    .DESCRIPTION
        Writes one JSONL line to Tasks/Logs/workflow-events.log with an auto-incrementing
        event ID, ISO-8601 UTC timestamp, agent identity, event type, phase, file paths,
        and an optional detail string. The directory and file are created on first use.
        Best-effort — never throws on IO failure.

        Use -Clear to delete the entire log and all per-agent offset files (audit rotation).
    .PARAMETER Type
        Event type from the catalog: SESSION_START, SESSION_END, CLAIM, RELEASE, MOVE,
        COMMIT, PUSH, CONNASCENCE_BLOCK, FILE_LOCKED, STALL_DETECTED, CONFUSION, ERROR,
        RESCUE, HANDSHAKE.
    .PARAMETER Files
        Array of file paths relevant to the event (task files, committed paths, etc.).
    .PARAMETER Detail
        Free-text detail string (e.g. commit hash, destination directory, agent that locked).
    .PARAMETER AgentId
        Agent identity. Defaults to $env:OC_RESERVATION_AGENT_ID, else "<unknown>".
    .PARAMETER Phase
        Agent phase at time of event: coder, reviewer, sentry, rescue, audit, planner, cowork.
    .PARAMETER Clear
        Switch. When set, deletes workflow-events.log and all files in .offsets/,
        effectively rotating the board clean. Does NOT write a new event.
    .EXAMPLE
        Write-WorkflowEvent -Type CLAIM -Files @("Tasks/Working/plan.md") -AgentId "coder-847-35" -Phase coder
    .EXAMPLE
        Write-WorkflowEvent -Clear -AgentId "auditor-001-01" -Phase audit
    #>
    [OutputType([void])]
    param(
        [Parameter(ParameterSetName = 'Write', Mandatory)]
        [Parameter(ParameterSetName = 'Clear')]
        [string]$Type,

        [Parameter(ParameterSetName = 'Write')]
        [string[]]$Files = @(),

        [Parameter(ParameterSetName = 'Write')]
        [string]$Detail = "",

        [Parameter(ParameterSetName = 'Write')]
        [Parameter(ParameterSetName = 'Clear')]
        [string]$AgentId = $(if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { '<unknown>' }),

        [Parameter(ParameterSetName = 'Write')]
        [Parameter(ParameterSetName = 'Clear')]
        [string]$Phase = "",

        [Parameter(ParameterSetName = 'Clear', Mandatory)]
        [switch]$Clear
    )

    $Files = @() + $Files
    $repoRoot = & (Get-Item function:Get-SalmonRunRepoRoot)
    $eventsDir = Join-Path $repoRoot "Tasks" "Logs"
    $logFile = Join-Path $eventsDir "workflow-events.log"

    if ($Clear.IsPresent) {
        try {
            if (Test-Path $logFile) { Remove-Item $logFile -Force }
            $offsetsDir = Join-Path $eventsDir ".offsets"
            if (Test-Path $offsetsDir) {
                Get-ChildItem "$offsetsDir/*.offset" -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            $null = New-Item -ItemType Directory -Path $eventsDir -Force
        } catch {
            Write-Debug "Write-WorkflowEvent cleanup failed: $_"
        }
        return
    }

    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-WorkflowEvents-Mutex")
        $timeoutMs = if ($env:PESTER_PROFILE) { 500 } else { 5000 }
        if (-not $mutex.WaitOne($timeoutMs)) {
            throw "Write-WorkflowEvent: Mutex timeout after ${timeoutMs}ms -- concurrent access detected"
        }

        $null = New-Item -ItemType Directory -Path $eventsDir -Force

        # Read offset for O(1) ID computation
        $offsetsDir = Join-Path $eventsDir ".offsets"
        $null = New-Item -ItemType Directory -Path $offsetsDir -Force
        $offsetPath = Join-Path $offsetsDir ".event-log.offset"

        $nextId = 1
        $byteOffset = 0
        if (Test-Path $offsetPath) {
            try {
                $offsetData = Get-Content $offsetPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json
                $nextId = $offsetData.lastId + 1
                $byteOffset = $offsetData.byteOffset
            } catch {
                $lastLine = Get-Content $logFile -Tail 1 -ErrorAction SilentlyContinue
                if ($lastLine -match '"id":(\d+)') { $nextId = [int]$Matches[1] + 1 }
                $byteOffset = 0
            }
        } elseif (Test-Path $logFile) {
            $lastLine = Get-Content $logFile -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine -match '"id":(\d+)') { $nextId = [int]$Matches[1] + 1 }
        }

        $eventData = @{
            id     = $nextId
            ts     = [datetime]::UtcNow.ToString('o')
            agent  = $AgentId
            type   = $Type
            phase  = $Phase
            files  = $Files
            detail = $Detail
        }

        $json = $eventData | ConvertTo-Json -Compress -ErrorAction SilentlyContinue
        if ($json) {
            if ($byteOffset -gt 0) {
                $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                $fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
                $writer.WriteLine($json)
                $writer.Flush()
                $newOffset = $fs.Position
                $writer.Close()
                $fs.Close()
            } else {
                Add-Content -Path $logFile -Value $json -Encoding utf8 -ErrorAction SilentlyContinue
                $newOffset = 0
                if (Test-Path $logFile) {
                    $fi = New-Object System.IO.FileInfo $logFile
                    $newOffset = $fi.Length
                }
            }

            $offsetData = @{ lastId = $nextId; byteOffset = $newOffset } | ConvertTo-Json -Compress
            Set-Content -Path $offsetPath -Value $offsetData -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Debug "Write-WorkflowEvent failed: $_"
        if ($_.Exception.Message -match "concurrent access detected") { throw }
    } finally {
        if ($mutex) {
            try { $mutex.Release() } catch { Write-Debug "Write-WorkflowEvent mutex release failed: $_" }
            $mutex.Dispose()
        }
    }
}
