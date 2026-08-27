# Skill: RunFix LocalOrchestrator

**Purpose**: Drive the orchestrator to drain **all three queues** (`Tasks/Code/`, `Tasks/Review/`, `Tasks/Working/`) cleanly and completely. The orchestrator must emit `exit 0` and leave zero `.md` files across all three queues with evidence that work meaningfully flowed through the pipeline.

**Target**: `Skills/Orchestrator/LocalOrchestrator.ps1`

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

---

## Defining Success

The orchestrator is not just a script that exits 0. Success means the full lifecycle completed:

### A) Work flowed through the pipeline
Plans progressed `Tasks/Code/` → `Tasks/Working/` (locked by agent) → `Tasks/Review/` (released by coder) → `Tasks/Complete/` (approved by reviewer). The completed plans in `Tasks/Complete/` are the **evidence** that work was meaningfully and actually completed, not skipped or incorrectly routed.

### B) Plans show correct cross-agent information
Completed plans in `Tasks/Complete/` must have Lock Headers showing the proper chain of possession — each plan was touched by a Coder agent (who implemented it) and a Reviewer agent (who audited it). The Lock Header fields (`Agent:`, `Status:`, `Released:`) should reflect this sequence.

### C) Clean terminal state
When the orchestrator finishes, all three queues must be empty, all subagents must have exited gracefully (no stale PIDs, no crash residue), and post-session cleanup must have been run. A queue that is empty because the orchestrator crashed early (and never processed any work) is **not** success — the queues must be empty AND work must have been completed (see criterion A).

---

## Two invocation paths

| Path | Entry point | Use case |
|------|-------------|----------|
| **Watchdog** (recommended) | `Invoke-Orchestrate.ps1` | Launches `LocalOrchestrator.ps1` in detached mode, then enters a persistent watchdog loop that checks all three queues every 3 minutes, re-launches on crash, cleans stale agents, and reports success. Use for normal /work usage. |
| **Direct** | `LocalOrchestrator.ps1` | Runs synchronously. No auto-recovery. Use for RunFix debugging when the watchdog fails and deeper fixes are needed. |

**Watchdog behavior** (`Invoke-Orchestrate.ps1`):
- Launches orchestrator detached
- Sleeps `$WatchIntervalSeconds` (default 180 = 3 min) between checks
- Reads `.orchestrator-pid` to track real orchestrator PID
- Checks all three queues + agent fleet status on each cycle
- On orchestrator crash with work remaining: rescues Working/ files to Code/Review/, clears lock artifacts, re-launches
- On stale agents: kills and cleans PID files
- On rogue agents (>2h): flags with warning
- On no-progress: warns if queues unchanged between cycles
- On orchestrator exit + all queues empty: prints summary, exits 0
- On stop signal or max cycles: exits 1

---

