---
name: opencode/workflow/scheduler
description: Schedule arbitrary prompts for any agent with natural-language timing, repeat/retry, and handoff chaining.
type: workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Scheduler Skill — opencode workflow

Schedule any prompt/agent with natural-language timing, repeat/retry, and handoff chaining. The alignment-audit flow remains untouched as a backward-compatible subtype.

## Trigger

- User says "schedule", "schedule a prompt", "set a reminder for coder"
- Agent needs to defer a task to a specific time or repeat interval

## Scripts

| Script | Purpose | Inputs |
|--------|---------|--------|
| `Schedule-Prompt.ps1` | User-facing schedule creation CLI | `-Prompt`, `-Due`, `-Repeat`, `-Agent`, `-HandoffPath`, `-Type`, `-Model`, `-RequestedBy`, `-WhatIf` |

## Schedule Schema

`Tasks/Schedule/<id>.json`:

```json
{
  "id": "sched-20260619-001",
  "type": "custom",
  "prompt": "Run diagnostic check",
  "agent": "coder",
  "status": "pending",
  "created_at": "ISO timestamp",
  "scheduled_at": null,
  "repeat": { "interval_minutes": 30, "max_attempts": 4 },
  "attempt": 1,
  "max_attempts": null,
  "retry_count": 0,
  "max_retries": 3,
  "last_error": null,
  "handoff_path": null,
  "model": null,
  "triggered_at": null,
  "completed_at": null,
  "result": null,
  "error": null
}
```

- `type`: `"custom"` (non-audit) or `"alignment-audit"` (existing flow)
- `agent`: `"coder"`, `"reviewer"`, `"auditor"`, `"any"` (default `"any"`)
- `scheduled_at`: ISO date or `null` (= fire ASAP on next poll cycle)
- `repeat`: `null` for single-shot or `{ interval_minutes, max_attempts }`
- `result`: populated with `"plan completed"` on successful execution
- `error`: populated with a descriptive message only on actual failures (e.g. stale watchdog expiry). Must be `null` on success.
- `retry_count`: number of auto-retries attempted by the sentry watchdog (incremented each retry)
- `max_retries`: maximum auto-retries before marking as failed (default 3)
- `last_error`: most recent error message from plan execution (set by the agent or watchdog)
- `handoff_path`: optional handoff file in `Tasks/Handoff/`
- `model`: optional model constraint (`"provider/model-id"` or `null` for agent's default)
- `cycle_id`: present only for `alignment-audit` type — identifies the audit cycle
- `requested_by`: present only for `alignment-audit` type — who requested the audit

## Usage

### CLI

```powershell
.\Skills\\Orchestration\Workflows\Scheduler\Schedule-Prompt.ps1 "Run diagnostics" -Due "in 30 minutes" -Agent "coder" -Repeat "every hour 3 times"
```

### Natural Language Due Parsing

| Input | Result |
|-------|--------|
| `"ASAP"` / null | `scheduled_at = null` (fires next poll) |
| `"in 2 hours"` | `scheduled_at = now + 2h` |
| `"tomorrow 3pm"` | `scheduled_at = tomorrow 15:00` |
| `"2026-06-20T15:00:00"` | Direct ISO parse |
| `"3pm"` / `"15:00"` | Today at that time (tomorrow if past) |

### Natural Language Repeat Parsing

| Input | Result |
|-------|--------|
| `"every 30 minutes for 2 hours"` | `{ interval_minutes: 30, max_attempts: 4 }` |
| `"every hour 3 times"` | `{ interval_minutes: 60, max_attempts: 3 }` |
| `"once"` / null | `repeat = null` |

## Sentry Poller Integration

The Tempo poller (`Start-TempoSchedulePoller` in `SalmonRun.Tempo`) handles:
- **Watchdog**: Schedules stuck in `"triggered"` state > 2h are auto-advanced or marked completed
- **Path A** (`alignment-audit`): Existing audit cycle creation flow
- **Path B** (`custom`): Writes a plan `.md` via `Write-SchedulePlan` — routed to `Tasks/Code/` (coder/auditor/any) or `Tasks/Review/` (reviewer) per the `agent` field

## Key Cross-References

- `Skills/Workflows/Scheduler/Schedule-Prompt.ps1` — CLI script
- `Orchestrator/Modules/SalmonRun.Tempo/Public/Start-TempoSchedulePoller.ps1` — Tempo poller with Path B dispatch
- `Skills/Auditor/alignment-audit.md` — backward-compatible audit flow
- `AGENTS.md` — Key Files & Directories table

## Red Lines

- **No modification of alignment-audit schedule flow**: Path A is untouched
- **Schedule files are write-once**: The poller mutates status/scheduled_at fields; agents update schedule files on plan completion
- **Sequential IDs**: Schedule files use date-based sequential IDs (`sched-YYYYMMDD-NNN`)
