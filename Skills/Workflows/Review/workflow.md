## Review Workflow

### Prerequisites (<10s)
- [ ] Identity registered (PID file, heartbeat)
- [ ] Orchestrator context detected (`$script:orchestrated` set; OrchestratorId/OrchestratorPID captured if applicable)
- [ ] **Stale-file pre-check**: Run `Invoke-StaleFilePreCheck -ScanDir "Tasks/Review" -LiveDirs @("Tasks/Code", "Tasks/Working", "Tasks/Complete") -Phase review` (from `workflow-primitives.md` § Stale-file pre-check). Run once per session (guard with `$script:stalePreCheckDone`).
- [ ] File lock acquired for plan file (appends Lock Header block with orchestrator fields if orchestrated)
- [ ] Plan/feedback file read
- [ ] HANDSHAKE event written acknowledging prior Coder session


### Workflow
 0. **Predictive compaction via checkpoint ritual** — If token budget >= 100K or >= 10% of the context window, run the checkpoint-compact-restore ritual (see the `/checkpoint` command template in `opencode.json`) BEFORE starting the audit, to avoid mid-review loss. The ritual persists workflow state to disk first, so compaction is lossless with respect to workflow position. Threshold 100K/10% inherited from prior convention.
 1. **Audit** — verify outputs exist on disk, check code against plan acceptance criteria.
    - **Run Pester tests conditionally** — only if the plan appears fully implemented:
        1. Check the plan's Lock Header. Skip test execution if: `Progress: < 100%`, or the `**Escalated**` section has unresolved items, or `**Deferred**` tasks would affect correctness of other modules.
         2. If the plan passes the gate, run applicable Pester tests — git-aware, covering modules the plan modified plus all Regression-Only guards, in a single pass:
            ```powershell
            $c = git diff --name-only HEAD
            $tags = $c | ForEach-Object {
                if ($_ -match 'Modules[/\\]Interclaw\.(\w+)') { $matches[1] }
                elseif ($_ -match 'Scripts[/\\]config\.ps1') { 'Config' }
                elseif ($_ -match 'Docker[/\\]1Install\.ps1') { 'Host' }
            }; $tags = $tags | Where-Object { $_ } | Select-Object -Unique
            # Single pass: plan-specific tags + Regression-Only guards (avoids double full-suite execution)
            if ($tags) { $tags | ForEach-Object { Invoke-Pester Skills/Docker/Tests/ -Tag $_ } }
            # Regression-Only guard: batch form throws "Unsupported Operating system!"
            # in Pester 6.0.1 GetPesterOs/TestDrive on this host — use the per-file
            # fallback wrapper in run-integration.ps1 (canonical invocation).
            & (Resolve-Path "Skills/Docker/Tests/run-integration.ps1") -RegressionGuard
            ```
            > **Test harness — Regression-Only guard**: The batch form
            > (`Invoke-Pester Skills/Docker/Tests/ -Tag "Regression-Only"`) throws
            > `Unsupported Operating system!` from Pester 6.0.1 `GetPesterOs`/TestDrive on
            > this host (pre-existing; see
            > `~/.salmon/Tasks/Archive/Manual/2026-08-02/2026-08-01-pester-batch-tag-run-unsupported-os.md`).
            > The per-file fallback in `run-integration.ps1` (`-RegressionGuard`) is the
            > canonical invocation. Re-test the batch form after a Pester upgrade and remove
            > the fallback when the batch form works.
         3. **Diagnose failures**: For each failing test, determine whether the failure is caused by the plan's code (new test failing, or existing test broken by a code change) or is pre-existing (test was already failing before this plan).
         4. **Write feedback if needed**: If any failure traces to the plan's code, write a feedback file to `~/.salmon/Tasks/Code/` listing each test name, failure message, and the plan file it relates to. Include `severity: blocking` if the plan would introduce a regression. Do not implement fixes — only document.
         5. If no failures trace to the plan's code, log `"Pester: <N>/<M> passed (pre-existing failures unrelated to this plan)"` and proceed.
    - If shared files modified, verify Shared Spec Change Protocol was followed.
    - **Dependency verification** — If the plan has a `**DependsOn**:` field:
      - [ ] All upstream deps listed in DependsOn have a Lock Header showing `Status: released` (for status: reviewed deps) or are committed to the repo (for status: complete deps).
      - [ ] The Lock Header's `DependsResolved:` field is set to `true`.
      - [ ] No DependsOn ref points to a session still in `Tasks/Code/` or `Tasks/Working/` without a released lock.
      - [ ] The implementation does not reference files or concepts from an unresolved upstream session.
      - If any check fails, flag in the feedback file with `severity: blocking`. If the Coder implemented a workaround duplicating upstream functionality, flag with `severity: warning`.

      Severity table:

      | Severity | Condition | Action |
      |----------|-----------|--------|
      | **Blocking** | A DependsOn dep with status `reviewed` was NOT in Tasks/Complete/ when the Coder locked. (Checked via Lock Header timestamps.) | Feedback: `severity: blocking`. Session must be reverted or retried after dep is reviewed. |
      | **Blocking** | A DependsOn dep with status `complete` was NOT committed when the Coder locked. | Same as above. |
      | **Warning** | Coder duplicated an unresolved upstream dep's scope (temporary workaround). | Feedback: `severity: warning`. Note duplication, suggest cleanup in upstream dep. |
      | **Info** | DependsOn ordering respected but `DependsResolved:` missing or `false`. | Feedback: `severity: info`. Ask Coder to add the field. |

      **Feedback templates**:

      Blocking template:
      ```
      ### Blocking: DependsOn gate not respected

      **Session**: <session name>
      **DependsOn ref**: <ref> (status: <gate>)
      **What was expected**: <ref> should have been in Tasks/Complete/ (for reviewed) or committed (for complete) before this session was locked.
      **What was found**: <ref> was still in <Tasks/Code/ or Tasks/Working/> at lock time (Locked: <timestamp> vs <ref>'s Released: <timestamp>).
      **Action required**: Revert the DependsOn-blocked changes, wait for the dep to reach the required gate, and re-implement.
      ```

      Warning template:
      ```
      ### Warning: Duplication of unresolved upstream dep

      **Session**: <session name>
      **Upstream dep**: <ref> (status: <gate>)
      **Duplicated scope**: <description of what was duplicated>
      **Suggestion**: Remove the duplication once <ref> is resolved, or refactor to use the upstream's output directly.
      ```
      - Run `Invoke-ValidateDependencyGraph.ps1 -Detailed` to auto-detect DependsOn issues before manual inspection.
