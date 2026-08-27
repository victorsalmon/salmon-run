---
name: queues
description: Inspect Salmon queue progress and escalate real stalls instead of reporting process-alive as healthy.
---

# Salmon Queues

Run `Orchestrator/Orchestration/Get-QueueProgressHealth.ps1 -Root C:\Repos\salmon-orchestrator` on every status check. Report a clearly labeled `Queues` section:

- `Code` and `Review`: root `*.md` only.
- `Working` and `Complete`: `*.md` recursively, including subfolders.
- `Handoff` and `Failed`: root `*.md` and named-plan delta.

Progress is semantic, not a file timestamp. Use the latest structured workflow completion event (`PLAN_COMPLETE`, `FILE_COMPLETE`, or completed sign-off). A write or route operation in `Tasks/Complete` is not proof of a completed plan.

The health check must also inspect:

- live watchdog and orchestrator PIDs, heartbeat/live records, and active stream count;
- queue fingerprint (counts, names, working paths, and dependencies);
- recent `DISPATCH_BLOCKED`, `DISPATCH_DEPENDENCY_ANALYSIS_UNAVAILABLE`, `STALL`, and crash/restart evidence;
- effective provider/model and the most recent completion age.
- persisted-state anomalies (invalid or future timestamps), canonical runtime-file presence, and recent child initialization failures.

Set `TriggerFix` when actionable work remains and any of these hold:

1. The queue fingerprint is unchanged for three five-minute checks, active streams are zero, and blocked/stall evidence repeats.
2. The fingerprint is unchanged for at least 30 minutes with no active streams.
3. No semantic completion has occurred for 60 minutes while work remains.
4. Persisted health state is impossible, a canonical runtime file/module cannot load, a watchdog lacks a living child, or repeated startup/dispatch/crash evidence appears.

When `FixDue` is true, a new Failed plan appears, `StateAnomalies` is non-empty, the child is absent/unhealthy, or startup/dispatch/crash errors repeat, immediately run `Invoke-FixOrchestrator.ps1 -Force -Reason <reason>`. The automatic FixDue cooldown is 15 minutes after the last escalation; supervisor death and stream discrepancies bypass that cooldown. Do not wait for a process to die. A running process with zero streams and repeated dispatch failures is unhealthy. Persist the evaluator state in `Tasks/Logs/queue-progress-state.json`; future timestamps must be surfaced and normalized rather than allowed to suppress a repair cycle. Never use `Complete` file `LastWriteTime` as the completion clock.

After a fix cycle, report the stop/probe/diagnosis/repair result, watchdog relaunch status, fresh watchdog heartbeat, child orchestrator PID/init status, and the next queue snapshot. If the watchdog is alive but the child has an init error or no fresh PID, keep health `unhealthy` and retain the error evidence for the next 4C cycle.
