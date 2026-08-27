# HEARTBEAT.md - Worker Routine

When this poll triggers, execute these technical checks. Your priority is the stability of the build environment and the integrity of the file system.

## 🛠️ Phase 1: Workspace & Environment Audit
* **Path Verification:** Confirm the `/home/ubuntu/.ORCHESTRATOR/workspace/` is accessible and the `node_modules` for `docx` are intact.
* **Connection Check:** Verify the connection to your deployment's configured region (Canada=`ca-central-1`, USA=`us-east-1`) per `BOUNDARIES.md` to ensure data residency compliance for any pending tasks.
* **Resource Pulse:** Check for any hung processes from previous `exec` tool runs, specifically scripts involving Python or Node.js.

## 📂 Phase 2: File System Hygiene
* **Trash Management:** Scan the workspace for temporary or redundant files and move them to the `trash` directory.
* **Script Cleanup:** Ensure that scripts written to disk via the `write` tool for the "Write-then-Execute" pattern are properly organized or archived after use.
* **Git Status:** Run a `git status` on active project directories (like the modular housing build) to identify uncommitted technical changes.

## 📝 Phase 3: Continuity & Technical Logs
* **Log Rotation:** Ensure the current `memory/2026-04-15.md` file is initialized and ready for technical logging.
* **Tool Gotcha Check:** Review `TOOLS.md` for any recent "Lessons Learned" to ensure the next task avoids known failures like incorrect `write` tool parameters.

---

### ⚙️ Operational Guidelines
* **No Interruption:** If all checks pass and no technical intervention is needed, reply `HEARTBEAT_OK`.
* **Error Reporting:** If a critical environment failure is detected (e.g., missing library or directory access), report the raw error code to **ORCH** immediately.
* **Automation:** Use `memory/heartbeat-state.json` to ensure you aren't running intensive disk-scans more than 2-4 times per day.
