# Opencode ACP Best Practices

This document defines best practices for VERI to delegate work to the `mcp_opencode` container (a single opencode serve instance on port 21001) as part of the Two-Agent Workflow (see `opencode-two-agent.md`). All agents should prioritize delegating heavy technical work to the mcp_opencode container — agent compute is metered separately from coding subscription keys, so offloading saves cost and context.

## Architecture Overview

```
VERI ──HTTP──► mcp_opencode (opencode serve)
                          │
                          ├── Session 1 (context A)
                          ├── Session 2 (context B)
                          └── Session N (context N)
```

The mcp_opencode container runs `opencode serve` inside a Docker Swarm service. It handles multiple concurrent sessions with isolated context windows.

## Task File Format

Every task dispatched to a opencode container is a markdown file. Follow this structure:

```markdown
# Task: <concise description>

## Objective
<One sentence describing the desired outcome>

## Context
- Repository: /workspace/<repo-name>
- Relevant files: <list specific files or directories>
- Constraints: <data residency, style, naming conventions>

## Deliverables
- <specific output file or artifact>
- Commit message: [OC-<Id>] <description>

## Verification
- [ ] <test command or validation step>
- [ ] <lint/typecheck command>

## Do NOT
- <things to avoid>
```

### Task File Rules

1. **One session per discrete task.** `opencode run --file` creates one session context. Bundle related subtasks that share context; split unrelated work into separate tasks.
2. **Be specific about file paths.** The opencode agent inside the container discovers files via `glob` and `grep` — give it exact paths when known to reduce exploration overhead.
3. **Include verification commands.** Always specify how to validate the result (test suite, linter, typecheck). The opencode agent can run these and self-correct.
4. **Specify the commit prefix.** Use `[OC-<Id>]` so git history is traceable.

## opencode Configuration (opencode.json)

Each repository can provide its own `opencode.json` at the root. The opencode container auto-discovers it when `cd`'d into the repo directory. If no `opencode.json` exists, the container falls back to defaults.

### Recommended opencode.json for ORCHESTRATOR Projects

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": "opencode-go",
  "model": "deepseek-v4-flash",
  "apiKey": "{env:OPENCODE_GO_KEY}",
  "reasoning": {
    "effort": "max"
  },
  "permission": {
    "edit": "allow",
    "bash": "allow",
    "read": "allow",
    "glob": "allow",
    "grep": "allow"
  },
  "compaction": {
    "auto": true,
    "prune": true
  },
  "snapshot": true
}
```

### Key Configuration Points

- **`apiKey: "{env:OPENCODE_GO_KEY}"`** — Reads the API key from the environment variable set by the container entrypoint. Never hardcode keys.
- **`reasoning.effort: "max"`** — Required when using `deepseek-v4-flash`. Without `effort: max` the model runs at default reasoning effort, which underperforms for code generation tasks.
- **`permission: "allow"`** for all tools — opencode containers are non-interactive (no human to approve). Auto-approve everything.
- **`compaction.auto: true`** — For large tasks that exceed context, opencode auto-compacts old messages. This prevents context overflow on long sessions.
- **`snapshot: true`** — Enables `/undo` capability within a session. Useful when the agent makes a wrong edit.

## Using opencode Agents Inside Tasks

opencode supports specialized agents (Build, Plan, General, Explore) and custom subagents. When writing task files, you can instruct the opencode container to use specific agents:

### Plan → Build Pattern (Recommended for Complex Tasks)

Instruct the task to use Plan mode first, then Build:

```markdown
## Instructions

1. First, analyze the codebase in **Plan mode** (no edits). Identify all files that need changes and describe the approach.
2. Then switch to **Build mode** and implement the changes.
3. Run the test suite to verify.
4. Commit with message: [OC-1] <description>
```

This matches opencode's built-in Tab-key mode switching but works in non-interactive `opencode run` mode through the task prompt.

### Subagent Usage

opencode's `@general` and `@explore` subagents can be invoked for parallel exploration:

```markdown
## Instructions

