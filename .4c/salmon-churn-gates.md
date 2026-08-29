# salmon-churn-gates - 4C Bug Fix
**Repo:** salmon-run - main   **Started:** 2026-08-29

## Concern
- Failure: When a completed pond lane contains historical verdicts or timestamped failure telemetry, Salmon Run reuses stale evidence or throws during transition and rescues the plan backward instead of applying one bounded, monotonic gate decision.
- Repro tests: `Tests/SalmonRun.ReviewVerdict.Tests.ps1`, `Tests/SalmonRun.PondEngine.Feedback.Tests.ps1`, and `Tests/SalmonRun.PondScheduling.Tests.ps1` (RED commit pending).
- State/concurrency properties: the latest gate attempt is authoritative; transition classification is total and non-throwing; and one Git common repository permits at most one writer.
- Repro run output: Pester 6.1.0 ran 17 tests: 13 passed, 4 failed. Failures proved first-match verdict poisoning in both directions, the `DateTime.TryParse` overload exception, and base-repo/worktree writer-key mismatch.

## Cause
Pending Concern gate.

## Countermeasure
Pending Cause gate.

## Check
Pending Countermeasure gate.