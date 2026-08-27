## Code Workflow

### Prerequisites (<10s)
- [ ] Identity registered (PID file, heartbeat, agent registration)
- [ ] Orchestrator context detected (`$script:orchestrated` set; OrchestratorId/OrchestratorPID captured if applicable)
- [ ] **Stale-file pre-check**: Run `Invoke-StaleFilePreCheck -ScanDir "Tasks/Code" -LiveDirs @("Tasks/Working", "Tasks/Review", "Tasks/Complete") -Phase code` (from `workflow-primitives.md` § Stale-file pre-check). Run once per session (guard with `$script:stalePreCheckDone`).
- [ ] **Pre-claim conflict check**: Before locking, verify the plan file is still at its source path (`Tasks/Code/`). If it has already been moved to another agent's `Tasks/Working/<agent-id>/` folder, release it from your to-do list — the other agent holds it. Skip to next item.
- [ ] File lock acquired for plan file (Lock-File, or Register-Namespace for connascent groups)
- [ ] **Record start branch** — capture `$script:sessionStartBranch = (git rev-parse --abbrev-ref HEAD).Trim()` in the target repo and record it in the Lock Header so the pre-commit branch guard can detect branch switches.
- [ ] Plan file read and verified
- [ ] Re-groom check: if task touches 2+ files or shared surfaces, re-explore target files (30s)


### Stream Variant
When running as a persistent stream coder (`opencode run --command work-stream`):

- **File discovery**: List `.md` files in `Tasks/Working/stream-<id>/` (from `$env:OC_STREAM_ID`). Do NOT scan `Tasks/Code/` — the orchestrator pre-placed your files.
- **Connascence**: All files in your stream directory share the same namespace. Process them sequentially — they are not safe to parallelize.
- **Logging (one-file principle)**: The session plan file's Lock Header is the canonical log. After each file, update the Lock Header with orchestrator fields (if orchestrated) and write a CLAIM/RELEASE workflow event. Do NOT write a separate `stream.log` — the plan file plus workflow events together provide the full life cycle record.
- **Stop signal**: Before processing each file AND before each poll cycle, check for a stop signal. Stream agents are orchestrated and skip the orchestrator-active check (because `$env:OC_STREAM_ID` is set):
  ```powershell
  . (Resolve-Path "Skills/Documentation/Scripts/Invoke-StopSignalCheck.ps1")
  if (Invoke-StopSignalCheck -Mode "code") { exit 0 }
  ```
- **Polling exit**: After processing all visible files, sleep 30s and re-scan. Before each re-scan, check stop signal first. If no new files after 5 consecutive empty polls, write a SESSION_END workflow event, clean up PID/heartbeat, and exit 0.
- **No `OC_RESERVATION_FILES`**: The stream coder ignores reservation env vars. Files are placed in its directory by the orchestrator.

### Lean mode
Activated by `**Lean**: true` in the plan header, or by setting `$env:ORCHESTRATOR_LEAN=1`.

When active:
- **Compact status output**: Replace multi-line status blocks with single-line summaries. Skip `Write-ParallelSectionHeader` and `Write-ParallelSectionSummary` calls — use `Write-SetupLog` directly with condensed messages.
- **Lazy-load references**: Do not pre-load large reference files. Load them only when the workflow step explicitly needs content.
- **Skip verbose logging**: Omit DEBUG-level log lines. Keep INFO-level and above.
- **Compress heartbeat/ping output**: Omit heartbeat text body; write only the timestamp.
- **Test output**: Use `--PassThru | ConvertTo-Json -Compress` for Pester results instead of multi-line output.


### Namespace Variant — full lifecycle for one namespace

When running as a namespace pass (`opencode run --command work-code-namespace`), the Coder commits to the complete lifecycle of a single namespace: implement all plans, process review feedback, and exit only when every file in the namespace reaches Tasks/Complete/.

**Agent identity**: Use agent ID format `code-ns-<random>-<filetime>` (distinct from `code-*` for regular drain-loop coders). This helps orchestrators and other agents identify namespace-specific sessions.

**Namespace selection**: Scan Tasks/Code/, group by namespace prefix. Filter to namespaces where every DependsOn entry is resolved at its required gate. Select the first eligible namespace alphabetically.