## Configuration

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Orchestrator/Orchestration/Invoke-Orchestrate.ps1` |
| `$FLAGS` | `-DetachWatchdog -Executor local -CodeParallelCount 10 -ReviewerParallelCount 10` | Other executors: `local-platform` (opencode serve on host), `platform` (container-to-container HTTP to mcp_opencode). > Terminal checks: Executor `local` skips AWS SSO and Docker checks. Executors `local-platform` and `platform` run all checks. |
| `$LOG_PREFIX` | `runfix-localorchestrator` |
| `$CHECKPOINT_RESUME` | `false` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `720` |
| `$TIMEOUT_SECONDS` | `300` |
| `$LOG_CHECK_GLOB` | `Tasks/Logs/orchestrator-*-structured.log` |

### How it works

The RunFix loop calls `Invoke-Orchestrate.ps1 -DetachWatchdog` repeatedly (60 max cycles):

- **Cycle 1** — No watchdog running. The script launches a hidden watchdog process that runs the full monitor/recover/report loop, then exits quickly. The script prints `Watchdog launched in background` and `Queues: Code=N ...` then `exit 0`. The rubrics check: exit 0 OK, but queues not empty → cycle repeats.

- **Cycle 2–N** — Watchdog already running. The script checks queues, reports them, and exits 0. If queues are still non-empty it prints `Work still in progress (waiting...)`. Rubrics fail → cycle repeats.

- **Final cycle** — Queues empty. Script prints `All queues empty — orchestrator complete` and exits 0. All rubrics pass → SUCCESS.

No cycle launches a second watchdog — the single-instance enforcement prevents it.

---

## Safety Protocol — Process Killing

**Never kill `opencode` processes.** The user runs interactive opencode sessions concurrently with the orchestrator. Any process that spawns `opencode` (as stream agents do) must be tracked via PID files so the orchestrator can kill only its own spawned subprocesses. Never use time-range or name-based process filters that could catch user-owned sessions.

When cleaning stale agents: only kill PIDs found in `Tasks/Logs/agents/*.pid` files that you can verify as your own spawns (by checking the agent registration log `SUBAGENT_SPAWN`). If a PID is in an agent file but the process name is `opencode`, warn and skip — it may be a user session that inherited the PID file from a prior crash.

---

## Preflight

Before running the orchestrator, verify:

1. **opencode CLI available** — `Get-Command opencode.cmd` or `opencode` resolves
2. **Working/ directory clean** — no stale `.md` files outside stream directories; run `Rescue-OrphanedLocks` or clean manually
<!-- doc-lint: exempt -->
3. **GracefulStop/stop signals absent** — no stale `Tasks/stop`, `Tasks/stop.code`, `Tasks/Logs/.orchestrator-stop`
4. **No stale orchestrator locks** — `Tasks/Logs/.orchestrator-pid` either absent or PID is dead
5. **Tasks/Code/ and Tasks/Review/ have work** — if empty, RunFix has nothing to do
6. **Watchdog not running** — kill any stale `orchestrator-watchdog.ps1` processes if re-entering RunFix. Also check `Tasks/Logs/.orchestrate-watchdog-pid` — if the PID is dead, remove the file to allow a new watchdog to start.
7. **Check file retry budget** — inspect `Tasks/Logs/file-retry-budget.json` for quarantined files; clear the budget if starting fresh
8. **Clean zombie stream dirs** — `Get-ChildItem Tasks/Working/stream-*` should be empty; remove dirs with no `.md` files
9. **Check Sentry schedule files** — `Get-ChildItem Tasks/Schedule/*.json` should contain only intentionally pending files. The Sentry container's audit cycle, rescue-stalled-plans, and CI poller are gated behind schedule files — if stale schedule files exist with `status: pending`, they will trigger unwanted agent dispatch. Clear stale schedules by setting their status to `"completed"` or removing them. Also `git rm --cached` any schedule files that should not be restored by `git pull`

---

## Rubrics — RunFix LocalOrchestrator

| # | Criterion | Passing condition |
|---|-----------|-------------------|
| 0 | Success signal | Log contains `All queues empty` |
| 1 | Exit code | `$LASTEXITCODE -eq 0` |
| 2 | All queues empty (terminal) | `Tasks/Code/` has zero `.md` files AND `Tasks/Review/` has zero `.md` files AND `Tasks/Working/` has zero `.md` files (excluding `.gitkeep`). This is the **only** terminal success criterion — no short-circuit allowed. |
| 3 | No orphaned locks | `Tasks/Working/` contains no subdirectories with files |
| 4 | No crash residue | No stale agent PID files in `Tasks/Logs/agents/` |
| 5 | No crash-loop pattern | Orchestrator did not enter catch block (main loop crash) |
| 6 | No stall timeout | Orchestrator did not hit stall limit |
| 7 | No cycling files | No file in Code/ has appeared in 3+ consecutive orchestrator runs |
| 8 | No self-generating plans | `fix-stale-orchestrator-cleanup.md` not regenerated if already completed |
| 9 | Graceful agent exit | All spawned subagents exited with exit code 0 — no crashed or stale agents remain |
| 10 | Completed work exists | If work existed in queues at start, at least one plan in `Tasks/Complete/` has a Lock Header showing the proper chain of possession (`Agent: coder-*` followed by a Reviewer lock) |
| 11 | Post-session GC ran | No stale PID files, no zombie stream dirs, no stale orchestrate-watchdog-pid |
| 12 | No agent crashes | Log does not contain `CRASH_EVIDENCE:` — if an agent crashed, RunFix must investigate the root cause and fix the source code before re-launching |
| 13 | No orchestrator ERRORS/WARNs | Orchestrator structured log has no `ERROR` or `WARN` level entries in the last 50 lines — if errors persist across consecutive cycles, RunFix flags them and triggers diagnosis |
| 14 | Rescue scan | If `Tasks/Failed/` contains files with retry_count < 3, rescue to `Tasks/Code/` |
| 15 | Completed plan integrity | No plan in `Tasks/Complete/` has retry_count == 3 with `lastExitCode != 0` |
| 16 | No max-fail misclassification | No plans in `Tasks/Complete/Failed/` — any that exist are rescued back to `Tasks/Code/` |

### Verification

```powershell
function Invoke-OrchestrateRubrics {
    param([string]$OutputText)
    $failures = @()

    # --- Terminal state checks ---

    # 1. All queues empty
    $codeFiles = @(Get-ChildItem "Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $reviewFiles = @(Get-ChildItem "Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $workingDirs = @(Get-ChildItem "Tasks/Working/*" -Directory -ErrorAction SilentlyContinue)
    $workingHasFiles = @($workingDirs | Where-Object {
        (Get-ChildItem "$($_.FullName)/*" -File -ErrorAction SilentlyContinue).Count -gt 0
    }).Count

    if ($codeFiles.Count -gt 0 -or $reviewFiles.Count -gt 0 -or $workingHasFiles -gt 0) {
        $failures += "Criterion 2 - Queues not empty: $($codeFiles.Count) code, $($reviewFiles.Count) review, $workingHasFiles working"
    }

    # 3. No orphaned locks
    if ($workingHasFiles -gt 0) {
        $failures += "Criterion 3 - Orphaned locks: files remain in Working/ subdirectories"
    }

    # 4. No crash residue
    $agentFiles = @(Get-ChildItem "Tasks/Logs/agents/*.pid" -ErrorAction SilentlyContinue)
    if ($agentFiles.Count -gt 0) {
        $failures += "Criterion 4 - Stale agent PID files: $($agentFiles.Count) file(s)"
    }

    # 5. No crash-loop
    if ($OutputText -match 'MAIN_LOOP_CRASH') {
        $failures += "Criterion 5 - Orchestrator crashed: main loop exception detected in output"
    }

    # 6. No stall
    if ($OutputText -match 'STALL_LIMIT') {
        $failures += "Criterion 6 - Orchestrator stalled: stall limit reached"
    }

    # 7. No cycling files
    $retryBudget = Join-Path $PSScriptRoot ".." ".." ".." "Tasks" "Logs" "file-retry-budget.json"
    if (Test-Path $retryBudget) {
        $budget = Get-Content $retryBudget -Raw | ConvertFrom-Json
        $cyclers = $budget.PSObject.Properties | Where-Object { $_.Value.retries -ge 2 }
        if ($cyclers) {
            $failures += "Criterion 7 - Cycling files detected: $($cyclers.Count) file(s) with 2+ retries"
        }
    }

    # 7b. Check for quarantined files
    $quarantined = @(Get-ChildItem "Tasks/Complete/Failed/*.md" -ErrorAction SilentlyContinue)
    if ($quarantined.Count -gt 0) {
        $failures += "Criterion 7 - Quarantined files: $($quarantined.Count) file(s) in Tasks/Complete/Failed/"
    }

    # --- Evidence of meaningful work ---

    # 10. Completed work with proper lock header chain
    $completedPlans = @(Get-ChildItem "Tasks/Complete/**/*.md" -Recurse -ErrorAction SilentlyContinue)
    $hasValidChain = $false
    foreach ($plan in $completedPlans) {
        $content = Get-Content $plan.FullName -Raw
        if ($content -match 'Agent:\s*coder-' -and $content -match 'Status:\s*released') {
            $hasValidChain = $true
            break
        }
    }
    # Only fail criterion 10 if work existed at start (queues weren't empty pre-run)
    $hadWorkAtStart = $false
    if ($null -ne $script:initialCodeCount -and $script:initialCodeCount -gt 0) { $hadWorkAtStart = $true }
    if ($null -ne $script:initialReviewCount -and $script:initialReviewCount -gt 0) { $hadWorkAtStart = $true }
    if ($hadWorkAtStart -and -not $hasValidChain -and $completedPlans.Count -eq 0) {
        $failures += "Criterion 10 - No completed plans found with proper lock header chain (work existed at start but none completed)"
    }

    # 11. Post-session GC
    $stalePids = @(Get-ChildItem "Tasks/Logs/agents/*.pid" -ErrorAction SilentlyContinue)
    $zombieDirs = @(Get-ChildItem "Tasks/Working/stream-*" -Directory -ErrorAction SilentlyContinue)
    $watchdogPid = Test-Path "Tasks/Logs/.orchestrate-watchdog-pid"
    if ($stalePids.Count -gt 0 -or $zombieDirs.Count -gt 0 -or $watchdogPid) {
        $gcFailures = @()
        if ($stalePids.Count -gt 0) { $gcFailures += "$($stalePids.Count) stale PID(s)" }
        if ($zombieDirs.Count -gt 0) { $gcFailures += "$($zombieDirs.Count) zombie stream dir(s)" }
        if ($watchdogPid) { $gcFailures += "stale watchdog-pid file" }
        $failures += "Criterion 11 - Post-session GC incomplete: $($gcFailures -join ', ')"
    }

    # 12. No agent crashes — CRASH_EVIDENCE is a hard failure requiring investigation
    $evidenceMatches = [regex]::Matches($OutputText, 'CRASH_EVIDENCE:\s*(\S+)\s*->\s*(\S+)')

    # 14. Rescue scan — move files from Tasks/Failed/ back to Tasks/Code/
    $failedDir = "Tasks/Failed"
    if (Test-Path $failedDir) {
        $failedFiles = @(Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue)
        if ($failedFiles) {
            $rescued = 0
            $budgetPath = "Tasks/Logs/file-retry-budget.json"
            $budget = @{}
            if (Test-Path $budgetPath) {
                try { $budget = Get-Content $budgetPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue } catch {}
            }
            foreach ($f in $failedFiles) {
                $retryCount = if ($budget.ContainsKey($f.Name)) { $budget[$f.Name].retries -as [int] } else { 0 }
                if ($retryCount -lt 3) {
                    $null = New-Item -ItemType Directory -Path "Tasks/Code" -Force
                    Move-Item -LiteralPath $f.FullName -Destination (Join-Path "Tasks/Code" $f.Name) -Force -ErrorAction SilentlyContinue
                    $rescued++
                    $failures += "Criterion 14 - Rescued $($f.Name) from Tasks/Failed/ (retry_count=$retryCount)"
                }
            }
            if ($rescued -eq 0) {
                $failures += "Criterion 14 - Files remain in Tasks/Failed/ with retry_count >= 3 — manual review needed: $(($failedFiles | ForEach-Object { $_.Name }) -join ', ')"
            }
        }
    }

    # 15. Completed plan integrity
    $completedPlans = @(Get-ChildItem "Tasks/Complete/**/*.md" -Recurse -ErrorAction SilentlyContinue)
    foreach ($cp in $completedPlans) {
        $content = Get-Content $cp.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'retry.*3|max.*fail|quarantine') {
            $failures += "Criterion 15 - Plan may be falsely completed: $($cp.Name)"
        }
    }

    # 16. No max-fail misclassification
    $cfailedDir = "Tasks/Complete/Failed"
    if (Test-Path $cfailedDir) {
        $cfailedFiles = @(Get-ChildItem "$cfailedDir/*.md" -ErrorAction SilentlyContinue)
        if ($cfailedFiles) {
            $rescued = 0
            foreach ($f in $cfailedFiles) {
                $null = New-Item -ItemType Directory -Path "Tasks/Code" -Force
                Move-Item -LiteralPath $f.FullName -Destination (Join-Path "Tasks/Code" $f.Name) -Force -ErrorAction SilentlyContinue
                $rescued++
                $failures += "Criterion 16 - Rescued $($f.Name) from Tasks/Complete/Failed/"
            }
            if ($rescued -eq 0) {
                $failures += "Criterion 16 - Files remain in Tasks/Complete/Failed/ — manual review needed"
            }
        }
    }

    if ($evidenceMatches.Count -gt 0) {
        $crashDetails = @()
        foreach ($match in $evidenceMatches) {
            $crashDetails += "$($match.Groups[1].Value) at $($match.Groups[2].Value)"
        }
        $failures += "Criterion 12 - Agent crash detected: $($crashDetails -join '; ')"
    }

    return @{
        Passed   = $failures.Count -eq 0
        Failures = $failures
    }
}
```

---

## Phase 2 — Error Table

| # | Error symptom | Root cause | Fix | Files changed |
|---|---|---|---|---|
| 1 | `Get-ConnascenceGroups.ps1` parse error at startup, orchestrator crashes | `[PSCustomObject]@{}` with inline if-expressions throws PowerShell parser error | Wrapped call in try/catch; rewrote `Format-DepStatusTable` without inline if syntax | `LocalOrchestrator.ps1`, `Get-ConnascenceGroups.ps1` |
| 2 | Coder subprocess exits non-zero (subprocess-crash); counter stays at 0 | `Spawn-StreamCoder` used `cmd.exe /c opencode run...` — cmd.exe masks exit codes, creates orphan process layer | Direct `Start-Process` with opencode path — no cmd.exe wrapper; exit codes propagate cleanly | `LocalOrchestrator-Worker.ps1` |
| 3 | Orchestrator crashes on stall limit; all active streams rescued and lost | `Invoke-StallDetection` used `throw "Stall limit reached"` — unhandled throw triggered outer catch | Return `StallLimitReached` bool from function; caller does `break` on the main loop instead of throwing | `LocalOrchestrator-LoopHelpers.ps1`, `LocalOrchestrator.ps1` |
| 4 | Healthy streams falsely rescued (heartbeat stale) | 5-minute heartbeat threshold too tight; `HasExited` race on Windows causes lag | Raised threshold to 15 min; added 10s re-check before declaring stale; added 3s wait before reading ExitCode after HasExited | `LocalOrchestrator.ps1` |
| 5 | Only 1 coder stream runs at a time while 5 reviewers run; Code queue never drains | `Get-DynamicCapacity` shared the same slot pool for coders and reviewers; proportional allocation gave coders 1 slot with 62:20 queue ratio | Decoupled pools: coders get up to `CodeParallelCount` slots, reviewers get up to `ReviewerParallelCount` slots; no sharing | `LocalOrchestrator-LoopHelpers.ps1` |
| 6 | Stream count inflated by empty zombie dirs | Orchestrator crashes left stream-* dirs in Working/ with 0 files; `Get-TaskCounts` counted them | Auto-clean empty stream dirs at startup; skip dirs with 0 `.md` files | `LocalOrchestrator.ps1` |
| 7 | `fix-stale-orchestrator-cleanup.md` regenerated every orchestrator startup | `Clear-StaleOrchestratorFiles` generates plan on stale log detection; no dedup check | Before generating, check if same-named plan exists in Code/, Review/, Complete/, or was committed (git log check) | `LocalOrchestrator-LoopHelpers.ps1` |
| 8 | `fix-stale-orchestrator-cleanup.md` regenerated every startup | `Clear-StaleOrchestratorFiles` generates this plan on every instance of stale logs; no dedup | Same dedup check before generation | `LocalOrchestrator-LoopHelpers.ps1` |
| 9 | Files cycle forever (struct1test-* etc.): dispatch → crash → rescue → re-dispatch | No retry budget; each failed attempt returns the file to Code/ with no backoff | Added `file-retry-budget.json` tracker (`Get-FileRetryBudget`, `Increment-FileRetry`, `Reset-FileRetry`); after 3 retries, file is quarantined to `Tasks/Complete/Failed/` | `LocalOrchestrator-LoopHelpers.ps1` (new functions), `LocalOrchestrator.ps1` (rescue paths) |
| 10 | "Already in HEAD" files returned to Code/ queue instead of Complete/ | Stream finds no changes needed, exits 0; sentinel-watch loop moves files back to role destination | Scan plan Lock Headers for `Already in HEAD:` before routing; matching files go to `Tasks/Complete/` instead. Fallback to legacy `stream.log` for backward compat. | `LocalOrchestrator.ps1` (sentinel-watch + failed-stream rescue) |
| 11 | `$remediation` variable referenced but never defined in `Invoke-StallDetection` | Copy-paste error: `KAIZEN_STALL_REMEDIATION` log referenced `$remediation.action_taken` from outer scope | Replaced with literal values `action=stopping resolved=$false` | `LocalOrchestrator-LoopHelpers.ps1` |
| 12 | Orchestrator exits (max iterations) but no auto-restart; queues remain | No heartbeat/monitoring outside the orchestrator process | `orchestrator-watchdog.ps1`: polls every 2 min, detects dead orchestrator, rescues orphan files, relaunches; runs for configurable max runtime (default 480 min) | `Tasks/Logs/orchestrator-watchdog.ps1` (new file) |
| 13 | No visibility into stream agent exit codes | No agent tracking; orchestrator shows "0 processed, 0 crashed" | `Invoke-StreamTracker.ps1`: monitors agent stdout logs, extracts exit codes, heartbeat ages, completion status; logs to `stream-tracker.log` | `Orchestrator/Orchestration/Invoke-StreamTracker.ps1` (new file) |
| 14 | Orphaned files in Review/ never re-dispatched — stall loop kills orchestrator | `Handle-OrphanStatus` moves files back to Review/ but never clears `$script:usedNamespaces`, so dispatcher always skips them as already-assigned | Added `$script:usedNamespaces.Remove($File.Name)` in both branches of `Handle-OrphanStatus` | `LocalOrchestrator-Worker.ps1` |
| 15 | Sentinel-watch writes `.complete` to stream directory that Phase B already deleted | Race between Phase B (completed-streams handler removes stream dir, writes sentinel, removes from activeStreams) and sentinel-watch (started before Phase B in same iteration, has stale reference to stream) | Added `Test-Path $stream.Path` guard before any sentinel or process-exit operations; skip and remove stale entry if dir gone | `LocalOrchestrator.ps1` |
| 16 | Detach mode args silently dropped — `$scriptArgsJoined` empty, subprocess runs with defaults | PowerShell operator precedence: `... | ForEach-Object {} -join ' '` parses `-join` as parameter to `ForEach-Object` (`RemainingScripts`) instead of array-join operator | Wrapped pipeline in parentheses `(...)` before `-join` | `LocalOrchestrator.ps1` |
| 17 | `$IdleTimeoutMinutes` referenced in idle-wait logic but not declared in `param()` — variable `$null`, causes `$idleElapsed -ge $null` to silently fail and never idle-exit | Missing parameter definition | Added `[ValidateRange(1, 480)][int]$IdleTimeoutMinutes = 30` to param block; forwarded in detach re-launch args and Invoke-Orchestrate passthrough | `LocalOrchestrator.ps1`, `Invoke-Orchestrate.ps1` |
| 18 | Duplicate plan files appear mid-RunFix: old-style (`domain-6-77.md`) and new-style (`domain6-77.md`) coexist with same content | Sentry container auto-triggers audit cycle and rescue-stalled-plans on every loop iteration, writing plan files independently of `Tasks/Schedule/`. Also: `Get-FileNamespace` regex uses `\.` (literal dot) which doesn't match hyphen dates, so filenames like `2026-06-21-domain6-77.md` extract namespace `2026` instead of `domain6`, causing all files to be grouped in one stream | (1) Gate all Sentry auto-actions behind explicit schedule files in `Invoke-SentryEntrypoint.ps1` (remove unconditional `Invoke-SentryAuditCycle`, `Rescue-StalledPlans`, `Start-SentryCiFailurePoller` calls). (2) Fix `Get-FileNamespace` regex: `\d{4}\.\d{2}\.\d{2}` → `\d{4}[-.]\d{2}[-.]\d{2}`. (3) `Convert-FindingsToPlans.ps1` was replaced by `Write-SessionPlan.ps1` (shared skill) with semantic namespaces. (4) Update plan file `**Namespace**:` headers to match filenames. (5) `git rm --cached Tasks/Schedule/*.json` to prevent `git pull` from restoring deleted schedule files | `Invoke-SentryEntrypoint.ps1`, `Start-SentrySchedulePoller.ps1`, `Start-SentryCiFailurePoller.ps1`, `LocalOrchestrator-FileHelpers.ps1`, `Get-ConnascenceGroups.ps1`, all plan files |
| 19 | Plan files with new-style namespaces (`domain6`) still produce old-style filenames during orchestrator run | Plan file headers still contain `**Namespace**: domain-6` (old style). When processes read the header to construct output filenames, they generate old-style names that `Get-FileNamespace` extracts as a different namespace | Bulk-update all plan file headers: `**Namespace**: domain-6` → `**Namespace**: domain6` | All plan files in `Tasks/Code/` and `Tasks/Review/` |
| 20 | Watchdog detects stalled queues — no progress across 3+ consecutive cycles | Orchestrator alive but not making progress. Possible causes: file retry budget exhausted without quarantine, concurrency deadlock, planned tasks depend on unplannable work (DependsOn cycle), or `Get-DynamicCapacity` allocating 0 slots due to workload miscalculation | Check `Get-DynamicCapacity` workload ratios. Inspect `file-retry-budget.json` for cycling files. Verify DependsOn graph is acyclic. Re-run with `-CodeParallelCount` increased. | `LocalOrchestrator-LoopHelpers.ps1`, `file-retry-budget.json` |
| 21 | Watchdog watchdog-pid collision — second instance refused | Another orchestrate watchdog process is already monitoring. Either a previous watchdog is still running legitimately, or a stale `Tasks/Logs/.orchestrate-watchdog-pid` file references a dead PID | Kill stale watchdog (check PID from `.orchestrate-watchdog-pid`) and remove file, or wait for the active watchdog to complete. | `Invoke-Orchestrate.ps1` |
| 22 | Orchestrator stalls with coder_workload>0 but refuses to dispatch — `usedNamespaces` cache prevents re-dispatch of files that moved between Code/ and Review/ | When a reviewer stream completes and moves files to Code/ (for coder fixes), the `Phase B completed-stream` handler only clears `$script:usedNamespaces` for files in **Review/**, not Code/. Files that transitioned from reviewer output to coder input remain locked in `usedNamespaces` and never get dispatched. | In both `Phase B completed-stream` and the `exit-0-failed-stream` sub-handler, add a second namespace-based clear for `Tasks/Code/*.md` matching the stream namespace. | `LocalOrchestrator.ps1` (Phase B completed-stream handler + exit-0 sub-handler) |
| 23 | Orchestrator silently fails to start — watchdog keeps re-launching every 3min but Working/ stays empty | `LocalOrchestrator.ps1` had a parser error (orphaned `} catch {` at line 1188 with no matching `try`). Hidden PowerShell window swallowed the error. | Remove orphaned catch block and extra closing brace. Add pre-launch AST syntax check in `Invoke-Orchestrate.ps1`, startup `trap` in `LocalOrchestrator.ps1` that writes `.orchestrator-init-error`, and structured JSONL watchdog log. | `LocalOrchestrator.ps1`, `Invoke-Orchestrate.ps1` |
| 24 | `CRASH_EVIDENCE:` marker appears in watchdog output — a subagent (coder or reviewer) crashed. RunFix must investigate the root cause before re-launching. | A subprocess exited unexpectedly, was killed by timeout, or its heartbeat went stale. The crash evidence directory (printed with the marker) contains the agent's stdout, stderr, log, PID, and heartbeat files. | **Mandatory investigation and fix** (not just cleanup): (1) Read crash evidence files at the path printed after `->` in the CRASH_EVIDENCE line — start with `crash-summary.json`, then the agent's `.log` and `.stderr`. (2) Identify root cause: is it a code bug, timeout, resource exhaustion, or protocol error? (3) Apply source fix to the affected code (most often `LocalOrchestrator-Worker.ps1` or `Invoke-Orchestrate.ps1`). (4) If fix cannot be determined, **write a plan** to `Tasks/Code/` that describes the crash pattern, what was found in the evidence, and what needs fixing — AND also document the pattern as a new error table entry so RunFix can auto-detect it next time. (5) Only then re-launch the watchdog. | `Invoke-Orchestrate.ps1`, `LocalOrchestrator-Worker.ps1` (depends on cause) |
| 25 | Orchestrator dies silently — no `ORCHESTRATOR_EXIT` or crash entry in structured log. Watchdog sees `orchAlive=False` with no diagnostic. | Unhandled exception in the main loop (e.g., `[int]` cast on non-numeric PID content) terminates the PowerShell process immediately. No `trap` or `catch` records the exception before exit. | Add `trap` at the top of `Start-Orchestrator` that writes `ORCHESTRATOR_FATAL_CRASH` to structured log. Add `Register-EngineEvent` handler for `PowerShell.Exiting` that logs `ORCHESTRATOR_EXIT_UNEXPECTED`. | `Start-Orchestrator.ps1` |
| 26 | Watchdog re-launch budget exhausted by mutex conflicts — orchestrator never actually crashed | A stale orchestrator (different PID) holds the named mutex. The new orchestrator can't acquire it and exits. Watchdog sees `orchAlive=False` after 15s, declares `ORCHESTRATOR_CRASH`, increments reload count. After 5 such false crashes, watchdog exits permanently. | Before declaring `ORCHESTRATOR_CRASH`, check `.orchestrator-active` for a live PID different from the intended one. If found, kill the stale orchestrator, clean lock artifacts, re-launch WITHOUT incrementing reload count. Reset reload count on successful launch. | `Invoke-Orchestrate.ps1` |
| 27 | Empty agent ID in crash evidence directory — evidence dir named `-20260706-213112` (dash + timestamp) | `Get-AgentFleetStatus` matches a `.pid` file with empty base name (just `.pid` with no prefix). `$agentId` is empty string. `Preserve-CrashEvidence -AgentId ""` creates a directory with no agent prefix. | Add guard in `Get-AgentFleetStatus`: skip PID files with empty or whitespace-only base names. Remove the offending file. | `Invoke-Orchestrate.ps1` |
| 28 | Duplicate crash evidence directories for the same agent — two dirs within 6 seconds | The orchestrator's sentinel-watch detects a failed stream and writes crash evidence. The watchdog's stale-agent pass detects the same stream's PID file moments later and writes evidence again. No dedup check exists. | Add dedup check in `Preserve-CrashEvidence`: check if evidence dir matching `{AgentId}-*` already exists before creating a new one. | `Invoke-Orchestrate.ps1` |
| 29 | `MaxNewStreamsPerIteration` capped total active streams at 2 regardless of `CodeParallelCount` | `Get-DynamicCapacity` computed `$existingNewThisIter = $ActiveCoder + $ActiveReviewer` (all active streams), subtracting from `MaxNewStreamsPerIteration=2`. Once 2 streams were active, `newSlotBudget=0`, blocking ALL new streams. | Raised default to 10. Changed calculation to not subtract total active — `newSlotBudget` is just `MaxNewStreamsPerIteration`. | `Capacity.ps1` |
| 30 | RunFix.ps1 terminal checks (AWS SSO, Docker) false-positive for `-Executor local` | `Test-TerminalConditions` unconditionally checks AWS SSO and Docker. For `-Executor local` targets, these services are not needed. SSO timeout causes RunFix to abort mid-session. | Gate AWS SSO and Docker checks behind executor detection from goals file `$FLAGS`. Only run when executor is `platform` or `local-platform`. | `RunFix.ps1` |

---

## Interaction with User

If the root cause of an orchestrator failure is not clear from the error table, batch any questions and ask the user. Common questions: whether to increase timeouts, change parallel counts, adjust connascence grouping, or clear the file retry budget.

---

## Related Files

| File | Purpose |
|------|---------|
| `Orchestrator/Orchestration/Invoke-Orchestrate.ps1` | Watchdog entry point — launches orchestrator detached, monitors all 3 queues every 3 min, re-launches on crash |
| `Skills/Orchestrator/LocalOrchestrator.ps1` | Legacy wrapper — delegates to `Start-Orchestrator` from `SalmonRun.Orchestrate` module |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Public/Start-Orchestrator.ps1` | Main orchestrator entry point — loop, dispatch, monitoring, rescue |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Cleanup.ps1` | Capacity allocation, stall detection, stale cleanup, file retry budget |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Orphan.ps1` | Orphan lock rescue, crash recovery, agent outcome tracking |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Process.ps1` | Process tree helpers, PID lock, heartbeat, startup rescue |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/RetryBudget.ps1` | File retry budget tracker |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Stream.ps1` | Stream directory management |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Queue.ps1` | Fleet status queries (Get-TaskCounts, Get-AgentFleetStatus) |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Connascence.ps1` | File namespace extraction, DependsOn graph helpers |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/State.ps1` | Filesystem state recovery and reconciliation |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Private/Capacity.ps1` | Dynamic capacity allocation, crash throttle |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Executors/Local.ps1` | Local executor — spawns stream subprocesses |
| `Orchestrator/Modules/SalmonRun.Orchestrate/Executors/local-platform.ps1` | Local-Platform executor — connects to local `opencode serve` HTTP API on localhost:21001 |
| `Orchestrator/Orchestration/Get-ConnascenceGroups.ps1` | Dependency graph and connascence grouping |
| `Orchestrator/Orchestration/Invoke-StreamTracker.ps1` | Live agent exit code monitor |
| `Tasks/Logs/orchestrator-watchdog.ps1` | Legacy auto-relaunch watchdog (superseded by Invoke-Orchestrate.ps1) |
| `Tasks/Logs/.orchestrate-watchdog-pid` | Watchdog PID lock file — prevents duplicate watchdogs |
| `Tasks/Logs/file-retry-budget.json` | Per-file retry counter (auto-generated) |
| `Tasks/Complete/Failed/` | Quarantine for files exceeding retry budget |
<!-- doc-lint: exempt -->
| `docs/Reference/Sentry-Architecture.md` | **(DEPRECATED)** Sentry dispatch architecture — schedule-gating design. Replaced by `is-fleet` and the host-side local orchestrator. |
| `Tasks/Schedule/` | Schedule files that gate Sentry's audit cycle, rescue, and CI poller actions |
| `Tasks/Logs/crashes/` | Crash evidence directory — per-agent subdirectories with stdout, stderr, log, PID, and heartbeat files preserved at crash time. Created by `Preserve-CrashEvidence` in the watchdog. RunFix uses these for root cause investigation. |

## Changelog
- 2026-07-06: Added error rows 25-30 for orchestrator silent crash, mutex conflict budget exhaustion, empty agent ID, duplicate crash evidence, MaxNewStreamsPerIteration cap, and RunFix terminal check gating
