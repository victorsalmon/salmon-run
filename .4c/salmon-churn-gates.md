# salmon-churn-gates - 4C Bug Fix
**Repo:** salmon-run - main   **Started:** 2026-08-29

## Concern
- Failure: When a completed pond lane contains historical verdicts or timestamped failure telemetry, Salmon Run reuses stale evidence or throws during transition and rescues the plan backward instead of applying one bounded, monotonic gate decision.
- Repro tests: `Tests/SalmonRun.ReviewVerdict.Tests.ps1`, `Tests/SalmonRun.PondEngine.Feedback.Tests.ps1`, and `Tests/SalmonRun.PondScheduling.Tests.ps1` (RED commit pending).
- State/concurrency properties: the latest gate attempt is authoritative; transition classification is total and non-throwing; and one Git common repository permits at most one writer.
- Repro run output: Pester 6.1.0 ran 17 tests: 13 passed, 4 failed. Failures proved first-match verdict poisoning in both directions, the `DateTime.TryParse` overload exception, and base-repo/worktree writer-key mismatch.

## Cause
### 5-Whys
1. Passed plans returned to Code because the executor declared them failed and the reaper rescued files left after a failed transition.
2. The executor declared them failed because verdict readers used `[regex]::Match`, so the first historical header controlled every later attempt; the transition then threw while trying to classify the failure.
3. Classification threw because `TryParse` received `[ref]` variables initialized as untyped `$null`, which PowerShell could not bind to a typed overload.
4. The reaper converted that internal exception into ordinary rework because its catch left the plan in the lane and an unconditional cleanup block moved every remaining file to `OnFailure` (Code).
5. These defects were possible because plan Markdown simultaneously served as immutable specification, mutable current state, and unbounded operational event store, while failure handling had no typed result contract or fail-closed engine-error state. Repository exclusion had the same identity hole: scheduling keyed the base path, but active-lane bookkeeping keyed the worktree path.

### Root cause
The control plane lacks a canonical attempt/result and repository-identity boundary. Gate readers infer current state from the first matching line in an append-only document, transition classification can throw instead of returning a typed outcome, and reaping treats internal transition failure as recoverable plan failure. Concurrent scheduling similarly compares non-canonical path strings. Operational events and per-transition Git commits amplify every false transition into prompt growth and sync contention.

### Violated invariants
- State transition: the latest completed gate attempt is authoritative and one lane exit produces exactly one monotonic transition.
- Parser/date-time: failure classification is total and never throws for persisted telemetry.
- Idempotency/concurrency: one Git common repository permits at most one active writer, regardless of base/worktree path spelling.
- Recovery: engine errors fail closed to Paused and are never converted into Code rework.
- Bounded state: operational telemetry cannot grow the agent input without limit.

### Sibling occurrences
- `Modules/SalmonRun.PondEngine/Executors/PondVerdict.ps1:32,40` - first-match decision and evidence.
- `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1:35,344,345,418` - first-match failure reason and verdict reads.
- `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1:148` - untyped parse-by-reference exception.
- `Modules/SalmonRun.PondEngine/Public/Start-PondEngine.ps1:168-193` - transition exception followed by unconditional rescue to OnFailure.
- `Modules/SalmonRun.PondEngine/Private/Select-PondGroups.ps1:50-54` and `Public/Start-PondEngine.ps1:251-252,389-390` - inconsistent repository keys.
- `Modules/SalmonRun.PondEngine/Private/PondTasks/Push-PondRepos.ps1:37-49` - duplicate Git common-directory identity logic suitable for centralization.
- `Modules/SalmonRun.PondEngine/Public/PlanLog.ps1:210-240` plus executor/claim/push callers - full event history repeatedly rewritten into agent input.
- `Tools/Get-SalmonRunHealthReport.ps1:256,283-286` - 24-hour completion totals and any queue delta mask current backward churn.

## Countermeasure
- Replaced first-match parsing with a shared latest-attempt verdict resolver used by executors and transition validation.
- Added stable PlanId, AttemptId, GateAttempt, and validated attempt-scoped JSON gate results with total failure kinds.
- Transition/reaper exceptions now fail closed to Paused with engine-error; terminal Failed plans are never auto-rescued.
- Canonical Git common-directory identities now serialize all writer roles across base repositories and worktrees.
- Feedback is an attempt-linked JSON sidecar on the canonical plan; semantic rework no longer creates a second circulating family.
- Added persistent per-plan retry budgets, identical-signature escalation, and a six-transition/no-progress circuit breaker.
- Removed claim commits and direct fetch/rebase/push. Stable checkpoints enqueue an idempotent serialized sync request with dispatch backpressure.
- Operational telemetry moved to a rotating external JSONL journal. Plans retain at most 32 semantic outcomes in one normalized PondLog block.
- Health now measures forward/backward transitions, cycles, errors, sync state, duplicate families, prompt size, unique completions, and useful-run ratio.