**Batch claim**: Register-Namespace for the prefix. Lock-File for every file in the group. Move all files to `Tasks/Working/<agent-id>/<namespace>/` simultaneously. Prepend Lock Header to each using the atomic write pattern in `workflow-primitives.md § Atomic lock-header writes` (temp-write + `Move-Item` + verify the plan body survived; for simple Cowork plans use `New-LockHeader.ps1`).

**DependsOn resolution rule**: Same-namespace alone implies only sequential coding order — not review-waiting. Plans proceed back-to-back unless an explicit `DependsOn` entry at the `reviewed` gate blocks them. The `DependsOn` field is the **only** signal for review-waiting.

**Status log (one-file principle)**: The session plan files' Lock Headers are the canonical record. Additionally, write a lightweight `namespace-status.json` at `Tasks/Working/<agent-id>/<namespace>/namespace-status.json` as a summary convenience (updated after every cycle). Fields: `namespace`, `agent_id`, `phase` (code-pass | feedback-sweep | wait-loop), `files_in_review` (array), `files_deferred` (array), `files_complete` (array), `cycle_count`, `elapsed_seconds`, `last_updated`. This sidecar is not the primary log — all execution provenance lives in the plan Lock Headers and workflow events.

**Five-phase workflow**:

1. **Code Pass** — Sort files by iteration number. For each file:
   - Check all DependsOn entries (cross-namespace and within-namespace):
     - Any at `reviewed` gate and dep not yet in Complete/? -> mark **deferred**, skip
     - All at `complete` gate or absent? -> code immediately
    - Implement per Code Workflow -> Pester tests -> Validation block -> Lock Header `Status: released` -> move to Review/ -> commit & push
    - **Compaction** — Between plans, compact context: summarize completed work (files changed, key decisions, deferred items), flush working memory of plan-specific details, then load the next plan's file fresh. Use the handoff skill (`Skills/Cowork/handoff.md`) to produce an in-session summary. Re-read the next plan's file to avoid stale context.

2. **Feedback Sweep** — After Code Pass completes, scan Tasks/Code/ for feedback files belonging to this namespace. Process each batch:
   - Move to Working/, prepend Lock Header using the atomic write pattern in `workflow-primitives.md § Atomic lock-header writes`
   - Implement fixes -> test -> Lock Header `Status: released` -> move to Review/ -> commit & push

3. **Wait Loop** (max 30 cycles x 120s = 60 min):
   Each cycle:
   a. Check Tasks/Code/ for new feedback -> process immediately per Feedback Sweep
   b. For each deferred plan whose DependsOn `reviewed`-gate deps are now in Complete/:
      - Implement -> test -> release -> Review/ -> commit & push
      - Check Tasks/Code/ for feedback again -> process immediately
   c. Check if ALL namespace files (original plans + feedback) are in Tasks/Complete/ -> break
   d. Update `namespace-status.json`
   e. Sleep 120s

   If 30 cycles expire without completion: write a **Deferred** note into each remaining file's Lock Header, release namespace reservation, move `namespace-status.json` to Tasks/Logs/, delete Working/ folder, and exit.

<!-- doc-lint: exempt -->
4. **Stop signal handling** — If `Tasks/stop.code` or `Tasks/stop` is detected during the Wait Loop, finish the current feedback or deferred-plan batch, write deferred notes for remaining files, release namespace reservation, move log to Tasks/Logs/, delete Working/ folder, exit gracefully. (Stop signal is checked at the start of each cycle using `Invoke-StopSignalCheck.ps1`.)

5. **Cleanup & Exit** — When namespace is fully in Complete/:
   - Remove-NamespaceReservation
   - Move `namespace-status.json` to Tasks/Logs/
   - Delete `Tasks/Working/<agent-id>/<namespace>/`
   - Clean up PID/heartbeat
   - Report elapsed time with per-file breakdown
   - Exit 0

**Poll-on-no-namespace**: If no namespace in Tasks/Code/ has all its DependsOn resolved, enter a poll loop checking every 120s (up to 10 cycles) for newly eligible namespaces. Update `namespace-status.json` each cycle with `phase: awaiting-namespace`. If one becomes available, select it and enter Phase 1 (Code Pass). If 10 cycles expire, exit 0.

