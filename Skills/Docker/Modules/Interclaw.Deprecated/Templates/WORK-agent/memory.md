# MEMORY.md - Technical Reference & Execution Ledger

This file is the long-term repository for verified code patterns, environment paths, and execution lessons.

## 💻 Environment & Paths
* **Work Directory:** `/home/ubuntu/.ORCHESTRATOR/workspace/` is the root for all persistent operations.
* **Node.js Modules:** The `docx` library (v9.6.1) is located at `/home/ubuntu/.ORCHESTRATOR/workspace/node_modules/docx/dist/index.mjs`.
* **Cloud Endpoint:** All AWS operations must target your deployment's configured region (Canada=`ca-central-1`, USA=`us-east-1`) per `BOUNDARIES.md`. Global tier has no regional lock.
* **Auth Credentials:** Credentials must be accessed via environment variables; never hardcode or echo them in chat.

## 🛠️ Verified Implementation Patterns
* **ESM Imports:** Always use `await import()` for the `docx` library to ensure compatibility with the `.mjs` distribution.
* **File Writing:** Always use the `write` tool with the `file_path` parameter. Using `path` or `content` will trigger a "Missing required parameter" error.
* **Complex Scripts:** For any script involving backticks (`) or complex template literals, write the script to a file first using the `write` tool, then execute it via `exec`.
* **String Sanitization:** Use `.trimEnd()` for Node.js string operations; `rstrip()` is only for Python.

## ⚠️ Tool Constraints & "Gotchas"
* **Python Heredocs:** These are fragile and often corrupt backtick characters. They are deprecated in favor of the "Write-then-Execute" pattern.
* **API Rate Limiting:** Limit batches to 1-3 requests with a 150-300ms delay to prevent socket timeouts.
* **Image Processing:** Vision capabilities are currently disabled. Save images to `/tmp/` and describe them manually if needed.
* **Deletion Rule:** Use `trash` for file removal to ensure recoverability.

## 📝 Recent Technical Context
* **Current Tooling:** Actively utilizing **ORCHESTRATOR (v4.1)**, **n8n**, and **Pabbly Connect** for agentic deployments.
* **Hardware Context:** Local inference testing occurs on **Lenovo M70q** (11th Gen i5) units.
* **Project Reference:** Modular housing build logic should reference standards verified for the **Prince George** build.

---

### 🔄 WORK Memory Maintenance
* **Log Success:** When a new complex automation or script pattern works, document the import paths and parameters here immediately.
* **Update Versions:** If ORCHESTRATOR or local Node.js packages are updated, reflect those changes here to prevent WORK from using outdated syntax.
* **Daily Sync:** At the end of a task, cross-reference this with `memory/YYYY-MM-DD.md` to ensure no "Lessons Learned" are lost.
