# TOOLS.md - Worker Technical Reference

This file contains verified technical paths, syntax requirements, and execution patterns for the **WORK** environment.

## 📂 System Paths & Environment
* **Root Workspace:** `/home/ubuntu/.ORCHESTRATOR/workspace/`.
* **Node.js Modules:** The `docx` library (v9.6.1) is located at `/home/ubuntu/.ORCHESTRATOR/workspace/node_modules/docx/dist/index.mjs`.
* **Regional Lock:** All AWS calls must target your deployment's configured region (Canada=`ca-central-1`, USA=`us-east-1`). Global tier has no regional lock. See `BOUNDARIES.md` for your tier.
* **Temporary Storage:** Use `/tmp/` for volatile data; move persistent artifacts to the workspace.

## 🛠️ Execution Patterns (The "Worker's Way")
* **Write-then-Execute:** Never execute complex scripts or those containing backticks (`) directly via `exec`. Always use the `write` tool to create a `.js` or `.py` file first, then run it.
* **ESM Compatibility:** When using `docx` in Node.js, use dynamic imports: `const docx = await import('/home/ubuntu/.ORCHESTRATOR/workspace/node_modules/docx/dist/index.mjs');`.
* **String Manipulation:** Use `.trimEnd()` for Node.js string operations. Do not use Python's `rstrip()` in JavaScript environments.

## ⚠️ Tool Constraints & Parameters
* **`write` Tool:** You MUST use the `file_path` parameter. The parameters `path` or `content` are invalid and will cause failure.
* **API Rate Limiting:** Limit batch operations to 1-3 requests with a 150-300ms delay to prevent socket hangs.
* **Deletion:** Always use the `trash` tool for file removal. The `rm` command is discouraged.

## 🤖 CODE Container Usage

CODE containers are trigger-based CODE containers that run `opencode run --file <task>` against markdown task files dropped in their inbox. They are **the preferred execution layer** for heavy technical work because ORCHESTRATOR agent compute is metered on top of your existing coding subscription.

### Trigger Format
To dispatch work to a CODE container, write two files to its inbox:
1. `{task-name}.md` — the task description in markdown
2. `{task-name}.md.trigger` — an empty trigger file that signals the worker to begin

Inbox path: `/workspace/code_<Id>_inbox/` (e.g., `code_1_inbox` for CODE_ID=1)
Outbox path: `/workspace/code_<Id>_outbox/` — contains results, stderr logs, and moved task files

### What to Push to CODE vs. Execute Here
- **Push to CODE:** Multi-file code generation, refactoring, research synthesis, long-running scripts, anything requiring subagents or multiple tool calls, and any task that would consume significant ORCHESTRATOR agent context tokens.
- **Execute here:** Single-file edits under 50 lines, quick syntax fixes, verifications that require reading local files already in your context, and anything VERI's plan explicitly assigns to you.

When VERI's plan involves heavy execution, you may **offload the implementation to CODE** and then audit the result from the CODE outbox before delivering to VERI. This preserves your iteration budget and reduces token spend.

### Session Strategy
- **One session per discrete task.** CODE containers process tasks sequentially from their inbox. Do not bundle unrelated work into a single large task file unless the subtasks depend on each other.
- **Parallelize across multiple CODE containers** when tasks are independent. If you have 3 unrelated bugs, drop one in `code_1_inbox`, one in `code_2_inbox`, and one in `code_3_inbox`.
- **Do not spin up multiple sessions inside a single task file** expecting parallel subagents unless the task explicitly asks for parallel exploration. The container runs `opencode run --file` which creates one session context.

### Subagent Usage
Inside a CODE task, you can instruct the coding runtime to use subagents via standard opencode directives (e.g., `Task` tool calls, `subagent` invocations, or `@agent` mentions depending on the opencode version). Best practices:
- Give subagents **narrow, verifiable goals** with clear output paths.
- Limit subagent depth to 2 levels to avoid runaway context consumption.
- Always specify a single output file for the final deliverable so the parent task can extract results cleanly.

### Key Cycling & Rate Limits
Coding API keys (`opencode_go_key1` through `opencode_go_key4`) are mounted as Docker secrets. When a key hits a subscription limit, the CODE container will fail with an authentication or rate-limit error.

**Key Timeout Pattern (if configured in AWS Secrets Manager):**
Each key may have an associated `opencode_go_key<N>_timeout` value (Unix timestamp or ISO 8601) in the AWS Secrets Manager JSON blob under `ORCHESTRATOR/Production/<Project>`. Before dispatching to CODE:
1. Check the current key's timeout.
2. If the key is still in cooldown, rotate to the next key by selecting a different CODE container configured with a different key.
3. After a timeout expires, the key returns to the rotation pool.

If no timeouts are configured, fallback to round-robin across all four keys and retry once on rate-limit errors before escalating to ORCH.

### Reading Results
CODE containers write output to `/workspace/code_<Id>_outbox/`:
- `{task-name}_result.md` — stdout from `opencode run`
- `{task-name}_stderr.log` — stderr capture
- The original task file and trigger are also moved to the outbox on completion

Check the container's health endpoint at `http://code-<Id>:3000` for current status (`idle`, `busy`, `error`).

## 🏗️ Hardware-Specific Context
* **Testing Environment:** Local inference and script testing are performed on **Lenovo M70q** hardware (11th Gen i5).
* **Project Reference:** Building logic for modular housing should reference the standards established during the **Prince George** build.

---

### 🔄 WORK Maintenance Note
* **Documentation Rule:** If a new library is installed or a specific shell command is verified as the "gold standard," it must be added here immediately.
* **Audit Rule:** **VERI** will fail any output that deviates from the paths or patterns defined in this file.
