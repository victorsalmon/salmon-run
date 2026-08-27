# Restore-SessionCheckpoint
# Used by: /checkpoint command (opencode.json) — step 3 (restore) of the
# checkpoint-compact-restore ritual.
#
# Reads the newest checkpoint for the current session and prints it to stdout so the
# model re-ingests the saved workflow state as a tool result. READ-ONLY: this script
# never writes, moves, or modifies any file. Re-orientation (re-reading the plan file,
# re-reading workflow-primitives.md for the step you were on) is the agent's job, driven
# by the /checkpoint command template — this script only hands back the saved state.

function Restore-SessionCheckpoint {
    param(
        [Parameter(Mandatory = $false)]
        [string]$SessionId,

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot
    )

    if (-not $SessionId) {
        $SessionId = if ($env:OPENCODE_SESSION_ID) { $env:OPENCODE_SESSION_ID } else { 'unknown' }
    }

    if (-not $RepoRoot) {
        $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
    }

    $checkpointsDir = Join-Path $RepoRoot 'Tasks\Logs\checkpoints'
    if (-not (Test-Path -LiteralPath $checkpointsDir)) {
        Write-Host "[checkpoint] No checkpoint found for session $SessionId (checkpoints dir does not exist)"
        return $null
    }

    $candidates = Get-ChildItem -LiteralPath $checkpointsDir -Filter "$SessionId*.checkpoint.md" -File -ErrorAction SilentlyContinue
    if (-not $candidates) {
        Write-Host "[checkpoint] No checkpoint found for session $SessionId"
        return $null
    }

    # Newest by LastWriteTime (the writer's filename embeds a unix-ts that sorts identically,
    # but LastWriteTime is robust to filename parsing edge cases).
    $newest = $candidates | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1

    $content = Get-Content -LiteralPath $newest.FullName -Raw -ErrorAction Stop

    Write-Host "[checkpoint] Restoring newest checkpoint: $($newest.FullName)"
    Write-Host "----- CHECKPOINT BEGIN -----"
    Write-Host $content
    Write-Host "----- CHECKPOINT END -----"

    return $newest.FullName
}
