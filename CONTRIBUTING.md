# Contributing to Salmon Run

Thank you for improving Salmon Run. The project favors small, composable control-plane services and evidence-backed changes.

## Development setup

1. Install PowerShell 7 and Pester 6.
2. Clone the repository and run `./install.ps1` with a disposable `-RuntimeHome` for development.
3. Run `Invoke-Pester -Path ./Tests` before submitting a change.

Runtime plans, credentials, logs, results, leases, and sync state belong under `SALMON_RUN_HOME`; never commit them to the source repository.

## Architecture rules

- Treat ponds as interchangeable stages with narrow eligibility and result contracts.
- Keep routing, leases, recovery, health, and Git synchronization coordinator-owned.
- Use Git common-directory identity for every code-changing writer lock.
- Fail parser and transition errors closed to `Paused/EngineError`.
- Keep plan specifications bounded; operational telemetry belongs in the journal.
- Preserve idempotency across restarts and outbox replay.

Read [docs/orchestrator-architecture.md](./docs/orchestrator-architecture.md) before changing the engine.

## Bug fixes

Use a red-green workflow for non-trivial defects:

1. commit a focused failing reproduction;
2. document the root cause and sibling search;
3. fix the architectural cause;
4. run focused, full, property, and mutation-relevant checks.

Do not weaken an invariant or convert an engine error into automatic Code rework to make a test pass.

## Pull requests

Keep commits scoped and use imperative messages such as `fix: serialize repository writers`. A pull request should include:

- the behavior and invariant changed;
- red-then-green evidence for defects;
- exact test commands and results;
- migration or compatibility notes;
- confirmation that `scripts/Invoke-LeakCheck.ps1` passes.

By contributing, you agree that your work is licensed under the repository's MIT License.