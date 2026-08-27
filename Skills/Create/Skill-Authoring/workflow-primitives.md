---
name: workflow-primitives
---
# Workflow Primitives

All agents follow a standard workflow: **Start**, **Execute**, **Complete**. The workflow is composed from modular primitives defined below. The **Complete** phase runs the AGENTS.md Completion Checklist (steps 1–12) — this is the only completion gate. Per-file commit/push actions are folded into each mode's Workflow Finale step so the agent re-enters the drain queue after every file instead of terminating. No separate Sign Off phase.

## Agent identity and registration

1. **Determine your agent ID**: Use `$env:OC_RESERVATION_AGENT_ID` if set (orchestrated dispatch), or generate a new identity using the orchestrator's format: `<mode>-<random(1-1000001)>-<filetime>` (e.g., `code-142057-134253429109383`). PowerShell equivalent: `"$role-$(Get-Random -Minimum 1 -Maximum 1000001)-$([Math]::Floor((Get-Date).ToFileTime() / 1000))"`. The orchestrator uses this format for all subprocess agents, and agents dispatched to containers must match — the Rescue-OrphanedLocks function relies on consistent ID patterns to clean up stalled files.
2. **Detect orchestrator context** — Determine whether this agent was spawned by an orchestrator, and if so capture its identity and PID for Lock Header enrichment. Queue-drain (standalone) agents set all three to `$null`/`$false`:

   ```powershell
   $script:orchestrated = -not [string]::IsNullOrWhiteSpace($env:OC_STREAM_ID)
   $script:orchestratorId = if ($script:orchestrated) { $env:OC_STREAM_ID } else { $null }
   $script:orchestratorPID = $null

   if ($script:orchestrated) {
       # Walk the parent-process chain to find the orchestrator's PID.
       # The orchestrator spawns agents via Start-Process, so PPID is the
       # PowerShell/opencode shell that launched us. Walk up to find the
       # orchestrator entry-point PID.
       try {
           $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
           $visited = @{}
           $depth = 0
           while ($ppid -and $depth -lt 10 -and -not $visited.ContainsKey($ppid)) {
               $visited[$ppid] = $true
               $proc = Get-Process -Id $ppid -ErrorAction SilentlyContinue
               if (-not $proc) { break }
               # Detect orchestrator by its agent-ID heartbeat file
               $hbFile = "~/.salmon/Tasks/Logs/agents/orchestrator-$($proc.Id).heartbeat"
               if (Test-Path $hbFile) {
                   $script:orchestratorPID = $proc.Id
                   break
               }
               # If no orchestrator marker found, walk further up
               $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId = $ppid").ParentProcessId
               $depth++
           }
        } catch {
            Write-Warning "Could not detect orchestrator PID: $_"
        }
   }
   ```
3. **Write PID file** — write the **numeric process ID** (`$PID.ToString()`), NOT the agent ID string. The orchestrator's aliveness check reads this file and parses it as an integer; a non-numeric value (like `"lane-coder-1"`) makes the PID-based aliveness guard fail and forces a fallback to heartbeat-only checking:
   ```powershell
   $agentDir = "~/.salmon/Tasks/Logs/agents"; $null = New-Item -ItemType Directory -Path $agentDir -Force
   $PID.ToString() | Out-File -FilePath "$agentDir/<your-agent-id>.pid" -Encoding utf8 -NoNewline
   ```
   **Do NOT** write `$env:OC_RESERVATION_AGENT_ID` to the `.pid` file — that env var holds the agent ID *string* (e.g. `lane-coder-1`), not a PID. If the orchestrator already wrote a correct numeric PID to the file before your agent started, leave it; only write if the file is missing or contains a non-numeric value.
4. **Seed heartbeat**:
    ```powershell
    [datetime]::UtcNow.ToString('o') | Out-File -FilePath "$agentDir/<your-agent-id>.heartbeat" -Encoding utf8 -NoNewline
    ```
    Write-WorkflowEvent -Type SESSION_START -AgentId "<your-agent-id>" -Phase "<mode>" -Detail "Session started"
5. **Set up structured logging** (unless already set by orchestrator):
   ```powershell
   $env:ORCHESTRATOR_SETUP_LOG = (Resolve-Path "$agentDir/<your-agent-id>.log").Path
   ```
6. **Write SESSION_START event**:
   ```powershell
   Write-WorkflowEvent -Type SESSION_START -AgentId "<your-agent-id>" -Phase "<mode>"
   ```
7. **Heartbeat during work**: After every significant action (locking a file, completing a task, running tests, committing, before releasing), update the heartbeat:
   ```powershell
   [datetime]::UtcNow.ToString('o') | Out-File -FilePath "$agentDir/<your-agent-id>.heartbeat" -Encoding utf8 -NoNewline
   ```
8. **Module preflight (orchestrator only)** — Before entering the main dispatch loop, the orchestrator must attempt to load `SalmonRun.AgentLifecycle` (which provides `Test-AgentAlive`, `Write-AgentHeartbeat`, `Write-AgentPidFile`, and `Clear-StaleAgentFiles`) and `SalmonRun.Orchestrate` (which provides `Rescue-OrphanedLocks` and `Handle-OrphanStatus`). Try `Import-Module SalmonRun.AgentLifecycle` first, then `Import-Module SalmonRun.Orchestrate`, then fall back to dot-sourcing the module files directly from `Orchestrator/Modules/SalmonRun.AgentLifecycle/SalmonRun.AgentLifecycle.ps1` and `Orchestrator/Modules/SalmonRun.Orchestrate/SalmonRun.Orchestrate.ps1`. If both fail, log the failure with `PSModulePath` context and continue with degraded functionality — the orchestrator's `Rescue-OrphanedLocks` will fall back to raw PID-file checking instead.
9. **Store agent ID in script scope** — The `$agentId` variable is referenced throughout the workflow (Working/ subdirectory path, lock file naming, event logging). After determining your agent ID in step 1, store it in a script-scoped variable:
    ```powershell
    $script:agentId = "<your-agent-id>"
    ```
    Also initialize the compaction counter (used by the Drain Queue to track how many times context has been compacted this session):
    ```powershell
    $script:compactionCount = 0
    ```
    Because each tool call is a fresh PowerShell process, `$script:compactionCount` is only reliable when re-derived from the latest checkpoint file via `Restore-SessionCheckpoint` (see `Skills/Documentation/Scripts/Restore-SessionCheckpoint.ps1`). The checkpoint ritual is the durable source of truth for the count — the in-memory variable is a convenience for the current tool call only.
10. **Load recent audit errors** — If the agent has a domain context (e.g., Bookkeeper mode → `"Bookkeeper"`, Marketer mode → `"marketer"`), load recent errors from the audit trail:
   ```powershell
   if (Get-Module SalmonRun.Audit) {
       $errors = Get-AuditTrail -Domain "<domain>" -Since (Get-Date).AddDays(-7) -IncludeErrors -Last 20
       if ($errors) {
           Write-SetupLog -Message "Recent audit errors ($($errors.Count) in 7d):" -Level WARN
           $errors | ForEach-Object { Write-SetupLog -Message "  [$($_.action)] $($_.error?.message) at $($_.ts)" -Level WARN }
       }
   }
   ```
    For domains without a fixed context (e.g., Code mode working on mixed domains), use `Get-AuditTrail -Domain "adhoc"`. Agents that operate fleet-wide (Sentry) skip this step. This surfaces recent API failures before any new call is made, so the agent can anticipate broken endpoints, rate limits, or auth issues. If the same error has failed 3+ times, the agent should check for a related skill or write a manual task.
11. **Register cleanup** (optional — auto-cleanup on graceful exit):
    ```powershell
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Remove-Item "$agentDir/$script:agentId.pid" -Force -ErrorAction SilentlyContinue
        Write-WorkflowEvent -Type SESSION_END -AgentId "$script:agentId" -Phase "<mode>"
    } -SupportEvent -ErrorAction SilentlyContinue | Out-Null
    ```
12. **Check freshness** — Run the freshness checker to surface stale observational-state entries before relying on them:
    ```powershell
    & (Join-Path $PSScriptRoot "..\..\..\..\Skills\\Orchestration\Check-Freshness.ps1") -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\.."))
    ```
    If it exits 1 (stale entries found), read the warnings and re-verify any facts that matter for this session. Ignore stale entries not relevant to the current task. This step is defined in the `_freshness.json` convention (see AGENTS.md § Freshness & Observational State).

## Lock Header (chain of possession)

> **Sanctioned path: call `New-LockHeader.ps1`.** The inline splice snippet
> below is **deprecated** (kept for reference as the atomic-write contract spec).
> Always use the canonical script instead:
> ```powershell
> & "Skills/Cowork/Scripts/New-LockHeader.ps1" $agentId "locked" -OutputPath $filePath -ExistingContent $body
> ```
> The script implements atomic write + truncation detection + git restore with
> history-walk fallback — the inline splice duplicates this logic and can drift.
> See `### Atomic lock-header writes` below for the contract the script implements.

**First agent on a file** — prepend the Lock Header above the original content, including orchestrator context when running under an orchestrator. After prepending, write a CLAIM event. **Deprecated inline splice (use `New-LockHeader.ps1` instead):**

