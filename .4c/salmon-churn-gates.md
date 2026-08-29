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
Pending Cause gate.

## Check
Pending Countermeasure gate.