### Workflow
1. **Execute** — implement each task per the session plan. Log at INFO, edits at DEBUG.
   - If modifying shared files, follow the Shared Spec Change Protocol first.
   - If ambiguity surfaces, ask the user — do not guess.
   - **Predictive compaction via checkpoint ritual** — If token budget >= 100K or >= 10% of the context window, run the checkpoint-compact-restore ritual (see the `/checkpoint` command template in `opencode.json`) BEFORE starting the plan, to avoid mid-plan loss. The ritual persists workflow state to disk first, so compaction is lossless with respect to workflow position. (Skip when lean is active — lean assumes the agent manages its own context budget.) Threshold 100K/10% inherited from prior convention.
   - **Failure handling** — when a task cannot be completed:
       1. **First strike**: Log the failure detail in memory. Re-read the relevant task description and target files (re-groom). Retry once with the new context. If it succeeds, append a `Re-groom note` to the commit message (see re-groom rule above).
       2. **Second strike**: If the retry also fails, escalate — append to the Lock Header:
          ```markdown
          **Escalated**: Task <N> could not be completed after 2 attempts.
          Detail: <specific error, stack trace, or blocking ambiguity>
          Manual task: `Tasks/Manual/<date>-<slug>-<problem>.md`
          ```
          Write the manual task file with:
          - Originating context (plan file path, task number)
          - Exact failure detail
          - Suggested approaches (what was tried and failed, what remains to try)
          - Expected outcome
       3. **Exception — re-groom mismatch**: If step 1's re-groom reveals a fundamental plan-vs-codebase mismatch (per existing "Escalation rule" at bottom of workflow), escalate immediately to second strike — do not retry. Surface to user with the two options from the existing rule.
 2. **Nurture+Secure passes** (optional — gated by plan header):
   Read the plan header. If `**Nurture**: true` is set:
   - Grep for `TODO`, `FIXME`, `HACK`, `XXX` in changed files (`git diff --name-only HEAD`). File P0/P1 issues.
   - Check test coverage: compare changed functions/modules against existing Pester test files. File missing-test items.
   - Check doc drift: if any changed file has a corresponding `.md` doc, verify it still describes the API correctly.
    - Fix all P0 issues, fix P1 issues where trivial (<3 lines).
    If `**Secure**: true` is set:
    - Run secrets scan over changed files: `grep -rn -E '(api[_-]?key|secret|password|token|credential)\s*['':]='` on diff files.
    - Check for injection vectors: eval/Invoke-Expression with user input, SQL concatenation, command injection.
    - Check for hardcoded credentials in committed files.
    - Fix critical and high-severity findings immediately.
   Log results: `Write-SetupLog "NURTURE results=<N> fixed, <N> deferred"` and `Write-SetupLog "SECURE results=<N> fixed, <N> deferred"`.
   Any deferred items go into the Lock Header's Validation block as "Remaining delta".
   (When lean is active: skip verbose result formatting; log one line `NURTURE: fixed=N deferred=M SECURE: fixed=N deferred=M`)
 3. **Write Validation block** — insert into Lock Header:
    ```markdown
    **Validation**
    - Tests: <N> written (not run — Reviewer runs during audit)
    - Remaining delta:
      - None — all tasks complete
    ```
 4. **Finale** — update Lock Header: `Released: <now>`, `Status: released`, add **Deferred** notes if any. Release locks, write `RELEASE` + `MOVE` events. Move plan to `Tasks/Review/`. Record per-file timing. Then verify clean tree, stage, commit, and push:

   ```powershell
   Unlock-File -FileNames @("$planName")
   Write-WorkflowEvent -Type RELEASE -Files @("$planName") -Detail "released → Tasks/Review/" -Phase code
   Write-WorkflowEvent -Type MOVE -Files @("$planName") -Detail "Tasks/Working/<agent-id>/ → Tasks/Review/" -Phase code
   Move-Item -LiteralPath "Tasks/Working/<agent-id>/$planName" -Destination "Tasks/Review/$planName" -Force
   Remove-Item "Tasks/Working/<agent-id>" -Force -ErrorAction SilentlyContinue
   $elapsed = [math]::Round(((Get-Date) - $fileStart).TotalSeconds, 0)
   Add-Content -Path "$PWD\.session-timing.txt" -Value "$planName: ${elapsed}s"
   ```

    ```powershell
    # Pre-commit branch guard: ensure we are still on the branch observed at session start
    $startBranch = if ($null -ne $script:sessionStartBranch) { $script:sessionStartBranch } else { (git rev-parse --abbrev-ref HEAD).Trim() }
    $currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($currentBranch -ne $startBranch) {
        Write-WorkflowEvent -Type CONFUSION -Detail "branch switched from $startBranch to $currentBranch" -Phase code
        throw "Branch guard violation: expected $startBranch, found $currentBranch; resolve via checkout/cherry-pick before committing"
    }

    # commit and push the plan and any other files modified during the session
    git add "$planName"
    # Also stage the deletion of the original source path (Tasks/Code/ or Working/ copy)
    # so that git pull --rebase from other agents does not restore the stale source file.
    git add "Tasks/Code/$planName" 2>$null  # may already be deleted; ignore if absent
    git commit -m "$planName"
    $commitHash = (git rev-parse --short HEAD).Trim()
    Write-WorkflowEvent -Type COMMIT -Files @("$planName") -Detail $commitHash -Phase code
    & (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push
    Write-WorkflowEvent -Type PUSH -Detail "pushed" -Phase code
    ```

   (When lean is active: compress the Lock Header update to a one-liner status instead of elaborated Validation block.)
 4b. **Target-repo integration merge** — If the session modified a target repo (not salmon-orchestrator), the work is NOT done until the feature branch is merged to that repo's integration branch. This step runs AFTER the plan-file commit (step 4) but BEFORE returning to queue (step 5).

   **Why**: salmon-orchestrator uses `main`-only, but target repos (e.g. currentsbk.ca) use gitflow-lite where `dev` is the integration trunk. A feature branch with finished work that sits unmerged is invisible to CI, invisible to other agents, and invisible to the promotion path. The currentsbk.ca `AGENTS.md` says: "A feature branch with finished work that sits unmerged is not 'done'."

   **Procedure**:
   0. **Worktree isolation** — If another live lane already has the target repo's main checkout locked, create a per-lane git worktree for this lane: `git worktree add <repo>/wt/<lane> <integration-branch>`. Operate from that worktree and never run `git checkout -b` in a shared checkout. The stream `OC_WORKTREE_PATH` already isolates salmon-orchestrator; target repos require the same per-lane treatment when shared.
   1. **Detect the target repo's branch convention** — Read the target repo's `AGENTS.md` for a "Branching model" or "Branch convention" section. If it says `gitflow-lite` → the integration branch is `dev`. If it says `main`-only → the integration branch is `main`. If no `AGENTS.md` exists, default to `main`.
   2. **Run the target repo's verify gate** before merging — check the target repo's `AGENTS.md` for the gate command list (e.g. currentsbk.ca: `npm run typecheck && npm run test:fe && npm run test:backend && npm run audit && npm run verify:diag-off`). All must pass. If any fails, STOP — do not merge. Report the failure.
   3. **Merge the feature branch to the integration branch** from the correct worktree. For gitflow-lite repos, this is the dev worktree (e.g. `C:\Repos\currentsbk.ca-dev`): `git merge --no-ff <feature-branch>`. For main-only repos, merge from the main clone.
   4. **Push the integration branch** — `git push origin <integration-branch>`. For gitflow-lite repos, do NOT use the safe-pull wrapper (it rebases the merge commit); use plain `git push origin dev`.
   5. **Delete the feature branch** (local + remote) after the push succeeds.
   6. **Reset the main worktree** to detached-at-integration-branch-tip (for gitflow-lite repos with a separate main worktree).
   7. **Record the merge** in the plan's Validation block: merge commit hash, integration branch push confirmation.
   8. **Delete any stale branches** that should not exist (e.g. if a repo's `AGENTS.md` says `main` was renamed to `dev`, delete `origin/main` if it still exists).

   **Exception — `code-multi` worktree variant**: The `code-multi` variant pushes a `wt/code-multi/<slug>` branch and moves the plan to `Tasks/Review/` for `review-merge` to handle. The merge is deferred to `review-merge`, not done in step 4b. See the "code-multi" section below and the `review-merge` workflow.

   **Exception — no code changes**: If the session only modified salmon-orchestrator (plan files, task moves, orchestrator config), skip this step — the step 4 push already handled it.

 5. **Return to queue** — Check for a [stop signal](workflow-primitives.md#stop-signal-graceful-drain-interrupt) via `Invoke-StopSignalCheck.ps1` — this includes the orchestrator-active check (standalone agents yield when an orchestrator is running; orchestrated agents skip it). If signal found, emit a `CLEANUP` event and exit. Otherwise, scan `Tasks/Code/` for the next task. If a file is found, return to step 1. If none found, proceed to the [AGENTS.md Completion Checklist](AGENTS.md#completion-checklist) — its step 11 (Return to queue) handles polling via the Drain Queue.
    
    **Exception — orchestrated dispatch (`work-code`, `work-stream`):** `work-code` exits after step 4 (Finale+Commit) — the orchestrator manages the outer loop. `work-stream` checks before each file and each poll cycle — see Stream Variant above.

### Coder re-groom rule

Before executing each task, the Coder MUST re-explore the codebase immediately adjacent to the task's target files — and SHOULD explore the target files themselves — to verify the plan's assumptions still hold.

**Why**: Plans are written against a snapshot of the codebase. By the time the Coder picks up the task, files may have moved, conventions may have shifted, or new patterns may have been introduced. A 30-second read at task start catches drift before the Coder commits to a wrong implementation.

**Mandatory vs. recommended split**:
- **Mandatory** when the task touches 2+ files, or touches any architectural surface (auth, security, public APIs, shared modules, data models)
- **Mandatory** in stub mode (per the Stub-Mode Plan Shape section in `session-plan-format.md`)
- **Recommended** otherwise (single-file trivial tasks); the Coder may skip if the target file is small and recently read

**Re-groom note format**: The Coder appends a 1–3 line re-groom note to the commit message (after the body, separated by a blank line) recording: drift, contradictions, and chosen adaptation.

**Escalation rule**: If the re-groom pass reveals a fundamental plan-vs-codebase mismatch (e.g., the plan's chosen approach is incompatible with the codebase's actual architecture), the Coder MUST stop and surface to the user with two options: in-place workaround, or re-architect (Planner re-engages with the original plan + the concrete failure as new context).

### Troubleshooting

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| `Lock-File` returns False for a stale lock | Prior agent crashed without releasing `.lock` file | `Remove-Item <stale.lock> -Force` then retry |
| `git show <file> | Out-File` collapses newlines | `git show` returns array; `Out-File` joins with spaces via `$OFS` | Use `$content -join "\`n"` before `Set-Content` |
| `git add` warns "LF will be replaced by CRLF" | `Set-Content` uses CRLF on Windows | Use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))` |
| `Invoke-Pester` times out on full test suite | Many pre-existing failures (AWS SSO, mcp_web 403s) | Scope to single test file: `-Output Minimal -PassThru` |
| `Export-OpenCodeSessions.ps1` writes to wrong dir | Script reads `$PSScriptRoot` instead of canonical `Tasks/Complete/Prompts/` | Pass explicit `-OutputDir Tasks/Complete/Prompts` |
| `Write-WorkflowEvent` fails "Access is denied" | Mutex held by another agent | Don't retry — commit is the source of truth |
| Docker Swarm DNS `dns.resolve()` returns ENOTFOUND after service recreation | VIP registration lost | Use `dns.lookup()` + `extra_hosts` in compose |
| Container exits 137 (SIGKILL/OOM) or 143 (SIGTERM) | Insufficient memory limit | Verify service memory limits (is-api needs >256MB) |

### Procedure — Best Practices

- **Process plans in alphabetical order** — this naturally respects dependency chains when plans are numbered sequentially
- **Verify with `node --check` after every JS/MJS edit** — catches syntax errors before commit
- **Use `git add <file>` per-file** — avoids staging other agents' concurrent modifications (never `git add -A`)
- **Pre-verify Working/ directory creation** before starting implementation
- **Use explicit absolute path resolution** for all agent-related paths
- **Use `[regex]::Match()` instead of `-match`** in dot-sourced scripts to avoid `$matches` pollution
- **Return arrays from PowerShell functions using `, @($result)`** — bare `return $result` unrolls single-element collections
- **When committing Code/ → Review/ moves**, stage with `git rm --cached <source>` before `git add <dest>`
- **Scope Pester to one test file** with `-Output Minimal -PassThru` for fast signal
- **Check Pester version** — current 5.7.1 works on this host; re-validate if assumptions change

## code-multi — Parallel Worktree Variant

The `code-multi` opencode command is a parallel variant of Code mode for headless dispatch via the host orchestrator. It differs from sequential Code mode in these ways:

| Aspect | Sequential Code | code-multi |
|---|---|---|
| Working dir | Main clone (shared index) | Isolated worktree (own index at `.git/worktrees/<name>/index`) |
| Branch | Works on a lock-claimed plan in main | Creates `wt/code-multi/<slug>` branch |
| Drain loop | Full drain (process all plans, poll 10×120s) | Single plan per session, exits |
| Concurrency | Serialized by git lock + namespace | Parallel — up to `OPENCODE_MAX_CONCURRENT_SESSIONS` |
| Merge to main | Coder pushes main directly | Coder pushes branch; review-merge merges later |
| MCP access | Via OPENCODE_CONFIG (opencode serve) | Via config merge (serve-time OPENCODE_CONFIG inherited by `?directory=` sessions) |

**Flow**:
1. The host orchestrator (`-CodeDispatchCron`) triggers mcp_opencode to create a worktree via `New-SessionWorktree` (verifies head, JIT-rebases onto `origin/main`). MCP access comes from config merge — no overlay file is written.
2. The `code-multi` session cds to the worktree, reads the plan, runs `Get-ConnascenceGroups.ps1` for a safety check (no overlap with in-flight sessions), implements, commits, pushes `wt/code-multi/<slug>`.
3. Writes `## Worktree Metadata` block (branch name, session ID, push timestamp) to the plan.
4. Moves plan to `Tasks/Review/`, removes the worktree working dir (keeps the branch for review-merge).

