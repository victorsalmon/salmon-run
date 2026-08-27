# HEARTBEAT.md - Base Agent Routine

When this poll triggers, follow these checks in order. If no action is required after completing the rotation, reply `HEARTBEAT_OK`.

## 📡 Phase 1: Environment & Infrastructure (High Priority)
* **Workspace Verification:** Confirm the workspace path in `ENVIRONMENT.md` is accessible and the required Node.js modules are intact.
* **Connectivity Check:** Verify connection to your deployment's configured region (Canada=`ca-central-1`, USA=`us-east-1`) per `BOUNDARIES.md`, and any configured external services (Signal).
* **Docker Health:** If running in a container, check Docker service status and overlay network connectivity.
* **Resource Pulse:** Check for hung processes from previous tool runs.

## 🧠 Phase 2: Active Tasks & Memory
* **Task Review:** Review recent namespace log entries via `Get-NamespaceLog -Namespace <domain> -Since (Get-Date).AddDays(-1)` for in-progress or stalled tasks.
* **Memory Distillation:** If significant progress was made in the last 4 hours, ensure it is logged via `Write-NamespaceLog`.
* **Self-Audit:** Review the last 2-3 outputs for quality drift. Are you still meeting the verification standards defined in `PROTOCOLS.md`?

## 🧹 Phase 3: Long-Term Maintenance (Rotate 1x Daily)
* **Memory Pruning:** Review raw logs from the past 48 hours. Distill lessons into `MEMORY.md` and prune outdated entries.
* **Tool Verification:** Review `tools.md` for accuracy. Remove deprecated paths or patterns and add any new "gotchas" discovered since the last heartbeat.
* **Environment Alignment:** Verify `ENVIRONMENT.md` paths and configuration are still current. Flag any drift to {OWNER_SHORT_NAME}.
* **Sovereign Audit:** Confirm all active agents or containers are still locked to their configured regions per `BOUNDARIES.md`.

---

### ⚙️ Operational Guidelines
* **Proactive Outreach:** If an important email or message is found during triage, cross-post a summary to {OWNER_SHORT_NAME} on Signal at {OWNER_PHONE} immediately.
* **Quiet Time:** Between 23:00 and 08:00 (Pacific), suppress non-urgent notifications unless they represent a critical system failure.
* **State Tracking:** Record the timestamp of these checks in `memory/heartbeat-state.json` to avoid redundant API calls.