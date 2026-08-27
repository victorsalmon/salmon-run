# Skill: RunFix Orchestrate

**Canonical goals file**: `Skills/Cowork/RunFix/runfix-localorchestrator.md`

Resolves via the naming convention: `orchestrate` → `runfix-orchestrate.md` (this file),
which is an alias for the canonical `runfix-localorchestrator.md`.

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

## Key design

`RunFix orchestrate` runs in **script mode**, delegating to the canonical `runfix-localorchestrator.md` goals file. It:
1. Launches `Invoke-Orchestrate.ps1 -DetachWatchdog` — which re-launches the entire
   watchdog loop in a hidden PowerShell window and exits immediately.
2. **Reads the orchestrator's structured log** (`Tasks/Logs/orchestrator-*-structured.log`)
   after each cycle and flags any `ERROR`/`WARN` entries as fatal failures
   (if they persist across two consecutive cycles).
3. Polls queues until all three are empty (or max cycles reached).
4. Reports SUCCESS when queues drain, FAILED otherwise.

This means **RunFix orchestrate does not block** — the watchdog runs fully detached.
The orchestrator log is verified between each cycle to detect issues early.