2. **Completion assessment** — score against plan's task list:
   - **100%** (or human-only deferred): route to `Tasks/Complete/<namespace>/`, where `<namespace>` is computed **deterministically** by the existing `Get-FileNamespace` parser — do **not** invent or shorten the subfolder name by eye. Compute it once and reuse it for every file in the batch:
     ```powershell
     . (Resolve-Path "$PWD\Skills\\Orchestration\LocalOrchestrator-FileHelpers.ps1")
     $namespace = Get-FileNamespace -FileName $planName
     $destination = "Tasks\Complete\$namespace"
     if (-not (Test-Path $destination)) { New-Item -ItemType Directory -Path $destination | Out-Null }
     ```
     For a filename like `2026-07-27-csbk-fe-dash-1-step-indicator-and-5tab-nav.md`, this yields `csbk-fe-dash` — the full segment between the date prefix and the iteration number. Two plans in the same namespace (e.g. all `csbk-fe-dash-*`) MUST land in the same subfolder. Never abbreviate to a shorter token (e.g. `dash`) — that splits a single namespace across folders and makes completed work look missing.
   - **Partially complete**: route to `Tasks/Complete/` as loose file + write feedback to `Tasks/Code/`
   - **Nothing done (blocked on deps)**: route back to `Tasks/Code/` — valid plan that couldn't execute due to external dependencies; a future Coder with available deps will pick it up.
   - **Nothing done (obsolete/invalid plan)**: route to `Tasks/Complete/` as loose file with clear note — do not leave in `Tasks/` root which is outside the pipeline lifecycle.
