# Write-SessionCheckpoint
# Used by: /checkpoint command (opencode.json), Code/workflow.md predictive compaction,
# Review/workflow.md predictive compaction, workflow-primitives.md Drain Queue step 1.
#
# Persists an interactive agent's workflow state to a session-scoped file BEFORE context
# compaction. The companion Restore-SessionCheckpoint.ps1 re-reads it afterward so the
# agent can re-orient in place — compaction becomes lossless with respect to workflow
# position, and the context-gated exit (Drain Queue step 2) is rarely needed.
#
# Read-only w.r.t. git and locks: this script NEVER mutates the repo, only writes a log
# file under Tasks/Logs/checkpoints/. Safe to call mid-plan.

function Write-SessionCheckpoint {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('code', 'review')]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlan,

        [Parameter(Mandatory = $false)]
        [string]$PlanStatus = 'not specified',

        [Parameter(Mandatory = $false)]
        [string]$DeferredItems = 'none',

        [Parameter(Mandatory = $false)]
        [string]$Notes = 'none',

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot
    )

    # Resolve repo root the same way neighboring Scripts/ files do (3 levels up from here).
    if (-not $RepoRoot) {
        $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
    }

    # --- Auto-captured state -------------------------------------------------

    $sessionId = if ($env:OPENCODE_SESSION_ID) { $env:OPENCODE_SESSION_ID } else { 'unknown' }

    $sessionStart = 'unknown'
    $sessionStartLog = Join-Path $RepoRoot ("Tasks\Logs\session-start-" + ($env:OC_STREAM_ID ?? $env:OC_RESERVATION_AGENT_ID ?? $PID) + '.log')
    if (-not (Test-Path -LiteralPath $sessionStartLog)) {
        # Legacy fallback: sessions that wrote the unscoped shared file
        $sessionStartLog = Join-Path $RepoRoot 'Tasks\Logs\session-start.log'
    }
    if (Test-Path -LiteralPath $sessionStartLog) {
        $raw = (Get-Content -LiteralPath $sessionStartLog -Raw -ErrorAction SilentlyContinue)
        if ($raw) { $sessionStart = $raw.Trim() }
    }

    $timestamp = Get-Date -Format 'o'
    $unixTs = [string][int][double]::Parse((Get-Date -UFormat %s))

    # Git state — porcelain, never mutating. Fall back gracefully if not a git repo.
    $branch = 'unknown'
    $porcelain = 'clean'
    try {
        Push-Location -LiteralPath $RepoRoot
        $branchOut = & git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branchOut) { $branch = $branchOut.Trim() }
        $porcelainOut = & git status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and $porcelainOut) {
            $porcelain = ($porcelainOut -join "`n").TrimEnd()
            if ([string]::IsNullOrWhiteSpace($porcelain)) { $porcelain = 'clean' }
        }
    } catch {
        # Leave defaults; git is not available or not a repo.
    } finally {
        if ($null -ne (Get-Location).Path) { try { Pop-Location } catch {} }
    }

    # Compaction count: derive from existing checkpoints for this session (highest + 1).
    # This is the durable source of truth — robust to model amnesia after compaction,
    # since each tool call is a fresh PowerShell process and $script: variables do not
    # persist across them.
    $checkpointsDir = Join-Path $RepoRoot 'Tasks\Logs\checkpoints'
    $compactionCount = 1
    if (Test-Path -LiteralPath $checkpointsDir) {
        $existing = Get-ChildItem -LiteralPath $checkpointsDir -Filter "$sessionId*.checkpoint.md" -File -ErrorAction SilentlyContinue
        if ($existing) {
            $highest = 0
            foreach ($f in $existing) {
                $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match '\*\*Compaction Count\*\*:\s*(\d+)') {
                    $n = [int]$matches[1]
                    if ($n -gt $highest) { $highest = $n }
                }
            }
            $compactionCount = $highest + 1
        }
    }

    # --- Write the checkpoint ------------------------------------------------

    if (-not (Test-Path -LiteralPath $checkpointsDir)) {
        New-Item -ItemType Directory -Path $checkpointsDir -Force | Out-Null
    }

    $fileName = "${sessionId}-${unixTs}.checkpoint.md"
    $outPath = Join-Path $checkpointsDir $fileName

    $body = @"
# Session Checkpoint
- **Session ID**: $sessionId
- **Timestamp**: $timestamp
- **Mode**: $Mode
- **Session Start**: $sessionStart
- **Compaction Count**: $compactionCount

## Workflow State
- **Current Plan**: $CurrentPlan
- **Plan Status**: $PlanStatus
- **Locks / Routing Notes**: $Notes

## Git State
- **Branch**: $branch
- **Uncommitted files** (git status --porcelain):
``````
$porcelain
``````

## Deferred Items
$DeferredItems
"@

    Set-Content -LiteralPath $outPath -Value $body -Encoding utf8

    Write-Host "[checkpoint] Written: $outPath"
    Write-Host "[checkpoint] Compaction count for session ${sessionId}: $compactionCount"
    return $outPath
}
