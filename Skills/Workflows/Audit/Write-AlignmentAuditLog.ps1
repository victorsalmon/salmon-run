function Write-AlignmentAuditLog {
    <#
    .SYNOPSIS
        Appends a JSONL entry to the alignment audit log with hash-chain integrity.
    .DESCRIPTION
        Writes one JSONL line to Tasks/Logs/alignment-audit-<date>.jsonl with a
        SHA-256 hash chaining each entry to its predecessor. Provides tamper-evident
        audit trail for multi-domain alignment audits.
        Standalone — no module dependencies. Resolves the log directory relative to
        this script's own location.
    .PARAMETER Domain
        "domain-<N>", "master"
    .PARAMETER Action
        "phase-start", "phase-complete", "session-create", "finding",
        "progress-update", "close-out", "finding-retraction", "finding-crossref"
        #
        # CC enforcement: the auditor MUST emit exactly one "close-out" entry per
        # audit pass, after the final "phase-complete". The Reviewer and downstream
        # agents read the audit log and treat a missing "close-out" as an incomplete
        # audit (CC not run). See the Completion Checklist section for the full
        # procedure.
    .PARAMETER Detail
        Free-text detail or JSON payload.
    .PARAMETER Severity
        "info", "low", "medium", "high", "critical"
    .PARAMETER SessionFile
        Sub-session file name (if applicable).
    .PARAMETER Stage
        Stage name (e.g. "scope-assessment", "session-creation").
    .PARAMETER StageDurationMs
        Elapsed milliseconds for this stage.
    .EXAMPLE
        Write-AlignmentAuditLog -Domain "domain-1" -Action "phase-start" -Detail "Claimed by auditor-001"
    .EXAMPLE
        Write-AlignmentAuditLog -Domain "domain-4" -Action "finding-retraction" -Detail "Retracting D1-CRITICAL-1: resolved by session plan"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$Action,
        [string]$Detail = "",
        [string]$Severity = "info",
        [string]$SessionFile = "",
        [string]$Stage = "",
        [int]$StageDurationMs = 0
    )
    try {
        $LogDir = Join-Path $HOME "intersite-orchestrator\Tasks\Logs"
        $Date = (Get-Date -Format 'yyyy-MM-dd')
        $LogPath = Join-Path $LogDir "alignment-audit-$Date.jsonl"
        $null = New-Item -ItemType Directory -Path $LogDir -Force

        $MutexName = "Global\AlignmentAuditLog-$Date"
        $Mutex = $null
        $acquiredLock = $false
        try {
            $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
            $acquiredLock = $Mutex.WaitOne(3000)
            if (-not $acquiredLock) {
                Start-Sleep -Milliseconds 100
                $acquiredLock = $Mutex.WaitOne(3000)
            }
            if (-not $acquiredLock) {
                Write-Warning "Write-AlignmentAuditLog: Could not acquire mutex for $LogPath — skipping entry"
                return
            }

            $PrevHash = ""
            if (Test-Path $LogPath) {
                $LastLine = Get-Content $LogPath -Tail 1 -ErrorAction SilentlyContinue
                if ($LastLine) {
                    $PrevEntry = $LastLine | ConvertFrom-Json
                    $PrevHash = $PrevEntry.hash
                }
            }

            $Sep = [char]0x1F
            $Data = "$Domain$Sep$Action$Sep$Detail$Sep$Stage$Sep$StageDurationMs$Sep$(Get-Date -Format 'o')"
            $HashInput = "$PrevHash$Sep$Data"
            $Hash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($HashInput)
                )
            ).Replace("-", "").ToLower()

            $Entry = [ordered]@{
                ts = (Get-Date -Format 'o')
                domain = $Domain
                action = $Action
                detail = $Detail
                severity = $Severity
                session = $SessionFile
                stage = $Stage
                stage_duration_ms = $StageDurationMs
                prev = $PrevHash
                hash = $Hash
            } | ConvertTo-Json -Compress

            Add-Content -Path $LogPath -Value $Entry -Encoding UTF8NoBOM
        } finally {
            if ($acquiredLock -and $Mutex) { $Mutex.ReleaseMutex() }
            if ($Mutex) { $Mutex.Dispose() }
        }
    } catch {
        Write-Warning "Write-AlignmentAuditLog failed: $_"
    }
}