3. **Finale** — update Lock Header: `Released: <now>`, `Status: released`. Release locks, write `RELEASE` + `MOVE` events. Move to destination. Record per-file timing. Then verify clean tree, stage, commit, and push:

   ```powershell
   Unlock-File -FileNames @("$planName")

   # Verify-then-move guard (orchestration-3): the reviewer lock-header prepend
   # must never destroy the plan body. Abort before the move if it did.
   . (Resolve-Path "Skills/Workflows/Review/Scripts/Invoke-ReviewFinaleGuard.ps1")
   $planPath = "Tasks/Working/<agent-id>/$planName"
   if (-not (Test-ReviewPlanBodyIntact -Path $planPath)) {
       Write-WorkflowEvent -Type ABORT -Files @("$planName") -Detail "reviewer lock-header prepend lost the plan body; restoring from git" -Phase review
       git show "HEAD:Tasks/Review/$planName" | Set-Content $planPath -NoNewline
       throw "Reviewer lock-header write truncated $planName — restored from git, aborting move. Re-run the review."
   }

   # Instant-review rejection: Released - Locked < 10s means the "review" was
   # automated truncation, not a real audit. Leave the file for re-review.
   $reviewDelta = Test-InstantReviewDelta -Path $planPath
   if ($null -ne $reviewDelta -and $reviewDelta -lt 10) {
       Write-WorkflowEvent -Type INSTANT_REVIEW_TRUNCATION_SUSPECT -Files @("$planName") -Detail "Released-Locked delta=${reviewDelta}s" -Phase review
       throw "Reviewer run for $planName had Released-Locked delta ${reviewDelta}s (<10s) — likely automated truncation. File left in Tasks/Working/ for re-review."
   }

   # Usage metadata is part of the completed-plan record. The helper reads the
   # local OpenCode DB read-only and writes one stable block before the header
   # separator; missing usage remains explicit as unknown rather than guessed.
   . (Resolve-Path "Orchestrator/Orchestration/Add-PlanUsageMetadata.ps1")
   Add-PlanUsageMetadata -Path $planPath -SessionId $env:OPENCODE_SESSION_ID `
       -Harness $env:OC_HARNESS -Provider $env:OC_PROVIDER -Model $env:OC_MODEL -Effort $env:OC_EFFORT

   Write-WorkflowEvent -Type RELEASE -Files @("$planName") -Detail "released -> (destination)" -Phase review
   Write-WorkflowEvent -Type MOVE -Files @("$planName") -Detail "Tasks/Working/<agent-id>/ -> (destination)" -Phase review
   Move-Item -LiteralPath "Tasks/Working/<agent-id>/$planName" -Destination "<destination-path>" -Force
   Remove-Item "Tasks/Working/<agent-id>" -Force -ErrorAction SilentlyContinue
   $elapsed = [math]::Round(((Get-Date) - $fileStart).TotalSeconds, 0)
   Add-Content -Path "$PWD\.session-timing.txt" -Value "$planName: ${elapsed}s"
   ```

   ```powershell
   # commit and push the audited plan and any other files modified during review
   git add $planName
   git commit -m "review: $planName"
   $commitHash = (git rev-parse --short HEAD).Trim()
   Write-WorkflowEvent -Type COMMIT -Files @("$planName") -Detail $commitHash -Phase review
    & (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push
   Write-WorkflowEvent -Type PUSH -Detail "pushed" -Phase review
   ```

4. **Return to queue** — Check for a [stop signal](workflow-primitives.md#stop-signal-graceful-drain-interrupt) via `Invoke-StopSignalCheck.ps1` — this includes the orchestrator-active check (standalone agents yield when an orchestrator is running; orchestrated stream agents skip it automatically via `$env:OC_STREAM_ID`). If signal found, emit a `CLEANUP` event and exit. Otherwise, scan `Tasks/Review/` for the next file. If a file is found, return to step 1. If none found, proceed to the [AGENTS.md Completion Checklist](AGENTS.md#completion-checklist) — its step 11 (Return to queue) handles polling via the Drain Queue. Exception: `work-review` orchestrated dispatch exits after step 3.

## Troubleshooting

### Agent ID collision with concurrent sessions
When a concurrent agent runs the same session-init.ps1, it overwrites `.session-agent.txt`. Subsequent reads return the *other* agent's ID. Symptoms:
- `Move-Item` errors: `Cannot find a part of the path` pointing to a different agent's `Tasks/Working/<other-agent-id>/` directory
- File locks acquired by the wrong agent
- Workflow events emitted under the wrong agent identity

**Fix**: set `$env:OC_RESERVATION_AGENT_ID` directly from a per-script variable before any module import. Do NOT read from `.session-agent.txt` after the first invocation. Re-import `SalmonRun.Core` and `SalmonRun.WorkflowEvents` after the variable change to refresh module state.

### Workflow events mutex timeout
The global `Interclaw-WorkflowEvents-Mutex` named semaphore can be held by a concurrent agent for several seconds. Default `WaitOne(5000)` timeout fires and the function throws.

**Fix**: wrap `Write-WorkflowEvent` in a retry loop with 2-3s sleep, max 5 retries. The events are best-effort — failing to emit one is preferable to failing the whole review pass.

### Per-file timing accumulation
The per-file timing cache (`.session-timing.txt`) is gitignored but accumulates across sessions. To get a clean per-session report, clear the file at session start (Phase 1 step 0) and append per-file entries as you go. The CC's elapsed-time reporter reads the file as-is.

## review-merge — Parallel Merge Variant

The `review-merge` opencode command is the reviewer + merger for the parallel `code-multi` path. It replaces both the Reviewer role and the daemon merge step for worktree-based work. It runs **serially** (one at a time, lock-guarded) because merges to the integration branch must not race.

| Aspect | Sequential Review | review-merge |
|---|---|---|
| Working dir | Main clone | Main clone (NOT a worktree — it merges to the integration branch) |
| What it reviews | Plans moved by Coders to `Tasks/Review/` | Plans with `## Worktree Metadata` block |
| Merge | Hands off — Coder already pushed main | Does the merge itself (LLM resolves conflicts) |
| Concurrency | Serialized by git lock | Serialized by `.review-merge.lock` |
| Feedback | Writes to `Tasks/Code/` if issues | Post-merge audit writes re-do feedback if work lost |

**Flow**:
1. Tempo cron (`-ReviewDispatchCron`) checks `.review-merge.lock` — if held (and < 30 min old), skips.
2. The `review-merge` session reads the oldest plan in `Tasks/Review/` with a `## Worktree Metadata` block.
3. Acquires `.review-merge.lock`, fetches the coder's branch (`wt/code-multi/<slug>`).
4. Reviews changes against plan, runs Pester tests.
5. Merges into the target repo's integration branch: `git merge --no-ff`. **Detect the integration branch** by reading the target repo's `AGENTS.md` for a "Branching model" section — `dev` for gitflow-lite repos (e.g. currentsbk.ca), `main` for main-only repos. If conflict, the LLM resolves each conflict file (prioritize the integration branch, consider coder's value, destructive mods viable if they match plan intent).
6. **Post-merge audit**: `Write-RedoFeedback` diffs the merge range against the plan's `**Files**:` field. If expected files are missing from the merge, writes `<date>-<slug>-redo-feedback.md` to `Tasks/Code/`.
7. Pushes the integration branch via `Invoke-GitPullSafe.ps1` (for main-only repos) or plain `git push origin dev` (for gitflow-lite repos — do NOT use the safe-pull wrapper, it rebases the merge commit). Releases lock.

**Design decision — post-merge feedback, not live-steering**: Coders are never interrupted with merge diffs. If a merge loses work the plan required, the audit writes a re-do plan to `Tasks/Code/` that a coder picks up in the normal queue. This avoids lossy mid-session re-derivation from deltas.

See `Infrastructure/opencode/review-merge-helper.ps1` for `Get-WorktreeMetadata`, `Lock-ReviewMergeLock`, `Unlock-ReviewMergeLock`, and `Write-RedoFeedback`.

## Changelog
- 2026-08-02: Added verify-then-move guard to the Finale — a reviewer lock-header prepend that loses the plan body aborts with `ABORT`/`LOCK_WRITE_TRUNCATION` before the move, restoring from git. Instant reviews (`Released - Locked` delta < 10s) are rejected with `INSTANT_REVIEW_TRUNCATION_SUSPECT` and left in `Tasks/Working/` for re-review. Atomic lock-header writes are defined once in `workflow-primitives.md` § Atomic lock-header writes.
- 2026-08-01: Fixed review-merge to detect the target repo's integration branch (`dev` for gitflow-lite, `main` for main-only) instead of hardcoding `main`. Push logic now branches: safe-pull for main-only repos, plain `git push origin dev` for gitflow-lite (safe-pull rebases the merge commit unnecessarily).
- 2026-06-16: Added Troubleshooting section (agent ID collision, workflow events mutex, per-file timing); integrated with SKILL.md Audit patterns
