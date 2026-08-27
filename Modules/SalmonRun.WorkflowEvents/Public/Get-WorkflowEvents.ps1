function Get-WorkflowEvents {
    <#
    .SYNOPSIS
        Returns unseen workflow events for a given agent, tracking read offset per agent.
    .DESCRIPTION
        Reads from Tasks/Logs/workflow-events.log starting from the agent's stored
        offset (in Tasks/Logs/.offsets/<agent-id>.offset). Returns all new events
        as PSCustomObjects and updates the offset to EOF.
        Best-effort — never throws on IO failure.
    .PARAMETER AgentId
        Agent identity. Defaults to $env:OC_RESERVATION_AGENT_ID, else "<unknown>".
    .PARAMETER Clear
        Switch. Delegates to Write-WorkflowEvent -Clear, which deletes the log and offsets.
    .EXAMPLE
        Get-WorkflowEvents -AgentId "coder-847-35"
    .EXAMPLE
        Get-WorkflowEvents -Clear -AgentId "auditor-001-01"
    #>
    [OutputType([array])]
    param(
        [string]$AgentId = $(if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { "<unknown>" }),
        [switch]$Clear
    )

    if ($Clear.IsPresent) {
        & (Get-Item function:Write-WorkflowEvent) -Clear -AgentId $AgentId -Phase "audit"
        return @()
    }

    $taskRoot = Get-SalmonTaskRoot
    $logFile = Join-Path $taskRoot "Logs" "workflow-events.log"

    if (-not (Test-Path $logFile)) {
        return @()
    }

    $mutex = $null
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-WorkflowEvents-Mutex")
        if (-not $mutex.WaitOne(5000)) {
            Write-Warning "Get-WorkflowEvents: Mutex timeout after 5000ms -- returning empty"
            return @()
        }
        $acquired = $true

        $offsetsDir = Join-Path $taskRoot "Logs" ".offsets"
        $null = New-Item -ItemType Directory -Path $offsetsDir -Force

        $offsetFile = Join-Path $offsetsDir "$AgentId.offset"
        $startOffset = 0
        if (Test-Path $offsetFile) {
            $saved = (Get-Content $offsetFile -Raw -ErrorAction SilentlyContinue) -replace '\s', ''
            if ($saved -match '^\d+$') { $startOffset = [long]$saved }
        }

        $fileStream = $null
        $reader = $null
        try {
            $fileStream = [System.IO.File]::OpenRead($logFile)
            $fileLength = $fileStream.Length

            if ($startOffset -ge $fileLength) {
                return @()
            }

            $fileStream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = [System.IO.StreamReader]::new($fileStream)
            $newEvents = @()
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    try {
                        $evt = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($evt) { $newEvents += $evt }
                    } catch {
                        Write-Debug "Get-WorkflowEvents: JSON parse failed: $_"
                    }
                }
            }

            $newOffset = $fileStream.Position
            [System.IO.File]::WriteAllText($offsetFile, $newOffset.ToString(), [System.Text.UTF8Encoding]::new($false))

            return $newEvents
        }
        finally {
            if ($reader) { $reader.Dispose() }
            if ($fileStream) { $fileStream.Dispose() }
        }
    } catch {
        Write-Debug "Get-WorkflowEvents failed: $_"
        return @()
    } finally {
        if ($mutex) {
            if ($acquired) {
                try { $mutex.Release() } catch { Write-Debug "Get-WorkflowEvents mutex release failed: $_" }
            }
            $mutex.Dispose()
        }
    }
}
