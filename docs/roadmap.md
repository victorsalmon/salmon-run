# Salmon Run roadmap

This roadmap distinguishes implemented code from release proof. The product destination is defined in [`../vision.md`](../vision.md).

## Implemented MVP foundation

- Canonical pipeline and replaceable pond task graph.
- Independent per-pond `Challenge`, `Harness`, `Provider`, `Model`, `Effort`, `TimeoutMinutes`, and `CostCeiling` resolution.
- Confirmed plan overrides with field-by-field precedence: plan, pond configuration, global configuration, provider catalog.
- Read-only Review; ordered deterministic Audit contract; defect-triggered 4C contract.
- Typed, attempt-bound result sidecars and bounded semantic/transport retry state.
- QA evidence schema and fail-closed 95% raw changed-code mutation gate.
- Missing mutation tooling and invalid/unconfirmed execution choices route to Intake.
- PublicLocal deterministic lifecycle canary and OpenCode Go golden-path configuration.
- Manifest-driven public-to-private sync and hash parity checks.

## MVP release gates

The next release is blocked until all of these produce fresh evidence on the release commit:

1. Full Pester suite, documentation lint, leak scan, installer verification, Docker build/dry run, and PublicLocal lifecycle are green.
2. Unit/property tests exercise profile precedence, partial and invalid overrides, cost ceilings, adapter interchangeability, Audit order, 4C routing, evidence freshness, every retry/decision terminal state, and weekly Archive.
3. Changed production code achieves at least 95% raw mutation coverage with every non-killed outcome dispositioned and no waiver.
4. A representative OpenCode Go plan completes every pond, plus controlled transport, semantic, identical-failure, and human-decision canaries.
5. The synchronized private consumer imports and runs the shared engine with no parity drift.
6. A monitored four-hour unattended soak has no duplicate dispatch, stuck lease, residual Working lane, unbounded retry, or queue-state loss.

## After MVP

- Promote beta adapters only after provider-specific lifecycle and soak evidence.
- Add new ponds and policy packs without coordinator changes.
- Expand platform-neutral installers and observability exporters.
- Publish reproducible release evidence and signed artifacts.