## Check
- Focused churn regressions: 20 passed, 0 failed.
- Full Pester suite: 657 passed, 0 failed, 10 skipped. Two skips are obsolete global-counter tests retained for history and replaced by per-plan persistent-budget tests.
- PowerShell parser scan: all module, tool, and test scripts parse successfully.
- Queue recovery and live canary evidence pending.
### Runtime sibling cause — tracked working claims
The installer ignored root-level `/Working/`, but the coordinator's actual lease-owned claim directory is `/Tasks/Working/`. This path-contract drift made every claim appear as a tracked source deletion plus an untracked working copy, so Git stayed dirty during legitimate execution and sync/backpressure metrics could misclassify healthy work. The invariant is that ephemeral lease-owned lane state is journaled and ignored, while only stable pond transitions are checkpointed.
### Runtime sibling cause — heartbeat and completed lanes
`Run-SalmonRun.ps1` wrote a supervisor heartbeat, but the supported direct `Start-SalmonRun.ps1 -Run` path did not, splitting liveness ownership across entry points. Separately, transition cleanup deleted only dot-sentinels and then attempted a non-recursive directory removal, leaving `executor.log`; the health reporter treated every `lane-*` directory as active work without requiring a plan or lease. Thus dead historical scaffolding overrode live coordinator/process truth. The coordinator must publish its own PID heartbeat, transitions must remove completed lane envelopes recursively, and health must recognize only plan- or lease-bearing lanes.
### Runtime sibling cause — acknowledged sync requests
The serialized outbox evaluated retry backoff before checking whether the queued commit was already reachable from the remote branch. A successful out-of-band/manual push therefore left an obsolete high-attempt request circuit-open, suppressing dispatch even though synchronization had completed. Idempotent replay must acknowledge remote containment first, independent of retry timing and the current working-tree state.

## Final verification

- Full Pester suite: **684 total, 676 passed, 0 failed, 10 skipped, 0 not run**.
- Mutation-tagged selection: **37 passed, 0 failed**.
- Property suites: **77 passed, 0 failed**.
- PowerShell parser scan: **0 errors** across `.ps1` and `.psm1` files.
- PSScriptAnalyzer on the changed control-plane surfaces: automatic-variable and empty-catch findings removed; remaining warnings are established public naming/host-output conventions.
- Documentation lint: **11 files scanned, 0 broken references**.
- Public leak check: **no private references found**.
- Final local canary `2026.08.29-sr-final-canary-3-control-plane.md`: Code -> Review -> Audit -> QA -> Complete with exactly **4 forward transitions**, **0 backward transitions**, **0 cycles**, **0 transition errors**, **0 stale lanes**, **0 sync backlog/failures**, useful-run ratio **1.0**, one tracked Complete artifact, and clean/synchronized source and task repositories.
- Queue recovery: damaged external retry copies are preserved under `Tasks/Archive/PostCanary-20260829-195847`; complete uncertain artifacts remain in Paused and were not redispatched.

## Additional countermeasures found by the live canary

- Explicit runtime-root selection prevents inherited Pester homes from redirecting the coordinator.
- Shared dependency parsing handles blank, annotated, and bundled child dependencies.
- Repository-bound lane allocation rejects cross-repository fallback and includes Investigator in writer exclusion.
- Generation-scoped leases prevent recovery until PID, heartbeat, generation, and result checks all agree.
- `Tasks/Working`, results, state, and outbox data are excluded from task-repository checkpoints.
- Completed lane envelopes are removed recursively before checkpoint work, closing the lease-removal/recovery race.
- Coordinator-owned heartbeats and active-lane predicates make health reflect live control-plane state.
- Already-synchronized commits are acknowledged before outbox backoff, making replay idempotent.

## Result

The churn defect class is closed by typed attempt results, coordinator-owned state transitions, canonical repository locks, fail-closed recovery, bounded retry/cycle budgets, serialized Git synchronization, and progress-based health. The public documentation now describes the same stream/pond architecture enforced by the implementation.
### Performance sibling cause — repeated Git identity probes
Normal-concurrency startup resolved the same existing base repositories and worktrees repeatedly while grouping and assigning dozens of namespaces. `Get-PondRepositoryKey` spawned `git rev-parse --git-common-dir` on every comparison, so scheduling cost scaled with groups times lanes instead of unique repository paths. Existing paths have stable common-directory identity for the lifetime of one coordinator and can be memoized; nonexistent future worktree paths must remain uncached until creation.
## Planned-worktree bootstrap deadlock (2026-08-29)

### Concern

The restored queue contained eligible QA plans, the coordinator heartbeat advanced, and no writer was active, yet no lane could be claimed. `reserves a lane for a stream whose planned worktree does not exist yet` reproduces the failure: `Get-FreePondLane` returned null for the exact path owned by the stream until that worktree existed.

### Five whys

1. No restored plan was claimed because lane reservation returned no matching lane.
2. Reservation returned no lane because the requested planned-worktree key differed from the stream base-repository Git key.
3. The keys differed because the planned worktree did not exist, so Git could not resolve its common directory and the identity resolver correctly fell back to a path key.
4. The planned worktree did not exist because initialization occurs only after lane reservation.
5. The deadlock was possible because stream ownership and repository identity were collapsed into one comparison: an exact configured stream path was not recognized as authoritative before Git identity was available.

### Sibling search

The same ordering affects every non-local agentic pond (`Code`, `Review`, `Audit`, `QA`, `Intake`, `ProjectReview`, and `Investigate`) when its namespace worktree has not been created. Existing canary worktrees masked the defect. The correction belongs in the shared lane allocator so every pond receives the same bootstrap behavior while canonical Git identity remains the writer-exclusion mechanism once a repository exists.
### Final bootstrap and performance verification

- Repository identity is memoized only after a successful Git common-directory resolution; planned paths remain safe to re-evaluate.
- Exact configured stream paths can reserve their role lane before the worktree exists, breaking the initialization deadlock without weakening repository-wide writer exclusion.
- Focused scheduling suite: **13 passed, 0 failed**.
- Final flattened Pester suite: **686 total, 676 passed, 0 failed, 10 skipped, 0 not run** in 4m 53.54s.