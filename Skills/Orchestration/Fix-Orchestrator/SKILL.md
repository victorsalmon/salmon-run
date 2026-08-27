---
name: fix-orchestrator
description: Stop, diagnose, repair, and verify Salmon orchestrator failures with a complete 4C workflow.
---

# Salmon Fix Orchestrator

An actual Fix Orchestrator cycle is a bounded recovery controller, not a status report or blind retry. Run `Orchestrator/Orchestration/Invoke-FixOrchestrator.ps1 -Force -Reason <reason>` first. It stops the orchestrator and watchdog before diagnosis, preserves queue/failure evidence, and writes structured cycle evidence under `Tasks/Logs/`.

The controller order is mandatory:

1. **Stop and preserve** — stop recorded watchdog/orchestrator/lane processes; retain logs, failed plans, PID files, and corrupted state as timestamped evidence.
2. **Preflight and classify** — resolve the repository by marker discovery (never parent-count guessing), verify canonical launcher/wrapper/scanner files, parse and import the active module, reject retired runtime paths, validate persisted health timestamps, and classify stale PID/model/runtime/queue/repository faults.
3. **Repair deterministic state** — normalize impossible future health timestamps from a preserved backup and archive/remove dead PID markers. Re-run preflight. Do not restart while preflight is red.
4. **Probe the effective model** — make one minimal, short-timeout, redacted `Reply with exactly OK.` request. Treat unauthorized, quota/exhausted, timeout, launch error, and non-OK as unhealthy.
5. **Run 4C for the classified cause** — repair source/config/plan/dependency defects and all siblings; unknown faults fail closed with their evidence instead of being hidden by another restart.
6. **Restart and prove** — launch the canonical watchdog, require a fresh watchdog heartbeat and child orchestrator PID, reject init errors, then require fresh structured dispatch/stream activity and semantic completion progress. A failed proof re-enters diagnosis; it is never reported healthy.

Triage the evidence across all plausible fault classes:

- malformed or stale plan/header, status, dependency, or lock metadata;
- model/provider configuration, unauthorized/quota/exhausted key, timeout, or non-OK response;
- harness/runtime/stream launch failure;
- orchestrator dispatch, dependency analysis, watchdog, PID, or restart failure;
- repository-root migration, stale canonical/retired paths, parse/import, repository/merge/push, or sibling implementation defect;
- corrupted or future-dated health state that suppresses escalation.

For every root cause, complete all 4C gates:

1. **Concern** — preserve the smallest failing reproduction and commit it before application-source edits.
2. **Cause** — document 5-Whys, inspect the full error path, and search the codebase for sibling occurrences.
3. **Countermeasure** — implement the architectural fix and repair every in-scope sibling occurrence. Rescue a failed plan only when its dependencies and header are valid; never erase failure evidence.
4. **Check** — prove red-to-green regression, invariants/property behavior, mutation detection for changed executable code, relevant full-suite results, and blast-radius safety.

Every cycle probes the effective provider/model with `Reply with exactly OK.`, `--variant minimal`, a short timeout, and redacted logs. Classify 401/402/403/429, access denied, unauthorized, quota, exhausted, timeout, and non-OK as unhealthy without exposing the key.

After the repair decision is recorded, restart through `Start-OrchestratorWatchdog`. Launcher selection is ordered: canonical `Orchestrator/Orchestration/Invoke-Orchestrate.ps1`, then the current compatibility path. Retired Salmon paths are preflight failures, not fallbacks. Pass the effective harness/provider/model explicitly and inherit both `Orchestrator/Modules` and `Skills/Docker/Modules` when they exist. Wait for a live watchdog PID with a fresh `agents/watchdog-<pid>.heartbeat`, then require a fresh child orchestrator PID or preserve the new `.orchestrator-init-error` as the failure result.

Commit and push only explicit targeted source, test, dossier, and rescued-plan paths. Never use `git add -A`. Restart only after the 4C checks pass. Verify live PID state, active streams, a successful dispatch, and a new semantic completion; process existence alone is not health.
