# Review Workflow - Tool Configuration

> Tool baseline is at `Skills/Orchestrator/tools.md`. This file documents Review-specific deltas only.

## Review-specific deltas

### Lock + Move pattern (per-file claim)

Use the canonical 4-step pattern to claim a file:

```powershell
# 1. Lock
Lock-File -FileNames @("Tasks/Review/$file") -MaxWaitMs 30000 | Out-Null

# 2. Move to working dir
$destDir = "Tasks/Working/$env:OC_RESERVATION_AGENT_ID"
$null = New-Item -ItemType Directory -Path $destDir -Force
Move-Item -LiteralPath "Tasks/Review/$file" -Destination "$destDir/$file" -Force

# 3. Prepend Lock Header
$lockHeader = @"
**Lock**
- Agent: $env:OC_RESERVATION_AGENT_ID
- Locked: $([datetime]::UtcNow.ToString('o'))
- Status: locked
---
"@
$content = Get-Content "$destDir/$file" -Raw
Set-Content -LiteralPath "$destDir/$file" -Value ($lockHeader + "`n" + $content) -Encoding utf8 -Force

# 4. Emit CLAIM + HANDSHAKE events (with retry on mutex contention)
$maxRetries = 5
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        Write-WorkflowEvent -Type CLAIM -Files @("Tasks/Review/$file") -Phase review -Detail "locked -> Working/$env:OC_RESERVATION_AGENT_ID/"
        Write-WorkflowEvent -Type HANDSHAKE -Files @("Tasks/Review/$file") -Phase review -Detail "Reviewer picking up <file description>"
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}
```

### Agent ID isolation (avoid concurrent collision)

Set `$env:OC_RESERVATION_AGENT_ID` from a per-script variable, NOT from `.session-agent.txt`. Concurrent agents may overwrite that file between your initial load and subsequent use:

```powershell
# DO NOT do this — vulnerable to concurrent agent overwrites:
$env:OC_RESERVATION_AGENT_ID = (Get-Content .session-agent.txt ...)

# INSTEAD, capture once at session start and reuse:
$script:myAgentId = "review-XXXX-XXXXXXXXXXXXXXX"
$env:OC_RESERVATION_AGENT_ID = $script:myAgentId
```

### Per-file timing cache

Append to `.session-timing.txt` after each file's Finale:

```powershell
"$planName: ${elapsed}s" | Out-File -FilePath ".session-timing.txt" -Append -Encoding utf8
```

The file is gitignored. Read it during CC step 10 to produce the per-file breakdown.

## Changelog
- 2026-06-16: Replaced TODO with canonical lock/move pattern, agent ID isolation guidance, and per-file timing cache pattern (extracted from 13-file Review pass on 2026-06-16)