Use @explore to find all files that import from `src/legacy/` and list them.
Then use @general to refactor each file to use the new `src/modern/` API.
```

**Subagent limits:**
- Max 2 levels deep to prevent runaway context consumption
- Each subagent gets its own session — results flow back to the parent
- Give subagents narrow, verifiable goals with clear output paths

## Using opencode Skills Inside Tasks

opencode discovers `SKILL.md` files from `.opencode/skills/`, `.claude/skills/`, or `.agents/skills/` directories. If a repository includes skill definitions, the opencode agent can load them via the `skill` tool.

To make skills available in opencode containers:
1. Place skill directories in the repository under `.opencode/skills/<name>/SKILL.md`
2. The skill is auto-discovered when opencode starts in that repo
3. Reference the skill in your task: `"Use the git-release skill to draft release notes"`

## Using opencode Server API (Advanced)

For programmatic control beyond trigger files, opencode exposes an HTTP server:

```bash
# Start a persistent opencode server inside the container
opencode serve --port 21001 --hostname 0.0.0.0

# Create a session and send a message
curl -X POST http://mcp_opencode:21001/session -d '{}'

# Use temp file for structured payloads (avoids quoting issues)
cat > /tmp/payload.json << 'EOF'
{"parts":[{"type":"text","text":"Explain auth in this codebase"}]}
EOF
curl -X POST http://mcp_opencode:21001/session/<id>/message \
  -H "Content-Type: application/json" \
  -d @/tmp/payload.json

# Send async (no wait) — same temp file pattern
cat > /tmp/payload.json << 'EOF'
{"parts":[{"type":"text","text":"Refactor the auth module"}]}
EOF
curl -X POST http://mcp_opencode:21001/session/<id>/prompt_async \
  -H "Content-Type: application/json" \
  -d @/tmp/payload.json
```

### Server API Use Cases

| Endpoint | Use Case |
|----------|----------|
| `POST /session` | Create a new coding session |
| `POST /session/:id/message` | Send a task and wait for response |
| `POST /session/:id/prompt_async` | Fire-and-forget task dispatch |
| `GET /session/:id/message` | Read session messages (results) |
| `GET /session/:id/diff` | Get file changes made by the session |
| `POST /session/:id/abort` | Cancel a runaway session |
| `GET /event` | SSE stream for real-time progress |

### Server API Notes

- Set `OPENCODE_SERVER_PASSWORD` for basic auth protection
- The `--attach` flag on `opencode run` reuses an existing server (avoids cold boot)
- Use `--format json` for structured output parsing: `opencode run --format json "task"`

## Using ACP (Agent Client Protocol)

opencode supports ACP via `opencode acp` — a stdio-based JSON-RPC protocol for editor/agent integration. While primarily designed for IDEs (Zed, JetBrains, Neovim), ACP can be used to embed opencode as a subprocess in custom tooling:

```bash
# Start ACP server (communicates via stdin/stdout)
opencode acp --cwd /workspace/my-repo