```powershell
$lockHeader = @"
**Lock**
- Agent: $script:agentId
- Locked: $([datetime]::UtcNow.ToString('o'))
- Started: $([datetime]::UtcNow.ToString('o'))
- Progress: 0%
- Status: locked
"@
if ($script:orchestrated) {
    $lockHeader += @"
- Orchestrated: true
- OrchestratorId: $script:orchestratorId
- OrchestratorPID: $script:orchestratorPID
"@
}
try {
    $body = Get-Content -Path $filePath -Raw -ErrorAction Stop
} catch {
    Write-Error "Lock-header prepend failed: cannot read $filePath"
    exit 3
}
if ([string]::IsNullOrWhiteSpace($body)) {
    Write-Error "Lock-header prepend failed: $filePath body is empty"
    exit 3
}
$tempPath = "$filePath.tmp.$PID"
($lockHeader + "`r`n" + $body) | Set-Content -Path $tempPath -NoNewline -Encoding utf8
Move-Item -LiteralPath $tempPath -Destination $filePath -Force

$written = Get-Content $filePath -Raw
$bodySurvived = ($written.Length -ge $body.Length -and $written -match '# Session Plan:')
if (-not $bodySurvived) {
    Write-Host "LOCK_WRITE_TRUNCATION path='$filePath' len=$($written.Length) originalLen=$($body.Length)" -ForegroundColor Red
    # Directory-agnostic git resolution: locate the work tree from the file's own
    # location (git -C walks up from $filePath's parent), never from the caller's cwd
    # (orchestrator-tooling-2 review feedback).
    $repoRoot = git -C (Split-Path -Parent $filePath) rev-parse --show-toplevel 2>$null
    if ($repoRoot) {
        $relSpec = try { [System.IO.Path]::GetRelativePath($repoRoot, $filePath).Replace('\', '/') } catch { $filePath }
        $restored = git -C $repoRoot show "HEAD:$relSpec" 2>$null
        if (-not $restored) {
            # History fallback: the tracked copy may have been moved or displaced by a
            # concurrent safe-pull — search all refs before giving up (orchestrator-tooling-2).
            # The newest commit touching the path may be its deletion commit, so walk
            # candidates newest→oldest and take the first commit where the path resolves.
            $candidates = git -C $repoRoot log --all --format='%H' -- "$relSpec" 2>$null
            foreach ($candidate in $candidates) {
                if (-not $candidate) { continue }
                $restored = git -C $repoRoot show "$candidate`:$relSpec" 2>$null
                if ($restored) { break }
            }
        }
    }
    if ($restored) {
        $restored | Set-Content -Path $filePath -NoNewline -Encoding utf8
        Write-Host "LOCK_WRITE_RESTORED path='$filePath' from git HEAD" -ForegroundColor Yellow
    } else {
        # No canonical blob exists anywhere in history — a header-only file is worse
        # than no file (it can be committed by a concurrent safe-pull checkpoint).
        Write-Host "LOCK_WRITE_UNRESTORABLE path='$filePath' — deleting truncated file and aborting lock" -ForegroundColor Red
        Remove-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
    }
    exit 3
}

Write-WorkflowEvent -Type CLAIM -Files @("<file-path>") -AgentId "<agent-id>" -Phase "<mode>"
```

Queue-drain (standalone) agents omit the `Orchestrated`/`OrchestratorId`/`OrchestratorPID` fields entirely — the `if ($script:orchestrated)` guard handles this automatically.

**Chain of possession** — if a Lock Header already exists, append your block after the last `---` separator. Each agent writes only its own block — do not carry forward or modify prior agents' orchestrator fields. Include orchestrator context in your block if `$script:orchestrated` is true, using the same template logic as the first agent. **Deprecated inline splice (use `New-LockHeader.ps1` instead — the script handles chain-of-possession appends via its `ConvertTo-LockHeader` function):**

```powershell
$blockHeader = @"
---
- Agent: $script:agentId
- Locked: $([datetime]::UtcNow.ToString('o'))
- Started: $([datetime]::UtcNow.ToString('o'))
- Progress: 0%
- Status: locked
"@
if ($script:orchestrated) {
    $blockHeader += @"
- Orchestrated: true
- OrchestratorId: $script:orchestratorId
- OrchestratorPID: $script:orchestratorPID
"@
}
try {
    $existing = Get-Content $filePath -Raw -ErrorAction Stop
} catch {
    Write-Error "Lock-header append failed: cannot read $filePath"
    exit 3
}
if ([string]::IsNullOrWhiteSpace($existing)) {
    Write-Error "Lock-header append failed: $filePath body is empty"
    exit 3
}
$lastSep = $existing.LastIndexOf('---')
if ($lastSep -lt 0) {
    Write-Error "Lock-header append failed: no '---' separator in $filePath"
    exit 3
}
$before = $existing.Substring(0, $lastSep)
$after  = $existing.Substring($lastSep + 3)
$tempPath = "$filePath.tmp.$PID"
($before + "---`n" + $blockHeader + "`n" + $after) | Set-Content -Path $tempPath -NoNewline -Encoding utf8
Move-Item -LiteralPath $tempPath -Destination $filePath -Force