**The `## Worktree Metadata` block** (read by review-merge):
```
## Worktree Metadata
- Branch: wt/code-multi/<slug>
- Session: <session-id>
- Pushed: <iso-timestamp>
```

See `Infrastructure/opencode/worktree-session.ps1` for worktree primitives and head assembly.

## Changelog

- 2026-08-01: Added step 4b (target-repo integration merge) — coders must merge feature branches to the target repo's integration branch (`dev` for gitflow-lite, `main` for main-only) before declaring done. Root cause: csbk-local-8..12 commits landed on `origin/main` in currentsbk.ca but were never merged to `dev`, making them invisible to CI and other agents. The `code-multi` variant is exempt (review-merge handles the merge).
- 2026-07-15: Consolidated 2026-06-14 dated lessons into Troubleshooting + Procedure sections; removed dated lessons block
- 2026-07-14: Documented `(?m)` regex multiline bug causing inline-vs-bullet parser confusion; PowerShell `return @($result)` unrolls single-element arrays (use `return ,$result`); Python module naming (hyphens not importable)
- 2026-06-19: Documented stale-file reappearance pattern — when plan moves aren't git-staged as deletions, concurrent agents' `git pull --rebase` restores the originals in Tasks/Code/. Fix: `git add "Tasks/Code/$planName" 2>$null` alongside the Review/ destination in Finale step.
- 2026-06-17: Captured `toPascalParams` casing-bug pattern in `zoho-expenses.js` `createRoute` helper. The function uses regex `/_([a-z])/g` which only uppercases chars AFTER an underscore — `org_id` becomes `orgId` (camelCase), NOT `OrgId` (PascalCase). When a session plan says "look for `params.OrgId`" the actual key is `params.orgId`. Verification: at runtime the PowerShell handler errored with "A parameter cannot be found that matches parameter name 'orgId'" because the JavaScript passed `orgId` (camelCase) instead of the expected `OrgName`. Fix: check for `params.orgId` in the JS, convert to `OrgName` via the `resolveOrg` helper, and `delete params.orgId` before passing to PowerShell. Multi-agent re-groom: when a Coder session's plan was queued concurrently with another agent's implementation of the same fix, the second agent's commit may land in HEAD before the first agent's git push. Verify the working tree's actual state before pushing — `git show HEAD:<file>` confirms whether the fix is already in. Also: Lock-File / Register-Namespace / Unlock-File from `SalmonRun.Core` are not exported by `Import-Module` when the module is dot-sourced; use `Import-Module ... -Scope Global` to make them available (the dot-source path keeps functions in a private scope that doesn't propagate). And: the `Bookkeeper.ManifestMerge.Tests.ps1` "contains 111 matched receipts" assertion is a hard baseline that breaks every time a sync adds new downloads — change to `Should -BeGreaterOrEqual 111` to make the test resilient to future sync runs.
- 2026-06-17: Captured PowerShell `$var:` colon-scoped-variable parser quirk. The parser interprets `$var:` as a scope-qualified variable reference (like `$global:foo`), so messages like `"for $expenseId: $_"` fail with "Variable reference is not valid. ':' was not followed by a valid variable name character." Two consequences: (1) inside any PowerShell script, use `${var}:` to delimit the variable name; (2) when writing git commit messages that contain `$var:` patterns (e.g., documenting a parser fix), call `git commit` via `bash commit.sh` rather than `pwsh -Command`, because pwsh parses the message before git sees it. Also: multi-line CSV cells (e.g., from rbc-6258-manifest.csv `Notes` column with embedded newlines) survive `Export-Csv` as quoted multi-line cells. `ConvertFrom-Csv` parses them as single rows, but `Get-Content | Measure-Object` line counts are wrong. Strip newlines from notes when writing manifest CSVs. And: `Get-ChildItem -Directory` enumeration of subdirs may be unreliable during a migration when the parent dir is being modified — explicit hard-coded subdir paths in `$searchDirs` are a safer fallback.
- 2026-06-17: Captured sequential-connascence drain-queue behaviour for `2026.06.17-Bookkeeper-{0..4}` namespace. When connascent plans explicitly declare `Connascence: sequential` (each one depends on the previous being reviewed first), the Coder processes only the first plan in the session and leaves the rest in `Tasks/Code/` for the next Coder session after the Reviewer approves. The `Invoke-AgentPollingLoop` function does not distinguish "blocked on review" from "no tasks", so the Coder must apply the sequential rule manually before claiming the next plan — do NOT batch-move or batch-lock dependent plans just because they share a namespace prefix. Verified by processing `Bookkeeper-0` (field-name bug fix in `Zoho/Expenses.ps1`) while leaving `Bookkeeper-1..4` untouched in `Tasks/Code/`. Also captured two re-groom catches: (1) plan line numbers were off by one (claimed `ReceiptUrl` at line 157, actual was line 156), and (2) Task 3's "double-parse" premise was wrong — `Invoke-ApiCall -ReturnRaw` uses `Invoke-WebRequest` internally and returns `.Content` as a JSON STRING, so the existing `ConvertFrom-Json` at line 119 is correct and required. Task 3 became a no-op with an explanatory comment to prevent a future maintainer from "fixing" the non-bug. Pester tests showed a transient 4-failure (Zoho.Invoices block) on the first run due to a Windows file-lock when `BeforeAll` imports a module that dot-sources the same file the tests read via `Get-Content`; re-run produced 33/33 pass. The fix is to re-run, not to change tests.
- 2026-06-16: Captured connascent-batch-with-partial-Lock-Header rescue pattern — when prior agent moved audit plans to `Tasks/Working/` but crashed before filling the `Agent:` field, Coder uses `[regex]::Replace` with `Multiline` option (the simple `-replace` with `$` anchor doesn't match end-of-line in PowerShell by default) to fill the field across all files; verified for `2026.06.16-audit-{0,1,2,3}`. Documented auditor-vs-codebase drift: 3 of 4 audit plans had either on-disk fixes that pre-empted the work (audit-0, audit-3) or verification checks misaligned with local convention (audit-1) — Coder must always re-groom and verify before implementing, even when the plan is marked `ready`. Added post-hoc FENCE protocol — when shared-workflow changes land uncommitted, the Coder surfaces a FENCE prompt to the user and waits for explicit approval before commit, per the Shared Spec Change Protocol. Original 2026-06-14 dated block preserved above.
- 2026-06-14: Initial dated lessons block (stale-lock cleanup, already-done detection, git-show pipe-to-file gotcha, Pester scoping, plan-move order, IDE `.psm1` association, workflow-event mutex behavior).