# Or bind to a port for network access
opencode acp --port 5000 --hostname 0.0.0.0
```

### ACP vs Server API vs Trigger Files

| Method | Interface | Best For |
|--------|-----------|----------|
| **Trigger files** | Filesystem | Simple task dispatch, existing worker pattern |
| **Server API** | HTTP REST | Programmatic control, session management, streaming |
| **ACP** | stdio JSON-RPC | Embedding in editors, real-time bidirectional communication |

**Recommendation:** Use trigger files for standard task dispatch. Use the Server API when VERI needs fine-grained session control (abort, diff inspection, streaming progress). ACP is not needed for ORCHESTRATOR's current architecture.

## Key Cycling & Rate Limit Handling

All 4 opencode coding keys (`opencode_go_key1` through `opencode_go_key4`) are mounted on every opencode container. The worker entrypoint auto-rotates through keys on auth/rate-limit errors:

```
Key 1 → (rate limit) → Key 2 → (rate limit) → Key 3 → ... → Key 4 → (all exhausted) → error
```
### Fallback Priority

The `code-runner.sh` uses this key priority:
2. `OPENCODE_GO_KEY` (opencode Go — primary coding key)

## What to Push to Opencode vs. Keep in ORCHESTRATOR

### Push to Opencode
- Multi-file code generation and refactoring
- Research synthesis across many files
- Long-running scripts and build tasks
- Anything requiring subagents or multiple tool calls
- Tasks that would consume significant agent context tokens
- LSP-powered analysis (go to definition, find references)
- Any task where the repo provides its own `opencode.json`

### Keep in ORCHESTRATOR
- Planning, evaluation, editing, polish (VERI's role)
- Single-file audits under 50 lines
- Orchestration and routing decisions (ORCH's role)
- Server API session management
- Credential/secret operations
- Tasks requiring human interaction (Signal messages, approval prompts)

## Git Workflow

opencode containers commit with a prefixed message format:

```
[OC-1] implement-user-auth-module
```

### Best Practices

1. **Always specify the commit prefix** in the task file. This ensures traceability.
2. **opencode containers push automatically** if git credentials are configured. If push fails, the task still succeeds (commit is local).
3. **Use `--amend` with caution.** opencode containers should not amend commits from other agents.
4. **Branch strategy:** For parallel dispatch, use the helper script at `Infrastructure/git-task-branch.sh` which handles the full lifecycle: `start` (create branch), `commit` (stage+commit), `finish` (merge back to main). For isolated experiments, manually instruct: `"Create branch feat/auth-module before starting work"`.

## Error Handling

### Reading Error Results

When an opencode task fails, check the outbox:
- `{task-name}_result.md` — stdout from opencode (may contain partial output)
- `{task-name}_stderr.log` — stderr capture with error details
- Health endpoint shows `"error"` status with `exit_code`

### Common Failure Modes

| Error Pattern | Cause | Resolution |
|---------------|-------|------------|
| `rate-limit` / `429` | All coding keys exhausted | Wait for cooldown, dispatch to different container |
| `unauthorized` / `401` | Invalid or expired key | Check AWS SM for rotated keys |
| `opencode binary not found` | Image build issue | Rebuild `code-worker:local` image |
| `exit code 1` (no rate limit) | Task logic error | Read stderr for specifics, fix task prompt |
| Container shows `busy` indefinitely | Hung opencode process | Check health endpoint, consider `POST /session/:id/abort` |

### Retry Strategy

1. **Non-rate-limit errors:** Do not retry the same task verbatim. Read stderr, fix the task prompt, and re-dispatch.
2. **Rate-limit errors:** The container auto-retries with the next key. If all 4 keys are exhausted, wait 60s and re-dispatch.
3. **Container crash:** Docker Swarm restarts the container. Re-dispatch the task after health endpoint returns `idle`.

## Environment Variables Reference

| Variable | Source | Purpose |
|----------|--------|---------|
| `OPENCODE_GO_KEY` | Container entrypoint (from Docker secret) | Primary API key for opencode |
| `OPENCODE_GO_KEY1`-`4` | Docker secrets (mounted on all opencode containers) | Fallback keys for rotation |

| `CODE_ID` | Container env | 1-based instance identifier |
| `WORKSPACE_REPOS` | Container env (from `install.json`) | Comma-separated repo URLs to clone |
| `OPENCODE_CONFIG` | Optional container env | Custom opencode.json path |
| `OPENCODE_CONFIG_CONTENT` | Optional container env | Inline JSON config (highest precedence) |
| `OPENCODE_BIN_PATH` | Dockerfile | Path to opencode native binary |
| `OPENCODE_DISABLE_AUTOCOMPACT` | Optional | Set `true` to disable auto-compaction |

## opencode.json Variable Substitution

Use `{env:VAR_NAME}` to reference environment variables and `{file:path}` to reference file contents:

```json
{
  "provider": {
    "openrouter": {
      "options": {
        "apiKey": "{env:OPENCODE_GO_KEY}"
      }
    }
  },
  "instructions": ["AGENTS.md", "{file:.opencode/context.md}"]
}
```

This is the recommended way to inject secrets — never hardcode API keys in `opencode.json`.


