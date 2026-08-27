# Logging — Canonical Reference

> **Audience**: Every persona (BASE, ORCH, VERI) and every opencode workflow. This is the single canonical reference for log levels, format, and destinations. `Skills/Orchestrator/Personas/Shared/protocols.md § Logging Protocol` and `docs/Reference/Logging.md` both link here.

## Log levels

| Level | When to use | Example |
|-------|-------------|---------|
| **DEBUG** | Detailed per-step info (a single file edit, a token swap, a config read). Verbose. Disabled by default. | `"Wrote 12 lines to Skills/skills.json"` |
| **INFO** | State transitions (start/end of a task, lock acquired, commit made, file moved). Default level. | `"Claimed Tasks/Code/2026.06.14-foo.md"` |
| **WARN** | Recoverable errors, degraded state, audit anomalies. Should be reviewed but not blocking. | `"Skill registry gate: 76 broken refs (pre-existing drift)"` |
| **ERROR** | Hard failures that require agent action. Always logged. | `"Push failed: non-fast-forward, manual rebase required"` |

Set `$env:ORCHESTRATOR_LOG_LEVEL = 'DEBUG'` to enable verbose logging. Default is INFO.

## Format

Every log line has the format:

```
[timestamp] [agent-id] [level] [phase] message
```

Example:

```
[2026-06-14T02:43:18Z] [code-134258997599883-576038] [INFO] [code] Claimed Tasks/Code/2026.06.14-mcp-2-fleet-auth.md
```

The `[phase]` is the agent's role (`code`, `review`, `rescue`, `audit`, `cowork`, etc.).

## Verbosity control

- **`ORCHESTRATOR_LOG_LEVEL`** env var: `DEBUG` / `INFO` / `WARN` / `ERROR`. Default `INFO`.
- **`ORCHESTRATOR_LEAN=1`** env var: enables lean mode for a single session (compresses status output, lazy-loads references).

## Workflow Events Log

A separate append-only JSONL notification board at `Tasks/Logs/workflow-events.log`. Every agent emits events for cross-agent coordination.

| Function | Purpose |
|----------|---------|
| `Write-WorkflowEvent` | Append an event (SESSION_START, CLAIM, RELEASE, MOVE, COMMIT, PUSH, CONNASCENCE_BLOCK, FILE_LOCKED, CONFUSION, RESCUE, HANDSHAKE, SIGN_OFF) |
| `Get-WorkflowEvents` | Read events for a given agent ID (uses per-agent offset) |

Functions are exported from `SalmonRun.WorkflowEvents` (a submodule of `SalmonRun.Core`).

## Audit log

A separate append-only JSONL audit trail at `Tasks/Logs/Audit/<domain>/audit.jsonl`. Every API call is logged with hash-chain signing.

- Domains: `Bookkeeper`, `marketer`, `web`, `deploy`, `adhoc`
- Functions: `Invoke-ApiCall`, `Write-AuditEntry`, `Get-AuditTrail` (from `SalmonRun.Audit`)
- Every entry is signed (the previous entry's hash is part of the new entry's signature) so tampering is detectable.

## Output destinations

| Destination | What goes there | Who writes |
|-------------|-----------------|------------|
| `Tasks/Logs/agents/<agent-id>.log` | Per-agent setup log | Every agent (via `Write-SetupLog`) |
| `Tasks/Logs/agents/<agent-id>.heartbeat` | Heartbeat timestamp (1 line) | Every agent |
| `Tasks/Logs/agents/<agent-id>.pid` | Process ID (1 line) | Every agent |
| `Tasks/Logs/workflow-events.log` | Cross-agent events | Every agent (via `Write-WorkflowEvent`) |
| `Tasks/Logs/Audit/<domain>/audit.jsonl` | API audit trail | Modules that make external API calls (via `Write-AuditEntry`) |
| `Tasks/Logs/orchestrator-<pid>.log` | Orchestrator run log | The orchestrator |
| `Tasks/Logs/Audit/screenshots/` | Playwright action screenshots | Modules using Playwright |
| `/var/log/` (containers) | Container stdout/stderr | Every container (captured by `docker service logs`) |
| `/workspace/logs/YYYY-MM-DD.log` | Daily event log | Containers (via POST to `http://sentry:29999/log`) |

## Privacy

- **No plain-text credentials**: secrets are never written to logs. Only the secret *name* (e.g., `ORCHESTRATOR_GATEWAY_TOKEN`) is logged.
- **No PII**: Personally Identifiable Information (full names, addresses, phone numbers, SSNs) is never logged.
- **No chat content**: Telegram/Signal message bodies are not logged. Only the dispatch event (`CLAIM`, `RELEASE`, `MOVE`) is logged.
- **Audit trail can be redacted**: `Get-AuditTrail` supports redaction of secret values via `Write-AuditEntry -SecretValue` (the value is replaced with `***REDACTED***` in the audit entry).

## Related skills

- `Skills/Orchestrator/Personas/Shared/protocols.md § Logging Protocol` — agent-side contract (now points here)
- `docs/Reference/Logging.md` — opencode CLI conventions (now points here)
- `Skills/Orchestrator/Personas/Shared/tool-baseline.md § Log levels` — quick reference for the common baseline
- `SalmonRun.Core` — `Write-SetupLog`, `Write-WorkflowEvent` functions
- `SalmonRun.Audit` — `Invoke-ApiCall`, `Get-AuditTrail` functions
- `docs/Reference/Logging.md` — full opencode CLI conventions