$written = Get-Content $filePath -Raw
$bodySurvived = ($written.Length -ge $existing.Length -and $written -match '# Session Plan:')
if (-not $bodySurvived) {
    Write-Host "LOCK_WRITE_TRUNCATION path='$filePath' len=$($written.Length) originalLen=$($existing.Length)" -ForegroundColor Red
    $repoRoot = git -C (Split-Path -Parent $filePath) rev-parse --show-toplevel 2>$null
    if ($repoRoot) {
        $relSpec = try { [System.IO.Path]::GetRelativePath($repoRoot, $filePath).Replace('\', '/') } catch { $filePath }
        $restored = git -C $repoRoot show "HEAD:$relSpec" 2>$null
        if (-not $restored) {
            $candidates = git -C $repoRoot log --all --format='%H' -- "$relSpec" 2>$null
            foreach ($candidate in $candidates) {
                if (-not $candidate) { continue }
                $restored = git -C $repoRoot show "$candidate`:$relSpec" 2>$null
                if ($restored) { break }
            }
        }
    }
    if ($restored) {
        $restored | Set-Content -Path $filePath -NoNewline -Encoding utf8
        Write-Host "LOCK_WRITE_RESTORED path='$filePath' from git HEAD" -ForegroundColor Yellow
    }
    exit 3
}

Write-WorkflowEvent -Type CLAIM -Files @("<file-path>") -AgentId "<agent-id>" -Phase "<mode>"
```

**Releasing** — update your block with `Released: <now>` and `Status: released`. Do **not** modify prior agents' blocks. Add **Deferred** notes and a **Validation** block (Coder only) before the `---`. Before releasing, write a RELEASE event:

```powershell
Write-WorkflowEvent -Type RELEASE -Files @("<file-path>") -AgentId "<agent-id>" -Phase "<mode>" -Detail "Status: released"
```

**DependsOn verification**: After the `Status: released` line, if the plan has a `**DependsOn**:` field, append a `DependsResolved: true/false` line. The Coder sets this to `true` only after confirming all upstream deps are at their required status gates. This helps the Reviewer quickly verify ordering was respected.

### Lock Header Format

Every task file in `~/.salmon/Tasks/Working/` carries a Lock Header prepended by the Coder. The Header is always added **after** the complete batch move of all connascent files, and is prepended above the original content (which is never modified).

```markdown
**Lock**
- Agent: coding-1
- Locked: 2026-05-05T12:00:00Z
- Started: 2026-05-05T12:00:00Z
- Progress: 100%

**Validation**
- Tests: N/A — documentation-only change
- PACT: All passed
- DependsResolved: true
- Rollback: git revert <commit-hash>

**Deferred**
- Task 2: Manual — requires AWS console access
- Task 4: Blocked on upstream dependency

**Escalated**
- Task 3: Could not be completed after 2 attempts.
- Detail: Zoho API returned 429 rate limit on all retries.
<!-- doc-lint: exempt -->
- Manual task: `~/.salmon/Tasks/Manual/2026-06-10-zoho-rate-limit.md`
---
- Agent: coding-1
- Locked: 2026-05-05T12:00:00Z
- Released: 2026-05-05T14:00:00Z
- Status: released
- DependsResolved: true

[original session plan content — UNCHANGED]
```

The Lock Header fields:

| Field | Set by | Meaning |
|-------|--------|---------|
| `Agent` | Coder | The container identity that locked this task |
| `Locked` | Coder | ISO 8601 timestamp when the file was locked (primary staleness field; required). |
| `Started` | Coder | ISO 8601 timestamp when the task batch was moved to Working (may duplicate `Locked` for batch-locked files; accepted as staleness fallback). |
| `Progress` | Coder | Self-reported completion: **0% or 100%** only |
| `Escalated` | Coder | Task that could not be completed after 2 attempts. Includes detail, error, and manual task path. Added on second strike of escalation ladder. |
| `DependsResolved` | Coder | `true`/`false`. Set in the release block only when the plan has a `**DependsOn**:` field. Confirms all upstream deps are at their required status gates. |
| `Orchestrated` | Coder | `true` if spawned by an orchestrator (stream/namespace dispatch). Queue-drain agents omit this field. New orchestrators use this to detect orphaned agents from dead orchestrators. |
| `OrchestratorId` | Coder | Stream or orchestrator ID that spawned this agent (e.g., `stream-3`, `orchestrator-1`). From env `OC_STREAM_ID` or parent process detection. |
| `OrchestratorPID` | Coder | PID of the orchestrator process at agent launch time. Used by new orchestrators to determine if the parent orchestrator is still alive. |

**Chain verification**: During review, the Reviewer checks that Lock Header timestamps are consistent with the DependsOn ordering. If session X depends on session Y, then Y's Lock Header should show a `Released:` timestamp earlier than X's `Locked:` timestamp. If not, the Coder may have skipped ahead.
To assist manual verification, the Reviewer can run `Get-ConnascenceGroups.ps1 -AsTable -DepGraphOnly` to see a sorted timeline of lock/release events. Set in the release block only when the plan has a `**DependsOn**:` field. Confirms all upstream deps are at their required status gates. |

**Important**: The `Progress` field is only ever `0%` (initial lock) or `100%` (complete). There are no intermediate milestones. The Reviewer does **not** trust the Coder's self-reported progress — the Reviewer audits actual output against acceptance criteria and computes their own % complete.

### Atomic lock-header writes

**Lock-header prepends MUST be atomic (temp-write + `Move-Item`) and MUST verify the body survived; a header-only file is a bug, not a valid lock state.** Every prepend — coder, reviewer, and stream-wrapper paths — follows the same write-verify-then-commit sequence (implemented in `New-LockHeader.ps1` and the stream coders' batch-lock step):

1. Read the current full file content into `$body`.
2. Compose `$new = $headerBlock + newline + $body`.
3. Write to a temp file in the same directory, then `Move-Item -Force` over the target (atomic on the same volume).
4. **Verify**: re-read the written file and assert it still contains the original plan marker (e.g. `# Session Plan:`) AND `$new.Length -ge $body.Length`. If verification fails, restore from git (`git show HEAD:<path>`) and abort the lock with a loud `LOCK_WRITE_TRUNCATION` log event — never leave the truncated file.
5. Only after verification succeeds may the lock be committed/moved onward.

The reviewer Finale additionally verifies `$content.Length -ge 200 -and $content -match '# Session Plan:'` between the prepend and the `Move-Item` to `Tasks/Complete/`, so a truncated record can never be committed.

### Deferred tasks

If any tasks in a session plan cannot be completed (needs human action, blocked on dependency, out of scope), the Coder:

1. Keeps `Progress: 100%` if the workable tasks are done, or approximates a lower value if partial work was done (e.g. `Progress: 60%`).
2. Adds a `**Deferred**` section below the Lock bar listing which tasks were deferred and why.
3. Does **not** change, delete, or annotate the original task text below the `---` separator. The original session plan is a record and is immutable.

```markdown
**Deferred**
- Task 2: Manual — needs AWS console to create IAM role
- Task 4: Blocked — waiting on Session 3 dependency
```

### Connascence batch locking

When a project spans multiple session files, the Coder:

1. **Discovers** all connascent files in `~/.salmon/Tasks/Code/` by matching the same date+namespace prefix (e.g. `2026.05.05-proj-1-example.md`, `2026.05.05-proj-2-another.md`, `2026.05.05-proj-3-yet-another.md`).
2. **Batch move** — copies all of them to `~/.salmon/Tasks/Working/` simultaneously.
3. **Batch lock** — after the move, prepends the Lock Header to each file (same `Agent` and `Started` timestamp across all).
4. **Works through** each file individually, setting each to `Progress: 100%` when done.
5. **Moves** completed files to `~/.salmon/Tasks/Review/` as each reaches 100%.

### Stalled task detection

The sentry checks the `Locked` timestamp (falling back to `Started`) in Lock Headers inside `~/.salmon/Tasks/Working/`. If a file's `Progress` hasn't changed from `0%` in >5 minutes, sentry annotates it with `[STALLED]` and logs the event.

**Liveness-aware stall contract**: Before marking a file `[STALLED]` or releasing it back to `Tasks/Code/`, the sentry MUST check the lane/stream agent's heartbeat (`Tasks/Logs/agents/<agent-id>.heartbeat`). A file whose agent heartbeat is fresh (<5 min) belongs to a **live, mid-work agent** and must NOT be reset, regardless of `Locked` age or `Progress: 0%` — a slow-but-alive coder (reading target-repo code, running a long test suite) legitimately sits at `Progress: 0%` for >5 min. The sentry logs `LANE_HOLD` for skipped live lanes. The same contract applies to the orphan/rescue sweep (`Handle-OrphanStatus`/`Resolve-OrphanStatus` — never stamp `Released:` on a file whose agent process is alive) and to the lane-recovery path (`Invoke-LaneStateRecovery` — a lane with a live agent PID is never "recovered").

## Connascence

- **Internal connascence**: Files sharing the same date+namespace prefix. Must be batch-locked together.
  - **Smart connascence**: Within a namespace group, plans that modify **different files** (determined by the plan's `**Files:**` field) can run in parallel. Plans that share any target file path must be serialized. The orchestrator's `Build-ConnascenceGroups` splits namespace groups into independent subgroups by file-target overlap.

### Namespace independence

Sessions in different namespace prefixes (`A`, `B`, `C`, etc.) are **independent by default** — the orchestrator may dispatch them in parallel. Sessions in the same namespace prefix (`D-4`, `D-5`) are **sequential by default** — the second session waits for the first to be released.

A namespace prefix is the segment between the date prefix and the iteration number in the filename: `<date>-<namespace>-<iteration>-<description>.md` (the `<date>` separator may be `-` or `.`). It may be a multi-word token (e.g. `csbk-fe-dash`, `architectural-secrets`). The canonical extraction is the `Get-FileNamespace` function in `Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1` (and its module mirror in `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Connascence.ps1`) — use it rather than parsing by hand, so the result is deterministic and consistent with connascence grouping.

> This default is overridden by the `DependsOn` field (see Cross-namespace dependency below). A session in namespace Y that lists a dep on namespace Z session becomes blocked on Z even though they are different namespaces.

### MODIFIES vs REFERENCES (connascence only applies to modifications)

The `**Files:**` field is the single source of truth for what a plan changes. Connascence — the reason two plans cannot run in parallel — exists only when **both plans list the same file in `**Files:**`** (both MODIFY it). A plan that references a file in its task body (as evidence, context, or cross-reference) but does NOT list it in `**Files:**` is merely reading it — that is not a conflict.

**When auditing or batch-planning**: assign each plan to a namespace based on the files it MODIFIES (its `**Files:**` field), not the files it references as evidence. Two plans in different namespaces that both modify the same file should use `DependsOn` to express the dependency — do not merge the namespaces. See `session-plan-format.md § Namespace as Parallel Track` for the full convention.

### Cross-namespace dependency (DependsOn)

The `**DependsOn**:` field in a session plan lists `Namespace-Iteration` refs with a required status gate (`complete` or `reviewed`).

**Effect**: The orchestrator MUST NOT dispatch session X until every dep in X's DependsOn has been resolved to the specified status gate.

- **Resolved to `complete`**: The dep session's changes are committed in the working tree (`git log` on HEAD).
- **Resolved to `reviewed`**: The dep session's file is in `~/.salmon/Tasks/Complete/` (passed review).

Cross-namespace deps override the default parallel assumption. E.g., D-4 (namespace D) listing `A-1 (status: reviewed)` and `B-2 (status: reviewed)` means D-4 is blocked until both A-1 and B-2 are in `~/.salmon/Tasks/Complete/`, even though A and B are different namespaces.

Sessions with no `DependsOn` field are **root sessions** — they have no required ordering relative to any other session.

> **Transitive blocking**: If D-4 depends on A-1 and A-1 depends on nothing, the orchestration is straightforward. If A-1 had its own deps, those are automatically upstream of D-4 (transitive closure is the orchestrator's responsibility — see D-4 session plan).

### Dependency Matrix Pattern (for Planners)

A structured methodology for designing dependency graphs across multiple sessions. Planners should follow these steps when planning a batch of 3+ sessions.

**Step 1 — List all sessions**: Write down every session you plan to create. For each, describe in one line what it does.

**Step 2 — Identify dependencies**: For each session, ask: "Does this session require another session's output (changes, concepts, or reviewed status)?" Draw a directed edge from session → prior session.

**Step 3 — Assign namespaces**: Group sessions by file-level connascence. Use the letter-namespace convention:
- Sessions that touch disjoint file sets → different namespace → can run in parallel.
- Sessions that touch overlapping files → same namespace → run sequentially.
- Fan-in nodes (sessions with 3+ incoming deps) → prefer a separate namespace to signal they are a merge point.

**Step 4 — Assign iteration numbers**: Within each namespace, assign iteration numbers starting from 1. Use the `N-letter` convention where `N` is the global session number and `letter` is the namespace:
   `A-1` = session 1, namespace A
   `B-2` = session 2, namespace B
   `D-4` = session 4, namespace D
   This lets humans sort alphabetically and see both order and grouping.

**Step 5 — Write DependsOn**: For each non-root session, write its DependsOn field listing all upstream deps with the appropriate status gate (`reviewed` is safest; use `complete` only when the dep's changes are standalone and review is not required before proceeding).

**Step 6 — Validate**: Run the dependency graph through three checks: refs exist, no cycles, filenames match. For batches of 5+, also run `Invoke-ValidateDependencyGraph.ps1` (E-8).

**Rules of thumb**:
- **Same namespace** if: sessions touch overlapping files, or sessions form a tight sequential chain where no parallelism is desired.
- **Different namespace** if: sessions touch disjoint files AND have no logical ordering requirement.
- **New namespace for fan-in** if: a session has 3+ incoming deps (it is a coordination point — giving it its own namespace signals importance).
- **Avoid namespace proliferation**: If you find yourself using 7+ namespace letters for 9 sessions, reconsider — the overhead of managing many short namespaces may outweigh the parallelization benefit. Merge some that don't truly overlap.
- **Single-session namespaces are fine**: A namespace with one session (like `A: A-1`) is normal for independent root sessions.

**Worked Example: 9-session planmode cohort**

```
Sessions:
A-1: Add DependsOn field to session-plan-format.md
B-2: Update connascence sections in workflow-primitives.md
C-3: Add dep-graph validation to Planner workflow
D-4: Implement DAG-aware orchestrator dispatch
D-5: Add visualization (Mermaid + table)
E-6: Document dependency matrix pattern
E-7: Update Reviewer workflow with dep verification
E-8: Create validation tooling script
E-9: Update documentation

Dependency matrix:
        │ A-1  B-2  C-3  D-4  D-5  E-6  E-7  E-8  E-9
  ──────┼──────────────────────────────────────────────
  A-1   │  —    —    —    ✓    —    —    —    —    —
  B-2   │  —    —    —    ✓    —    ✓    —    —    —
  C-3   │  —    —    —    —    —    ✓    ✓    —    —
  D-4   │  —    —    —    —    ✓    —    —    —    —
  E-6   │  —    —    —    —    —    —    —    —    —
  E-7   │  —    —    —    —    —    —    —    —    —
  E-8   │  —    —    —    —    —    —    ✓    —    —
  E-9   │  —    —    —    —    —    —    —    ✓    —

Namespace assignment:
  A: A-1                  (independent, file: session-plan-format.md)
  B: B-2                  (independent, file: workflow-primitives.md)
  C: C-3                  (independent, file: workflow.md)
  D: D-4, D-5             (connascent: share Get-ConnascenceGroups.ps1)
  E: E-6, E-7, E-8, E-9  (connascent: share Planner/Reviewer workflows)
```

The matrix shows at a glance which sessions fan in to which. D-4 is a fan-in node (depends on A-1 and B-2). E-6 is a fan-in node (depends on B-2 and C-3). Flag these for special orchestrator attention.

**Boilerplate: dependency matrix for new plan batch**
Copy this template and fill in:

```
### Sessions
| Session | Description | Depends on | Namespace |
|---------|-------------|------------|-----------|
|         |             |            |           |

### Matrix (fill X for depends-on)
        │  ... column headers ...
  ──────┼──────────────────────────
         │
```

The matrix is optional for batches of 1-2 sessions. Required for batches of 3+.

- **External connascence**: Files from different sessions that modify overlapping files. Before implementing, check the plan's `Connascence` field and verify each entry is in `~/.salmon/Tasks/Complete/` (subfolder) or set to `None`. If any connascent work is still in `~/.salmon/Tasks/Review/` or loose in `~/.salmon/Tasks/Complete/`, **do not proceed** — log a `CONNASCENCE_BLOCK` event:
  ```powershell
  Write-WorkflowEvent -Type CONNASCENCE_BLOCK -Files @("<plan-file>") -Detail "connascent work in ~/.salmon/Tasks/Review/" -Phase "<mode>"
  ```
  Then either move the plan back to `~/.salmon/Tasks/Code/` (self-contained) or exit with code 11 (orchestrated).
- **Namespace reservation**: When a Coder picks up a connascent file (one sharing a date+namespace prefix with others), it MUST first call `Register-Namespace` for that prefix. If the reservation is held by another live agent, the Coder MUST skip — log a `CONNASCENCE_BLOCK` event. If the reservation succeeds, the Coder owns the entire namespace: no other agent will claim files with that prefix. The reservation is released when the Coder releases its last file in the namespace.
- **Lock-first batch claim**: Verify all connascent files exist, then call `Lock-File` for all filenames in the group. If all locks acquired, move all files together. If any lock fails, release all acquired locks and skip the group. Write a `FILE_LOCKED` event:
   ```powershell
   Write-WorkflowEvent -Type FILE_LOCKED -Files @("<locked-file>") -Detail "connascence group blocked by lock" -Phase "<mode>"
   ```
   - `Lock-File` internally retries every 200ms up to its `$MaxWaitMs` parameter. If the lock is never acquired within the timeout, the group is skipped entirely — the other agent holds the locks and will process the file.
   - After successful claim, proceed to step 4.
   - **DependsOn gate check**: Before calling `Lock-File` for a session plan, the agent MUST verify that all entries in the plan's `**DependsOn**:` field (if present) are resolved to their required status. If any upstream dep is not yet resolved, log a `CONNASCENCE_BLOCK` workflow event with `Detail 'Upstream dep not resolved: <dep-ref>'` and do NOT proceed. This applies even when the target session is in a different namespace from its deps.
- **Namespace reservation release**: The reservation is released via `Remove-NamespaceReservation` when the Coder releases its last file in the namespace (at the same time as releasing file locks).
4. **Lock** — prepend or append Lock Header per Lock Header format. After prepending, write a `CLAIM` event:
   ```powershell
   Write-WorkflowEvent -Type CLAIM -Files @("<moved-files>") -Detail "locked" -Phase "<mode>"
   ```
5. **Already-done detection** — Before reading or implementing, verify whether the plan's required changes are already committed. Extract every file path from the plan's `**Files:**` field. Run `git log --oneline --all -- <each-file>` or `git show HEAD:<key-file>`. If all changes are already in HEAD:
   - Note the commit hash in the Lock Header (e.g., `Already in HEAD: <hash>`)
   - Add a **Validation** block: `- Tests: N/A — already in HEAD`, `- PACT: Not run`, `- Remaining delta: None`
   - Set `Status: released`, add `Released: <now>`. Write a `RELEASE` event:
     ```powershell
     Write-WorkflowEvent -Type RELEASE -Files @("<plan-files>") -Detail "already in HEAD → ~/.salmon/Tasks/Complete/" -Phase "<mode>"
     ```
   - Move the file to `~/.salmon/Tasks/Complete/` (post-hoc plans are already merged; no review needed)
   - Return to Drain Queue / select next file
6. **Read** the lowest-iteration plan. Record `$fileStart = Get-Date` and `$planName`.

### Completed-plan usage header

Before any successful plan is moved into `Tasks/Complete/`—including post-hoc
fast-tracks and direct stream completion—the agent MUST dot-source
`Orchestrator/Orchestration/Add-PlanUsageMetadata.ps1` and call
`Add-PlanUsageMetadata` for the plan. The helper reads the local OpenCode
database read-only, aggregates matching session IDs by explicit session ID and
plan filename, and inserts the stable `**Usage**` block before the header
separator. The block contains `Provider`, `Harness`, `Model`, `Effort`,
`SessionId`, `Requests`, `Tokens`, `CostUSD`, and `Source`. If usage cannot be
resolved, it records `unknown`/`unavailable`; agents MUST NOT estimate or omit
the fields.

## Workflow Events Log (notification board)

An append-only JSONL notification board for cross-agent collision prevention and session visibility.

**File**: `~/.salmon/Tasks/Logs/workflow-events.log`
**Format**: One JSON object per line (`id`, `ts`, `agent`, `type`, `phase`, `files`, `detail`)
**Functions**: `Write-WorkflowEvent`, `Get-WorkflowEvents` (from `ORCHESTRATOR.Core`)
**Offset tracking**: Per-agent read offset stored in `~/.salmon/Tasks/Logs/.offsets/<agent-id>.offset`

**Event type catalog**:

| Type | Meaning |
|------|---------|
| `SESSION_START` | Agent session began |
| `CLAIM` | File(s) locked for processing |
| `RELEASE` | File(s) released after completion |
| `MOVE` | File(s) moved between task directories |
| `COMMIT` | Git commit made |
| `PUSH` | Git push completed |
| `CONNASCENCE_BLOCK` | Connascence prevented work |
| `FILE_LOCKED` | File was locked by another agent |
| `CONFUSION` | Unexpected file state discovered |
| `COMPACT` | Context memory compacted between plans |
| `RESCUE` | Stale/orphaned file rescued |
| `CLEANUP` | Stale task file purged (resurrected by git pull --rebase) |
| `HANDSHAKE` | Reviewer picks up Coder's file |
| `SIGN_OFF` | Completion Checklist completed; agent emits "Status: Completed" |

**Audit rotation**: `Write-WorkflowEvent -Clear` or `Get-WorkflowEvents -Clear` deletes the log and all offset files. Only the Auditor role performs rotation.

**Best-effort**: Both functions never throw on IO failure. If the log is unwritable, the agent proceeds silently.

### Writing events

```powershell
Write-WorkflowEvent -Type CLAIM -Files @("~/.salmon/Tasks/Working/plan.md") -AgentId "code-847-35" -Phase code
```

The function accepts `-Type` (event type), `-Files` (string[]), `-Detail` (free-text), `-AgentId` (defaults to `$env:OC_RESERVATION_AGENT_ID`), `-Phase` (agent role), and `-Clear` (switch to rotate).

### Reading events

```powershell
$events = Get-WorkflowEvents -AgentId "code-847-35"
foreach ($e in $events) { Write-Host "$($e.type): $($e.detail)" }
```

Returns only events appended since the agent's last read. Per-agent byte offset stored in `~/.salmon/Tasks/Logs/.offsets/<agent-id>.offset`. Returns `@()` if no new events or log missing.

### Integration touchpoints

Write calls must be added at the lifecycle points listed below. These are **not optional** — a session that omits events creates gaps that confuse other agents. Each subsequent section marks its write point with an inline `Write-WorkflowEvent` call.

## Shared Spec Change Protocol

When a session plan targets shared workflow files (including `workflow-primitives.md`):

1. **Try before rewrite** — Before any edit, execute the current documented behavior with an appropriate timeout. Use the bash tool's `timeout` parameter — it accepts arbitrary values (the 120s default is not a hard limit). If the behavior succeeds as documented, the premise for the change is invalid — stop, report "Documented behavior succeeded — change not justified", and skip the edit. Only proceed if the documented behavior actually fails.

2. **FENCE prompt** — Before implementing the edit, present the diff and rationale to the user for confirmation. Format:
   > This session changes shared workflow files. Reason: `<explanation>`. Diff: `<show diff>`. Proceed? (y/n)
   Wait for affirmative response before editing.

3. **Rollback plan** — In the Validation block, include `- Rollback: git revert <expected-commit-hash>` so the change is reversible by the next agent.

> **Note**: Workflow-specific sections (Coder, Reviewer, Planner, Rescue) have been extracted to their per-role `workflow.md` files under `Skills/Workflows/<role>/`.

## Stale-file pre-check (shared — all modes)

When a plan file moves from `~/.salmon/Tasks/Code/` → `~/.salmon/Tasks/Working/` (batch-lock) and the source deletion is not staged before commit, the next `git pull --rebase` restores the original in `~/.salmon/Tasks/Code/`. This manifests as a stale plan file that looks like valid pending work. **All modes** must run this pre-check before scanning their task directory.

### Logic

For each file in the mode's source directory (e.g. `~/.salmon/Tasks/Code/` for Coder, `~/.salmon/Tasks/Review/` for Reviewer, `~/.salmon/Tasks/Working/` for Rescue):

1. Extract the namespace prefix: the segment after the ISO date, up to the iteration field. Pattern: `^\d{4}\.\d{2}\.\d{2}-(?<prefix>[^-]+(?:-[^-]+)*?)-\d+.*` — `2026.06.20-architectural-1-loader-drift.md` yields prefix `architectural-1`.
2. Search the other live directories (`~/.salmon/Tasks/Working/`, `~/.salmon/Tasks/Review/`, `~/.salmon/Tasks/Complete/`) for a file with the same namespace prefix.
3. If a match exists in a directory other than the one being scanned:
   - The current file is stale (the match in the other directory is the live copy)
   - Delete it: `Remove-Item -LiteralPath "<path>" -Force`
   - Log: `Write-WorkflowEvent -Type CLEANUP -Files @("<path>") -Detail "stale-file-purged (live copy in <other-dir>)" -Phase "<mode>"`
   - Do NOT include it in the task scan

The pre-check runs **once at session start** (after agent identity registration, before scanning for work).

### Powershell snippet

```powershell
function Invoke-StaleFilePreCheck {
    param(
        [string]$ScanDir,
        [string[]]$LiveDirs = @("~/.salmon/Tasks/Working", "~/.salmon/Tasks/Review", "~/.salmon/Tasks/Complete"),
        [string]$Phase
    )
    $files = Get-ChildItem -LiteralPath $ScanDir -Filter "*.md" -File
    $liveDirsFull = $LiveDirs | ForEach-Object { Join-Path (Resolve-Path ".") $_ }
    foreach ($f in $files) {
        if ($f.Name -notmatch '^\d{4}\.\d{2}\.\d{2}-(?<prefix>[^-]+(?:-[^-]+)*?)-\d+') { continue }
        $prefix = $matches['prefix']
        $stale = $false
        foreach ($ld in $liveDirsFull) {
            if ((Get-ChildItem -LiteralPath $ld -Filter "*.md" -File | Where-Object { $_.Name -match "^\d{4}\.\d{2}\.\d{2}-$prefix-\d+" })) {
                $stale = $true; break
            }
        }
        if ($stale) {
            Remove-Item -LiteralPath $f.FullName -Force
            Write-WorkflowEvent -Type CLEANUP -Files @($f.Name) -Detail "stale-file-purged (live copy elsewhere)" -Phase $Phase
        }
    }
}
```

Call at session start after identity registration. Omit the mode's own directory from `$LiveDirs` — a Coder scanning `~/.salmon/Tasks/Code/` checks `Working/`, `Review/`, `Complete/` but NOT `Code/`.

## Complete CC (shared snippets)

Per-file commit/push actions are now part of each workflow's Finale step (not a separate Completion section). This section provides reusable code snippets used directly during Finale.

**Shared patterns**:

### Commit event
```powershell
$commitHash = (git rev-parse --short HEAD).Trim()
Write-WorkflowEvent -Type COMMIT -Files @("<staged-files>") -Detail $commitHash -Phase "<mode>"
```

### Push with git lock
```powershell
$gitLocked = $false
try {
    if (Get-Command Lock-File -ErrorAction SilentlyContinue) {
        $gitLocked = Lock-File -FileNames @("git.lock") -MaxWaitMs 60000
    }
    & (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] git pull --rebase had issues — manual resolution may be needed" -ForegroundColor Yellow
    }
    git push
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] git push failed — check remote state" -ForegroundColor Red
    }
} finally {
    if ($gitLocked -and (Get-Command Unlock-File -ErrorAction SilentlyContinue)) {
        Unlock-File -FileNames @("git.lock")
    }
}
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
Write-WorkflowEvent -Type PUSH -Detail "pushed $branch" -Phase "<mode>"
```

### Time reporting
```powershell
# Read session start from file if variable is not set (crash recovery)
$sessionStartFile = '~/.salmon/Tasks/Logs/session-start-' + ($env:OC_STREAM_ID ?? $env:OC_RESERVATION_AGENT_ID ?? $PID) + '.log'
if (-not $sessionStart -and (Test-Path $sessionStartFile)) {
    $sessionStart = [datetime]::ParseExact((Get-Content $sessionStartFile -Raw).Trim(), 'o', $null)
}
# Legacy fallback: sessions that wrote the unscoped shared file
if (-not $sessionStart -and (Test-Path '~/.salmon/Tasks/Logs/session-start.log')) {
    $sessionStart = [datetime]::ParseExact((Get-Content '~/.salmon/Tasks/Logs/session-start.log' -Raw).Trim(), 'o', $null)
}
if ($sessionStart) {
    $elapsedTotal = [math]::Round(((Get-Date) - $sessionStart).TotalSeconds, 0)
    $elapsedMinutes = [math]::Floor($elapsedTotal / 60)
    $elapsedSeconds = $elapsedTotal % 60
    Write-Host "Session elapsed: ${elapsedTotal}s, ${elapsedMinutes}m${elapsedSeconds}s"
}
if (Test-Path "$PWD\.session-timing.txt") {
    Get-Content "$PWD\.session-timing.txt" | ForEach-Object { Write-Host "  $_" }
}
```



## Post-Implementation Audit Hook

The Planner's sign-off is unique: it shapes what the Coder and Reviewer do *after* they finish implementing. The Planner must consider, in advance, what additional steps the Coder should take to prevent breaking changes, ensure first-try correctness, and audit the integrity of the code and the change footprint. Embed this guidance directly in the plan file as a `## Post-Implementation Audit` section so the Coder and Reviewer treat it as binding.

The Planner asks three questions and writes the answers into the plan:

1. **What grooming/refactor/integrity steps should the Coder perform after the primary implementation, to prevent breaking changes and ensure the code works with no errors immediately after coding?**
   Examples (non-exhaustive — tailor to the change):
   - Run all consumers of the changed API/module/script and confirm no regression
   - Re-run the most recent deploy / config / 1Deploy dry-run if the change touches the deployment pipeline
   - Refactor any near-duplicate code introduced by the change into a shared helper
   - Update or extend Pester tests covering both the change and adjacent code paths
   - Grep the codebase for stale references to renamed/removed symbols, modules, or files
   - Add inline comments at non-obvious decision points (no drive-by commentary)

2. **Are the documentation, Mermaid tables, and opencode agent libraries (`Skills/ORCHESTRATOR/Personas/<ROLE>/soul.md`, `tools.md`, `bootstrap.md`, `agents.md`, `identity.md`, `memory.md`, `system-prompt.md`, `heartbeat.md`) adequately managed after the code change?**
   - Update `docs/Reference/*.md` for any changed behaviour
   - Update `docs/Reference/Diagrams.md` for any changed workflow/data flow
   - Update the relevant role's agent template files (soul.md, tools.md, bootstrap.md, etc.) for any role whose behaviour or surface area changed
   - Update `opencode.json` command templates that reference changed sections
   - Update `docs/Glossaries/` for any new or changed domain terms

3. **Are there other areas that should be inspected or audited?**
   - Touched modules' dependency graph in `docs/Reference/Diagrams.md` — does the change alter it?
   - Connascence surface — does the change introduce or remove a shared-state relationship?
   - Secrets / IAM policies / credential flow — does the change alter any of these?
   - Tests that previously passed — do they still pass, and do they still represent the intended contract?
   - Environment variables, port registry, Docker secret bundles — are they consistent?

**The Coder is bound by the Post-Implementation Audit section.** A plan without this section is incomplete; a Coder that completes a plan with this section without performing its checks fails the sign-off step. The Reviewer audits whether the Post-Implementation Audit checks actually ran (test commands executed, doc updates landed, Mermaid diagrams re-rendered, soul/tools/bootstrap files updated as required).

**Goal of the Planner sign-off** — make sure that after the Coder and Reviewer are done implementing, the code works to the best of the Planner's ability. The Planner's job is not just to write tasks but to anticipate the second-order effects of the change and pre-empt them.

## Cowork Sign-Off: Final Handoff Completeness

The Cowork sign-off is a Final-Handoff-completeness check. The Cowork agent re-reads its handoff document and asks:

1. **Documentation completeness** — Is there any additional information (project state, gotchas, working patterns, dead-ends) that the next agent will need that is NOT in the handoff or its referenced docs? If yes, write it to `docs/<topic>.md` first, then re-reference it from the handoff.
2. **Tools completeness** — Are all scripts, helpers, commands, or shell one-liners the next agent will need listed in "Key Files" or "Tools & Approaches — What Worked"? Are the entry points (e.g., `. Skills/Workflows/Cowork/Scripts/New-X.ps1`) included?
3. **Helpful information** — Are there upstream/downstream documents, glossary entries, ADRs, or memory files the next agent should know about? Cross-link them.
4. **Orphan references** — Are there files referenced in the session that are NOT cross-referenced by any other repo document? Add them to "Orphan notes" so the next agent discovers them.
5. **Verification evidence** — Does every completed item have a `Verification` cell? (test pass / API output / command stdout / screenshot)
6. **Redirects / Deprecations** — If files moved or scripts retired during the session, is the old→new mapping recorded?

If the answer to any of these is "no", the Cowork agent updates the handoff/memory file before completing. The Cowork cannot report `Status: Completed` with an incomplete handoff — that defeats the purpose of the handoff and strands the next agent.

## Stop signal (graceful drain interrupt)

To tell a running agent to stop after it finishes its current file (interrupting its drain queue), place a stop-signal file:

| Signal | Scope | Lifetime | Cleanup |
|--------|-------|----------|---------|
| `~/.salmon/Tasks/stop` | **All modes** — every agent that checks stops | Self-cleaning — deleted by the last agent to stop | Automatic (PID tracking) |
<!-- doc-lint: exempt -->
| `~/.salmon/Tasks/stop.code` | Only Coder mode | One-shot — deleted by first Coder that respects it | Automatic |
| `~/.salmon/Tasks/Logs/.orchestrator-active` | Standalone Code/Review agents only (not stream agents) | Written by orchestrator at startup, deleted on exit; stale-cleanup by next orchestrator startup | PID-verified: if orchestrator PID is dead, treated as stale and cleaned |

<!-- doc-lint: exempt -->
`~/.salmon/Tasks/stop.review` and `~/.salmon/Tasks/stop.audit` follow the same one-shot pattern as `~/.salmon/Tasks/stop.code`.

The `.orchestrator-active` signal is unique: it is **emitted by the orchestrator** (not placed by a user) and **only standalone agents** (`$env:OC_STREAM_ID` unset) check for it. Stream and code-namespace agents skip this check — they are spawned by the orchestrator and should keep working. The file contains the orchestrator PID on the first line; if the PID is dead (orchestrator crashed), the file is treated as stale and cleaned, allowing standalone agents to proceed normally.

**Check order** (after Finale, before scanning for next file or entering drain queue):
1. Check `~/.salmon/Tasks/Logs/.orchestrator-active` — if present and orchestrator PID alive, standalone agents stop. (Built into `Invoke-StopSignalCheck.ps1`; skipped automatically for orchestrated agents.)
2. Check `~/.salmon/Tasks/stop.<mode>` — if found, delete it (one-shot), stop
3. Check `~/.salmon/Tasks/stop` — if found, handle via PID-based self-cleaning (below), then stop
4. Neither found → continue normally

**Script**: `Invoke-StopSignalCheck.ps1` at `Skills/Documentation/Scripts/Invoke-StopSignalCheck.ps1`. Dot-source and call it after Finale, before scanning for the next file or entering the drain queue:

```powershell
. (Resolve-Path "Skills/Documentation/Scripts/Invoke-StopSignalCheck.ps1")
if (Invoke-StopSignalCheck -Mode "code") { exit 0 }
```

The script returns `$true` if a stop signal was found and handled (mode-specific one-shot or global PID-based self-cleaning), `$false` if neither exists. When returning `$true`, it handles deletion, PID tracking, last-agent cleanup, and workflow events internally.

**PID-based self-cleaning** (for the global `~/.salmon/Tasks/stop`):
Each agent appends `agentId|PID|mode` to `~/.salmon/Tasks/stop`, then checks all entries. Any PID still alive via `Get-Process` (or heartbeat freshness for cross-container) means another agent hasn't stopped yet — the file stays. When no other PID is alive, the checking agent deletes the file. Result: the last agent to stop cleans up automatically.

**Cross-container safety**: Same-machine agents use `Get-Process` directly. For fleet containers on different hosts, the script falls back to heartbeat freshness — if `~/.salmon/Tasks/Logs/agents/<agent-id>.heartbeat` was written within the last 5 minutes, the agent is considered still alive.

**Usage examples**:
| Action | Effect |
|--------|--------|
| `New-Item ~/.salmon/Tasks/stop` | All running agents stop at next file boundary; last agent cleans up |
| `New-Item ~/.salmon/Tasks/stop.code` | Only Code agents stop (one-shot) |
| `New-Item ~/.salmon/Tasks/stop.code, ~/.salmon/Tasks/stop.review` | Stop Code AND Review agents (one-shot each) |

If a mode-specific signal is placed for a mode with no running agent, it stays on disk until the next agent of that mode picks it up — potentially stopping that agent before it starts its first file. To prevent this, only place mode-specific signals when agents of that mode are running.

## Drain Queue

Called **only** from [AGENTS.md CC step 11](AGENTS.md#completion-checklist) (Return to queue). The workflow's own Return to Queue step does NOT enter the Drain Queue — it scans for files and delegates all polling to this CC step. This ensures a single, unambiguous entry point for polling.

0. **Stop-signal gate** — Before any other work, check for a [stop signal](#stop-signal-graceful-drain-interrupt). Run before compaction to minimize delay between the signal and the exit.

1. **Compact memory after every plan** — Always compact memory after completing a plan, before scanning for the next one. No threshold check: compaction runs unconditionally. The opencode runtime's `"compaction": { "auto": true }` setting handles token-level context compression in the background; this step ensures the agent also contracts its own narrative context (summarizing what was done, what remains, and what was learned about the codebase). **First write a checkpoint** via `Write-SessionCheckpoint` (see `Skills/Documentation/Scripts/Write-SessionCheckpoint.ps1`) so the compaction is restorable, then compact, then re-orient from the checkpoint via `Restore-SessionCheckpoint`. After compacting, increment `$script:compactionCount++` (the checkpoint file is now the durable record of the count) and write a `COMPACT` workflow event: `Write-WorkflowEvent -Type COMPACT -Detail "memory compacted after plan" -Phase "<mode>"`.

2. **Context-gated exit** — Only exit with code 99 if compaction has been attempted 3+ times this session AND post-compaction context still exceeds 250K tokens or 40% of total context window (whichever is lower, one condition sufficient). Track compaction count in script scope (`$script:compactionCount`). Exit with code 99 only when `$script:compactionCount -ge 3`. With the checkpoint ritual (Drain Queue step 1) now providing lossless workflow compaction, most sessions never reach this exit — the ritual can compact repeatedly while preserving state. The exit 99 remains a safety valve for genuinely unrecoverable context size, not the primary pressure-relief path.

    Before exiting, **spawn a fresh-mode TUI**: launch a new terminal window with a completely fresh opencode session carrying no context and a mode-specific drain-queue prompt. This lets work continue seamlessly even without the orchestrator catching the exit code.

    1. **Detect your mode**: If you are following the [Code Workflow](Skills/Coder/SKILL.md), your mode is `code`. If you are following the [Review Workflow](Skills/Reviewer/SKILL.md), your mode is `review`.
    2. **Run the script**:
       ```powershell
       . (Resolve-Path "Skills/Workflows/Cowork/Scripts/Invoke-FreshModeSession.ps1")
       Invoke-FreshModeSession -Mode "<your-mode>"
       ```
       This opens `opencode --prompt "<Mode> Mode and drain queue"` in a new terminal window at the repo root.
    3. If the script errors (e.g., opencode not found, terminal launch fails), log the error but proceed — the exit 99 still triggers the orchestrator failover.

    On exit, write a `RELEASE` workflow event with `Detail: Context gate triggered after N compactions`, push any pending commits, and exit with code 99. The orchestrator treats exit code 99 as a graceful handoff and spawns a fresh agent. The goal is to keep the same agent working as long as possible — compaction before every plan means most sessions never reach the exit threshold.

3. **Select next file(s)** — List candidate files in the role's task directory, sorted alphabetically. Select the first file(s) whose Lock Header shows `Status: ready` (or no Lock Header). If connascent files share the same namespace, batch-select them all.
   - **Coder**: Check `~/.salmon/Tasks/Code/` for `.md` files (ignoring `.gitkeep`).
    - **Reviewer**: Check `~/.salmon/Tasks/Review/` for loose `.md` and `.log` files (ignoring `.gitkeep`). If empty, run the Complete/ Organization Pass once before entering the polling loop: list loose files at `~/.salmon/Tasks/Complete/*.md` (files not yet inside a namespace subfolder) and move each into a named subfolder matching its namespace prefix. Commit the moves if any were organized, then push using Invoke-GitPullSafe: `& (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push`.

4. **Dispatch or Poll** — If files were found, return to the relevant interactive workflow ([Code Workflow](Skills/Coder/workflow.md#code-workflow) or [Review Workflow](Skills/Reviewer/workflow.md#review-workflow)). Do NOT prompt. If no files found, check for a [stop signal](#stop-signal-graceful-drain-interrupt) before entering the poll loop (in case the signal was placed while you were processing the last file). If present, exit instead of polling. Otherwise, call the shared polling primitive. **Do NOT use a manual `Start-Sleep` loop** — the function handles cycle counting, sleep, and the terminal message:
   ```powershell
   . (Resolve-Path "Skills/Documentation/Scripts/Invoke-AgentPollingLoop.ps1")
   $tasksFound = Invoke-AgentPollingLoop -TaskDirectory "~/.salmon/Tasks/<RoleDir>" -RoleName "<role>"
   ```
   The function defaults to **10 consecutive idle cycles at 120s each (20 minutes total)**. Do not pass custom `PollIntervalSeconds` or `MaxIdleCycles` unless the task explicitly requires non-standard values — the 10×120s default is the canonical drain policy.
   - If `$tasksFound` is `$true` (files arrived during polling) → return to workflow step 1 to process them. After the workflow completes, its Return to Queue step will scan and find no files, then delegate back to CC step 11, which re-enters the Drain Queue (counter reset to 0).
   - If `$tasksFound` is `$false` (all 10 idle cycles exhausted) → report and return to CC step 12. The terminal message "Polling exhausted — no `<role>` tasks arrived in `<N>` min" is emitted by the function; CC step 12 then emits `Status: Completed`.
   - **Memory**: Do NOT compact memory on empty-poll cycles — only when actual work was done.
   - **Orchestrated mode**: When spawned by `LocalOrchestrator.ps1`, exit immediately — do NOT enter the polling cycle. `Invoke-AgentPollingLoop` is not called in this mode.

## Orchestrator dispatch (code-namespace / stream)

The orchestrator (LocalOrchestrator.ps1, VERI) dispatches subprocesses via `work-code`, `work-review`, `work-stream`, or `code-namespace`. Each subprocess processes one or more files and exits — the orchestrator manages the outer loop.

**code-namespace** (orchestrated namespace dispatch) = [Code Workflow](Skills/Coder/workflow.md#code-workflow) — Namespace Variant (5-phase workflow: Code Pass → Feedback Sweep → Wait Loop → Stop handling → Cleanup & Exit). Processes all plans in one namespace, handles review feedback, and exits only when the namespace is fully in ~/.salmon/Tasks/Complete/. The subprocess spans multiple cycles including poll-waiting for review; it handles its own lifecycle and does not return to the orchestrator until complete.

For interactive (non-orchestrated) agents, the workflow's Return to Queue step scans for files and delegates all further polling to [AGENTS.md CC step 11](AGENTS.md#completion-checklist), which enters this Drain Queue. Compact memory after each cycle that did actual work, then return to CC step 11 to re-enter the Drain Queue.

## Reservation-based claiming

When `$env:OC_RESERVATION_FILE` is set:

1. Verify the file still exists at its source path (`~/.salmon/Tasks/Code/` for coders, `~/.salmon/Tasks/Review/` for reviewers).
2. `Lock-File -FileNames @("<filename>")` — atomic claim via lock file. The orchestrator may have already acquired this lock before spawning the subprocess; in that case it succeeds immediately.
3. If lock acquired, `Move-Item -LiteralPath <source> -Destination "~/.salmon/Tasks/Working/<agent-id>/<file>" -ErrorAction Stop` to claim the file.
4. If lock fails (already locked by another agent or timeout), exit with code 10 (`ExitCodeFileLocked`).
5. After move succeeds, prepend your Lock Header, then proceed with [Code Workflow](Skills/Coder/workflow.md#code-workflow) step 2 onward (or [Review Workflow](Skills/Reviewer/workflow.md#review-workflow) for review claims).

## Manual Dispatch Signals (legacy flow)

Orchestrators can still dispatch agents directly by writing trigger files. This is a legacy pattern — server mode is preferred for HTTP-based dispatch, but legacy mode is supported for non-server scenarios.

### Dispatch Planner (Planning)
```
Write: <REPO_DIR>/~/.salmon/Tasks/Code/<session-plan>.md  (session plan to write)
Touch: <REPO_DIR>/~/.salmon/Tasks/Code/<session-plan>.md.trigger
```

### Dispatch Reviewer (Review)
```
Write: <REPO_DIR>/~/.salmon/Tasks/Review/<task>.md  (review instructions)
Touch: <REPO_DIR>/~/.salmon/Tasks/Review/<task>.md.trigger
```

### Dispatch Coding Agent (Implementation+Feedback)
```
Write: <REPO_DIR>/~/.salmon/Tasks/Code/<session-plan>.md  (copy of the session plan)
Touch: <REPO_DIR>/~/.salmon/Tasks/Code/<session-plan>.md.trigger
```
The Coder will pick it up from `~/.salmon/Tasks/Code/`, move to `~/.salmon/Tasks/Working/`, and prepend a Lock Header per the standard flow.

## Git lock (concurrent commit safety)

When multiple agents run in parallel (two interactive windows, LocalOrchestrator subprocesses, or VERI dispatch), two agents may try to commit and push simultaneously. Use the same file-lock primitive that protects task claims:

1. Before `git commit` or `git push`, call `Lock-File -FileNames @("git.lock") -MaxWaitMs 60000` (or the convenience function `Get-ORCHESTRATORGitLock -TimeoutMs 60000`).
2. If it returns `$false` (timeout), exit with code 12 (`ExitCodeGitLock`).
3. Run all git operations (add, commit, pull --rebase, push) inside a `try { } finally { }` block.
4. In `finally`, call `Unlock-File "git.lock"` (or `Remove-ORCHESTRATORGitLock`).

The lock file ~/.salmon/Tasks/Locks/git.lock is created atomically via `New-Item -ErrorAction Stop`. Two concurrent processes cannot both acquire it. If a process crashes while holding the lock, the file remains on disk but is harmless — it will be cleaned up by the next Rescue pass (which checks agent PID files).

This mechanism works identically across all three scenarios:
- **Interactive Windows**: Two pwsh.exe processes racing for the same NTFS file → one wins atomically.
- **LocalOrchestrator subprocesses**: Same machine, same NTFS → same guarantee.
- **VERI/mcp_opencode containers**: Docker bind mount on Linux → `O_CREAT|O_EXCL` provides the same kernel-level atomicity.

**Multi-agent safe-pull (`Invoke-GitPullSafe.ps1`)**: When running `git pull --rebase` during the Completion Checklist, use `Invoke-GitPullSafe.ps1` instead of `git pull --rebase --autostash`. This wrapper:
- Creates a transient `WIP: safe-pull-checkpoint-*` commit (instead of a stash, which can be silently dropped) so all in-flight changes — own and foreign — survive the rebase
- Excludes runtime lane files: `Tasks/Working/**` is unstaged before the checkpoint and never committed
- **Lane-file gate**: before creating the WIP commit, if `Tasks/Working/**` holds any lane files, the script exits 0 with a "tree busy" message and creates no WIP commit — a later run once lane state clears proceeds normally. This prevents `git pull --rebase` from aborting on unstaged lane files and leaking a WIP checkpoint to `origin/main`
- After the pull, undoes the WIP commit (`git reset --soft HEAD~1 && git reset`), restoring the original staging state; the undo also runs on the failure path (`finally`), so a failed pull never leaves a WIP commit at HEAD
- On rebase conflict, exits with a clear error message directing manual resolution (`git rebase --continue`, then reset the WIP commit)

This replaces the previous `Invoke-GitPullSafe` behavior that used `git stash drop` (safe for single-agent but destructive in multi-agent). See `Skills/DevOps/Git/Invoke-GitPullSafe.ps1` for implementation details.

## Multi-agent coexistence

> **Worktree override**: If `$env:OC_WORKTREE_PATH` is set, this section does not apply. See [§ Worktree Mode](#worktree-mode) instead. Agents in worktree mode work in isolation on their own branch and never contend with other agents.

Other Coder or Reviewer agents may modify the working tree before or during your session. **Before editing any file**, run `git show HEAD:<file>` to verify your intended change is not already committed. If the file was modified by another agent and you were not expecting it, write a `CONFUSION` event:
```powershell
Write-WorkflowEvent -Type CONFUSION -Files @("<file>") -Detail "expected state mismatch; found committed by another agent" -Phase "<mode>"
```
Before committing, run `git status` and `git diff` to verify you only changed files your own plan targeted. Stage per-file with `git add <file>` — never `git add -A` or `git commit -a`. Accept other agents' changes as-is. Before pushing, run `& (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push`.

**Stage source deletions alongside destinations**: When a plan file was moved from `~/.salmon/Tasks/Code/` to `~/.salmon/Tasks/Working/` (batch-lock) and then to `~/.salmon/Tasks/Review/` (Finale), stage the **deleted source paths** so `git pull --rebase` from concurrent agents does not restore the stale originals. This staging must happen immediately after the batch-lock move (before edits), and the stream coder should run `git add "~/.salmon/Tasks/Code/$planName"` right after `Move-Item` to `Tasks/Working/`. Without this, `~/.salmon/Tasks/Code/$planName` reappears in the working tree after every rebase, making the task look unprocessed. Pattern: `git add "~/.salmon/Tasks/Review/$planName"; git add "~/.salmon/Tasks/Code/$planName" 2>$null`.

> Never: update git config, skip hooks, force push to main, rebase/amend pushed commits. Never expose or log secrets.

## Worktree Mode

When agents operate in isolated git worktrees (one per stream, each on its own branch), many of the coexistence rules above are superseded. **This mode is active when `$env:OC_WORKTREE_PATH` is set.**

### Setup (orchestrator)
1. For each stream to dispatch, the orchestrator calls `New-AgentWorktree` to create a branch from `main` and a `git worktree add` at `~/.salmon/Tasks/worktrees/<streamId>/`.
2. The agent's working directory is set to the worktree path.
3. `$env:OC_WORKTREE_PATH`, `$env:OC_BRANCH_NAME`, and `$env:OC_STREAM_ID` are set in the subprocess environment.

### Agent workflow (in worktree mode)
1. `cd $env:OC_WORKTREE_PATH` — working directory is the worktree, not the repo root.
2. No other agent touches this worktree — zero file contention.
3. Standard implementation flow: read plan, implement tasks, stage per-file (`git add <file>`).
4. Commit: `git commit -m "<semantic prefix>: <summary>"`.
5. Push: `git push origin $env:OC_BRANCH_NAME` — no stash, no pull, no git lock.
6. Exit 0 when done.

### What changes from direct-to-main mode
| Aspect | Direct-to-main | Worktree mode |
|--------|---------------|---------------|
| Working directory | Repo root | `$env:OC_WORKTREE_PATH` |
| Push | `Invoke-GitPullSafe && git push` | `git push origin $branch` |
| Git lock | Required | Not needed |
| Stash | Selective stash of owned files | No stash needed |
| Foreign dirty files | Must coexist | None exist (isolated) |

### Merge pass (orchestrator)
1. After all streams complete, the orchestrator runs `Merge-AgentBranches`.
2. Branches are merged in connascence order (namespace sort).
3. `.gitattributes` union drivers auto-resolve most conflicts in task files, docs, and tests.
4. Genuine conflicts are left in their worktree; a merge-agent is dispatched.
5. After all merges succeed, worktrees are removed with `Remove-AgentWorktree`.

### Crash recovery
- If the orchestrator crashes mid-workflow, leftover worktrees remain on disk.
- `Invoke-Orchestrate.ps1` detects orphan worktrees on re-launch and offers to clean them.
- `New-AgentWorktree -Resume` detects existing worktrees and reuses them.

## Feedback loop — Coder processes reviewer feedback

1. **Start** — read the feedback file from `~/.salmon/Tasks/Code/` (see Session Startup step 3). Move to `~/.salmon/Tasks/Working/<agent-id>/` and prepend Lock Header with `Status: locked`.
2. **Execute** — implement every numbered fix. If any fix relates to a script error or test failure, **check the log files first** (`~/.salmon/Tasks/Logs/`, stderr) to diagnose root cause.
3. **Complete** — run the [Complete CC](workflow-primitives.md#complete-cc) (10 steps per the canonical section). In the Feedback loop context:
   - **Step 1 (Post-hoc / Verify)**: re-read the feedback file, confirm every numbered issue is addressed (or noted as Deferred)
    - **Step 2 (Pester)**: skipped — the Coder does not run tests; the Reviewer re-runs them after the fix is submitted
   - **Steps 3-7 (Docs, templates, stage, commit)**: required — same as interactive mode
   - **Step 8 (Clean tree)**: required
   - **Step 9 (Push)**: required
   - **Step 10 (Elapsed time)**: required
   - **Sign Off** does NOT run in the Feedback loop — the Reviewer picks up the feedback file in `~/.salmon/Tasks/Review/` and audits the fix; the Coder does not emit a Sign Off report here.

> **Compact CC**: The Feedback loop does not run Step 11 (Drain Queue) because the Coder is already in the middle of its main session. The loop's role is to address the Reviewer's feedback and re-emit the file for re-review.
4. **Finale** — add `Released: <now>` to Lock Header, set `Status: released` (add **Deferred** notes if any fixes remain), and move the feedback file to `~/.salmon/Tasks/Review/` for the Reviewer to verify. The feedback file in `~/.salmon/Tasks/Review/` is now a Reviewer task.
5. **Re-enter drain loop** — After Finale, return to [Drain Queue](#drain-queue). Polling is inherent to drain — if no files remain, the queue drains and polls until exhausted.

## Completion Signal

When all plans and feedback files for a task are fully complete:
- `~/.salmon/Tasks/Complete/` has all session files and feedback files for the task as **loose files**
- To signal 100% completion, the Reviewer groups them into a subfolder: `~/.salmon/Tasks/Complete/<date>-<namespace>/`
- A subfolder = the task is fully finished. Loose files = still in progress or partially complete.
- The grouped subfolder name omits the iteration number (e.g., `2026.05.02-session/` contains sessions 1-16)

This convention is implemented by the Reviewer during their Finale step (see § Review Workflow), but is documented here as a shared lifecycle signal.

## Process-First Resolution

Fixing the process is as important as completing the task. When you encounter friction — ambiguity, missing context, awkward tooling, unclear conventions, or a task shape that fights you — treat that as a first-class signal, not a distraction.

| Severity | What you see | What you do |
|----------|-------------|-------------|
| **Enhancement** | The task *could* be done, but it would be easier/faster/reliable if the approach, tooling, or instructions were different | Create a fork-stub (`~/.salmon/Tasks/Handoff/fork-stub-<date>-<topic>.md`) capturing the process issue and the improvement. Do NOT drop the task — complete it first (or defer it if blocked), then write the fork-stub. See [`Skills/Archive/workflow-cowork-fork.md`](Skills/Cowork/fork.md) for the Fork-Stub format. |
| **Blocking** | The task genuinely cannot complete under current process — wrong assumptions, missing prerequisite, broken tooling, circular dependency | **Fix the process first**, then iterate and resume the task. Do not attempt to work around the process — that produces fragile output and burns tokens. Examples: fixing a deploy script instead of patching state; correcting a session plan's approach before implementing; adding a missing step to a workflow document. |
| **Ambiguous** | Not sure if it's blocking or just annoying? | Treat as Enhancement. Complete the task, write a fork-stub. If the same friction surfaces again on another task, escalate to Blocking. |

### Fork-Stub format (for Enhancement cases)

A lightweight fork-stub at `~/.salmon/Tasks/Handoff/fork-stub-<date>-<topic>.md`:

```markdown
# Fork-Stub: <topic>

**Source**: <session plan or task file path>
**Date**: YYYY-MM-DD

**Goal**: Fix the process issue so future tasks in this area are easier.

**Process Issue**:
- What is wrong with the current approach, tool, or instruction
- Evidence: what you had to do manually, what confused you, what broke

**Proposed Fix**:
- How the process should work instead
- Which files/scripts/docs would need to change

**Context**:
- Any links, file paths, or command output that will help the process-fixer
```

### Notes

- Do **not** confuse this with the ordinary `**Deferred**` mechanism. Deferred tasks are work that could not be done within the session (blocked on dep, needs human action). Process-First issues are about *how* the work is structured — they demand meta-work (changing instructions, scripts, tooling, or workflow docs).
- The fork-stub is not a complaint — it is a structured artifact that makes the next agent or planner faster. It pays down friction.
- If you fix a Blocking process issue mid-task, update the Lock Header's **Deferred** section to note what process fix was applied (e.g. "Fixed: updated deploy.ps1 Phase 3 to handle missing config key instead of crashing — was blocking task 2").

## Changelog

- 2026-07-14: Documented `(?m)` regex multiline bug — `$` matches before `\n` even with `\s*` consuming whitespace, capturing next line as "inline" content. Fix: omit `(?m)` for single-line checks. Documented `return @($result)` unrolls single-element arrays in PowerShell function return; use `return ,$result` (unary comma) to preserve. Documented dot-source guard pattern to prevent main-body `-match` from polluting `$matches` at script scope.
- 2026-06-16: Documented `Register-Namespace` parameter names (`-NamespacePrefix` and `-AgentId`, NOT `-Namespace` and `-MaxWaitMs`) — agents writing bootstrap scripts must use the correct names. Documented `Lock-File` and `Unlock-File` signatures (`-FileNames <string[]>` for both; `-MaxWaitMs 5000` is optional on `Lock-File`). Captured the connascent batch flow as it actually worked: `Register-Namespace` for each namespace → `Lock-File` for each filename → move remaining files from `~/.salmon/Tasks/Code/` to `~/.salmon/Tasks/Working/` → add Lock Header to moved files → fill empty `Agent:` field in existing files via `[regex]::Replace(... Multiline)`.
- 2026-07-07: Cross-reference sweep for Security Audit deprecation — no stale references found (file contains no mentions of "security-audit" or "Security Audit").

