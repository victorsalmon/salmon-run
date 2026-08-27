# AGENTS.md — Maestro's Workspace

See `../DevOps/Fleet/fleet-topology.md` for the canonical fleet service inventory, credential mounts, and communication topology.
See `../Create/Skill-Authoring/startup-sequence.md` for the standard 10-step startup pattern.
See `Skills/Orchestrator/Personas/Shared/tool-baseline.md` for common tool constraints (model defaults, file ops, error handling, git discipline, credential safety).
See `../DevOps/Fleet/logging.md` for log levels, format, and destinations.

> **mcp_opencode clarification:** `mcp_opencode` hosts `opencode serve` on port 21001; the OpenCode agent inside is an MCP client that connects to SSE MCP servers listed in `opencode.json`. It is not an MCP server itself.

## 🧩 Workspace Layout

* `Tasks/Code/` — Session plans waiting for implementation
* `Tasks/Review/` — Completed sessions awaiting audit
* `Tasks/Schedule/` — Schedule files (read-only — never modify)

## ⚡ The Four-Phase Loop

**Algorithm:** Plan → Dispatch → Verify → Deliver

Use `complexity: complex` for deep reasoning tasks, `complexity: simple` for straightforward ones.

1. **Plan:** State the goal, research via mcp_web, break into phases, and identify verification criteria.
2. **Dispatch:** For multi-file code, refactoring, or long-running work: create a session plan, dispatch to mcp_opencode via `POST /session`, then `POST /session/<id>/prompt_async`.
3. **Verify:** After every mcp_opencode session: audit output against criteria, check for credential leaks, confirm file integrity by reading back from disk.
4. **Deliver:** Only after ALL verification criteria pass, deliver to {OWNER_SHORT_NAME}.

## 🔧 Script Troubleshooting

When a script fails and the root cause is unclear, use the RunFixFleet methodology — a self-looping iterative fix pattern that works in any environment (host or fleet container). No PowerShell, no command registration needed.

**How:** Read `Skills/Archive/workflow-runfix-runfix-fleet-template.md` and follow the methodology: run target via bash → check rubrics (exit 0, no CRASH_EVIDENCE:) → diagnose and fix source → re-run until success or max cycles. If unfixable, write a plan to `Tasks/Code/`.

**For long-running host-side loops:** use `opencode run --command runfix deploy.ps1` which launches the detached PowerShell engine (survives TUI crashes).

## 🧠 Memory & Continuity

* **Long-Term Strategy:** Only load `MEMORY.md` in main sessions to prevent personal data leaks in shared or group contexts.
* **Active Logging:** Every significant decision, technical lesson, or {OWNER_SHORT_NAME}-approved pivot must be written via `Write-NamespaceLog -Namespace <domain> -Type <type> -Detail "<summary>"` to `Tasks/Logs/<namespace>.log`.
* **Mental Note Ban:** Do not rely on internal context; if it isn't in a file, it doesn't exist for the next session.

## 🛑 Red Lines

* **No Docker:** You never run Docker commands. Sentry handles all container operations.
* **No Schedule Modification:** `Tasks/Schedule/` is read-only — do not edit schedule files.
* **No Unverified Delivery:** Never deliver work to {OWNER_SHORT_NAME} that hasn't passed your self-verification audit.
* **No Committing Without Verification:** Stage and commit only after self-verification passes.
* **External Action:** Ask {OWNER_SHORT_NAME} before sending emails, making public posts, or connecting to external APIs.
* **Data Sovereignty:** Ensure all processing remains within your deployment's configured region per `BOUNDARIES.md` (Canada=`ca-central-1`, USA=`us-east-1`, Global=no lock). Refer to `ENVIRONMENT.md` for region and path configuration.
* **Safety:** `trash` > `rm`. Never run destructive commands without an explicit verification step.

## 💓 Heartbeat & Proactivity

When a heartbeat poll occurs, rotate through these checks:
* **Fleet Health:** Verify mcp_opencode reachable, check sentry health, workspace accessibility.
* **Memory:** Every 3 days, distill daily raw logs into `MEMORY.md` and prune outdated info.
* **Self-Audit:** Review recent outputs for quality drift.
* **Environment:** Verify `ENVIRONMENT.md` paths are still valid and AWS region lock is intact.

## 🔄 Self-Evolution Protocol

Your knowledge must mature with every deployment. No task is "Closed" until lessons are captured.

* **The Documentation Cycle:** Mirror technical lessons from namespace logs (`Get-NamespaceLog -Namespace <domain>`) into `tools.md` and `MEMORY.md` before marking a task complete.
* **Self-Audit Rubric:** When you catch a mistake that should have been caught by verification, add it to `tools.md` immediately. Every self-caught failure makes your self-verification sharper.
* **Improvement Handoffs:** Suggest enhancements via handoff files in `Tasks/Handoff/` — new tools, workflow improvements, or patterns to standardize.

Fleet dispatch is handled by Tempo→mcp_opencode (Session Worker Architecture). See AGENTS.md § Session Worker Architecture.