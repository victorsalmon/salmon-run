# PROTOCOLS.md - Universal Agent Protocol Standards

This file defines the universal protocol rules, verification formats, iteration limits, and delegation standards that all agents follow. It is the canonical reference — role-specific files reference this instead of duplicating these rules.

When protocol rules change, update this file. All other files inherit from here.

## Verification Format

All quality checks (self-verification in solo mode, VERI audits in team mode) use the binary PASS/FAIL standard:

### PASS Criteria
A task earns a PASS when **all** of the following are true:
1. **Goal Alignment:** The output directly addresses the original goal set in the planning phase.
2. **Technical Accuracy:** Tool parameters, code syntax, and library paths are correct per `tools.md` and `ENVIRONMENT.md`.
3. **Credential Safety:** No plain-text credentials, API keys, or tokens appear in the output.
4. **Data Residency:** All processing and references target the deployment's configured region per `BOUNDARIES.md` (Canada=`ca-central-1`, USA=`us-east-1`, Global=no lock).
5. **Platform Formatting:** Signal/Telegram outputs use bullet lists (no tables), and URLs are wrapped in `<>`.
6. **File Integrity:** Written files have been read back from disk to confirm content matches intent.

### FAIL Response
A FAIL must include:
* **Specific Error:** What exactly is wrong (not "it doesn't work").
* **Location:** File path, line number, or API call where the error occurs.
* **Required Fix:** The exact change needed to resolve the issue.

### FAIL Response (Team Mode — VERI to mcp_opencode container)
When VERI issues a FAIL, the feedback follows the **Coaching Loop** format:
* **Success Markers:** Identify specific logic blocks, shell commands, or output sections that functioned correctly.
* **Failure Analysis:** Map the error log to the likely root cause (e.g., library pathing vs. logic error vs. parameter mismatch).
* **Next-Step Directive:** Explicitly state what must change (e.g., "Pivot strategy to Node.js" or "Update library path per ENVIRONMENT.md").

mcp_opencode container receives this structured feedback and applies the Next-Step Directive immediately. VERI then re-audits the revised output.

### PASS Response
A PASS confirms delivery eligibility with any notes for the record.

## Iteration & Budget Rules

### Iteration Budget Management
Each task starts with a budget of **3 iterations**. The budget adjusts dynamically based on performance:

| Condition | Action | Budget Impact |
|-----------|--------|---------------|
| New Error Code | Free Iteration | No cost to current budget (max 2 free iterations per task) |
| Product Improving | Incentive Bonus | +1 to budget (max 5 total) |
| Complete Pivot | Strategic Reset | +3 to budget (max 8 total) |
| Stagnation | Iteration Cost | Standard −1 from current budget |

A "new error code" means genuinely novel — a different class of error than the previous iteration. Gaming this by introducing trivial variations is itself a stagnation signal.

### Mandatory Stop Rules
Regardless of remaining budget, the iteration **must** stop and escalate to {OWNER_SHORT_NAME} (solo) or ORCH (team) when any of these conditions is met:
* **Error Loop:** The same error code is encountered **5 times** within an 8-iteration cycle.
* **Exhaustion:** The total iteration count reaches **8**.
* **Dead End:** Technical logic repeats a failed pattern **twice** without modification.

When a stop rule triggers, the agent must document the failure pattern via `Write-NamespaceLog -Namespace errors -Type FAILURE_PATTERN -Detail "<pattern>"`, update `tools.md` with the failure mode, and escalate immediately. Do not continue.

### Budget Reset
The iteration budget **resets per task**. Each new task from ORCH or {OWNER_SHORT_NAME} starts fresh at 3 iterations. Carry-over between tasks is not permitted.

### Write-then-Execute Pattern
For any script with complex syntax, backticks, or multi-line content:
1. Use the `write` tool to create a file on disk first.
2. Execute the file from disk.
3. Read back the file to verify content integrity.
4. **Never** use inline Python heredocs or bash heredocs for complex scripts.

### API Discipline
* **Batch Size:** Limit to 1-3 requests per batch.
* **Delay:** 150-300ms between batches.
* **Backoff:** On rate-limit errors, wait 2 seconds then retry once. On second failure, report to {OWNER_SHORT_NAME}.

## Delegation Standards

### Solo Agent (BASE)
* No delegation occurs. The agent plans, executes, and verifies in a self-contained loop.
* Self-verification is mandatory before delivery — there is no "solo exception" for skipping QA.

## Workflow Algorithms

### Overview

Three workflow modes govern how tasks move through the team:

| Mode | Trigger | Path | Default n |
|------|---------|------|-----------|
| **Planned Pass** | ORCH tags task `planned` | ORCH → VERI (plan) → [(n−1) × (mcp_opencode → VERI)] → VERI (polish) → ORCH | n=3 |
| **Single Pass** | BASE agent operating solo | BASE (plan) → BASE (execute) → BASE (verify) | n=1 |

ORCH decides the workflow mode based on task complexity. A task with no `workflow` or `complexity` tag is left to ORCH's judgment. {OWNER_SHORT_NAME} can override by specifying `planned`, `classic`, or `complex`/`simple` directly.

### Model Selection

ORCH dispatches tasks with a `complexity` tag. Each role routes that tag to its configured complex or simple model for the deployment's sovereignty tier. ORCH never hardcodes model names.

| Complexity Tag | Meaning | ORCH dispatches with |
|---------------|---------|---------------------|
| `complex` | Multi-step, reasoning-heavy, or architecturally significant tasks | `complexity: complex` |
| `simple` | Routine, basic, single-step, or trivial tasks | `complexity: simple` |
| *(model name)* | Explicit model request by ORCH or {OWNER_SHORT_NAME} | e.g. `model: deepseek-v3.2` |

Each role's `ORCHESTRATOR.json` routing rules map these complexity tags to the role-appropriate model for the sovereignty tier. Roles may also route on model name — requesting a specific model by name activates it directly.

---

## Fleet Command Words

The following table defines how ORCH routes user commands arriving via fleet dispatch (Telegram/Signal) through to VERI. This is distinct from the local opencode CLI Role-Taking Commands table in AGENTS.md.

| You say | ORCH action | VERI action |
|---------|-------------|-------------|
| "Plan" / "I'd like you to plan" | Dispatch to VERI with `workflow: planned, mode: planning-only, complexity: simple` | Enter Plan mode. Assess complexity. Default: plan directly using Flash Max. Escalate to mcp_opencode (V4 Pro) if complex. Write session plan to `Tasks/`. Do NOT implement. |
| "Implement" / "Code this" | Dispatch to VERI with `workflow: planned, mode: implement` | Enter Plan mode FIRST. Assess complexity. Plan with Flash Max (default) or V4 Pro (escalation). Then dispatch Coder (mcp_opencode). Review. Polish. Deliver. |
| "Review" | Dispatch to VERI with `workflow: review` | Dispatch Reviewer (mcp_opencode1 or mcp_opencode2 depending on complexity) to audit. Return results. |
| "Audit" | Dispatch to VERI with `workflow: audit` | Trigger alignment audit per `Skills/Auditor/alignment-audit.md`. Auditor identity: `Skills/Auditor/SKILL.md`. Lifecycle: `Skills/Create/Skill-Authoring/workflow-primitives.md#auditor-workflow`. |

> This table is for fleet dispatch commands arriving via ORCH. Local opencode CLI instances use the Role-Taking Commands table in AGENTS.md.

---

---

## Single Pass Workflow (BASE Solo)

**Algorithm:** BASE (plan) → BASE (execute) → BASE (verify)

No team dispatch. BASE operates as a self-contained solo agent and applies the full loop internally. Self-verification is mandatory before delivery.

1. **Plan:** State the goal, break it into phases, identify verification criteria.
2. **Execute:** Perform the technical work using Write-then-Execute discipline.
3. **Self-Verify:** Audit output against verification criteria.
4. **Deliver:** Present to {OWNER_SHORT_NAME}.

---

## Task Hand-off Format

When delegating or receiving a task, include:

* **Goal:** One-sentence description of what the output should accomplish.
* **Specification:** Output format, file paths, naming conventions, and constraints.
* **Verification Criteria:** The checklist the verifier (or self-verifier) will apply.
* **Deadline Context:** Priority level and any time sensitivity.
* **Workflow Mode:** `planned` (default for complex tasks), `classic` (for straightforward tasks).
* **Mode:** `planning-only | implement | review | audit` — tells VERI which phase to execute and whether to stop after planning (`planning-only` means plan and stop, do not implement).
* **Complexity:** `complex` or `simple` — routes to the role-appropriate model for the sovereignty tier. Omit if ORCH is delegating without a complexity tag.
* **Session:** `fresh` — instructs the receiver to compact prior context, persist via `Write-NamespaceLog`, and start clean. Always include this on new task dispatches.
* **Pass Number:** `1` through `n` (tracked via `{task-id}-plan-pass-{N}.md` naming convention; omit for classic pass).

## Communication Standards

### Platform Rules
* **Signal:** The only authorized control channel. In team mode, only **ORCH** cross-posts replies to {OWNER_NAME} at {OWNER_PHONE}. VERI never communicates directly with {OWNER_SHORT_NAME}. In solo mode (BASE), the agent cross-posts directly. Bullet lists only — no Markdown tables. Links wrapped in `<>`.
* **Telegram:** Bullet lists only. No Markdown tables. Links wrapped in `<>`.
* **Internal (team mode):** Use `orchestration_net` for inter-agent communication. Use `service_net` for service-to-service communication.

## Documentation-First Principle

Before answering any question about your environment, tools, services, capabilities, or how to accomplish a task, you MUST first consult the relevant documentation. This is a standing behavioral rule that applies throughout the entire session — not just at startup.

### Required Reading Order
When faced with a question about what tools or services are available, read these files in priority order until you find the answer:
1. `ENVIRONMENT.md` — workspace paths, service endpoints, region configuration
2. `TOOLS.md` — verified technical paths, integration details, audit rubrics
3. `git-repos.md` — repository registry and their purposes
4. `projects.md` — active projects and client context
5. `docs/` — extended guides (Architecture, Deployment, Operations, etc.)
6. `MEMORY.md` — long-term lessons and strategic context

### Rules
- **No guessing:** If the answer is not found in the documentation, do not speculate. State that the capability is not configured and suggest how to set it up (e.g., "That integration is not in my environment docs. Would you like me to draft a setup plan?").
- **No generic suggestions:** Never respond with generic advice like "look into Google CLI" — check whether the integration exists in your documented environment first.
- **Exception:** Direct questions about the human's preferences, opinions, or business goals (covered by `USER.md` context) do not require documentation lookup.

### Tone
* **Operator Energy:** Technical, fast, direct. No over-explaining, no "softening" bad news, no filler.
* **Results Over History:** Report what happened and what you will do next. No "I've been struggling" narratives.
* **No Disclaimers:** Deliver the conclusion. The reader can ask for context if needed.

## Memory Protocol

Namespace logs (`Tasks/Logs/<namespace>.log`) replace date-based daily logs. Each decision, lesson, or state change is appended to the namespace log matching the domain worked on. To get a full timeline: `Get-NamespaceLog -Namespace <domain>`.

### Compact-and-Persist at Handoff
At every handoff point in a workflow (CODE→VERI, VERI→CODE, VERI→ORCH), the handing-off agent **must**:
1. **Persist:** Write key findings, decisions, and technical lessons via `Write-NamespaceLog -Namespace <domain> -Type <type> -Detail "<summary>"`.
2. **Compact:** Summarize and release working context. Keep only what is needed for the next phase.
3. **Signal:** Only then create `signal.md` and notify the next agent.

This prevents context bloat across passes. Each agent starts its next turn lean, with important context saved to file rather than carried in conversation history.

### Fresh Session on New Task
When ORCH dispatches a new task to VERI or CODE, the receiving agent should:
1. **Compact** any prior working context via `Write-NamespaceLog`.
2. **Clear** the conversation context — treat the incoming task as a fresh session.
3. **Read** only the files needed for this specific task (the plan/directive, plus relevant context files).

mcp_opencode containers start fresh automatically (each `opencode run` invocation is independent). VERI must do this explicitly when receiving a new task signal.

ORCH should include `session: fresh` in task dispatches to signal that the receiver should compact and reset before starting.

### Writing
* **Namespace Logs:** Every significant decision, technical lesson, or {OWNER_SHORT_NAME}-approved pivot goes to `Tasks/Logs/<namespace>.log` via `Write-NamespaceLog -Namespace <domain> -Type <type>`. Namespace matches the domain: `room-rentals`, `intersite-consulting`, `deploy`, `Bookkeeper`, `sentry`, `plan`, `audit`, `cowork`, `base`, `infrastructure`, `skill-dev`.
* **MEMORY.md:** Long-term strategy, environment pointers, and persistent lessons. Updated every 3 days during heartbeat distillation.
* **No Mental Notes:** If it isn't in a file, it doesn't exist for the next session.

### Discovery
If you know the date but not the namespace: `Select-String "2026-06-15" Tasks/Logs/*.log` finds the right file. If you know the domain: `Get-NamespaceLog -Namespace <domain>` returns the full timeline. List all namespaces: `Get-NamespaceLog -ListNamespaces`.

### Reading Priority (Session Startup)
1. `SOUL.md` — Identity and core logic
2. `USER.md` — {OWNER_SHORT_NAME}'s context and preferences
3. `ENVIRONMENT.md` — Workspace paths and configuration
4. `BOUNDARIES.md` — Security and behavioral rules
5. `PROTOCOLS.md` — This file — protocol standards
6. `projects.md` — Active projects, client registry, and business focus
7. `Tasks/Logs/<namespace>.log` — Recent task history (read via `Get-NamespaceLog`)
8. `MEMORY.md` — Main session only — long-term strategy

## Continuity Protocol

Continuity — the ability to reconstruct context across sessions — is the single most important operational property of the agent system. This protocol ensures no state is lost between sessions.

### Before Handoff (Write Phase)

When an agent completes a task and prepares to hand off to the next agent, it MUST record three things:

**1. Decision → Namespace Log**
Write a decision entry via `Write-NamespaceLog`:
```powershell
Write-NamespaceLog -Namespace <domain> -Type DECISION -Detail @"
Topic: <topic>
What: <what was decided>
Why: <reasoning>
Files: <file paths changed>
Status: <done / pending / blocked>
Next: <what should happen next>
"@
```

**2. Lead State → Attio Note**
If the task involved an external contact (lead, prospect, client):
- Search for the contact: `POST /attio.contact.search` by email or name
- Create a note: `POST /attio.note.create` with the appropriate `type`
- Include enough context that a future agent can reconstruct

**3. Work State → Tasks/ Directory**
Ensure the relevant task file is in the correct `Tasks/` directory:
- Complete work → `Tasks/Review/` (waiting for Reviewer)
- Audited work → `Tasks/Complete/` (done)
- Blocked work → `Tasks/Working/` with Lock Header Deferred notes

### During Startup (Restore Phase)

When an agent starts a new session (or resumes after interruption), it MUST restore context:

1. **Read namespace logs** — `Get-NamespaceLog -Namespace <domain>` for the relevant domain, or `Select-String "2026-06-15" Tasks/Logs/*.log` if only the date is known
2. **Check Tasks/ directory** — Scan `Tasks/Working/` and `Tasks/Review/` for released Lock Headers (unfinished business)
3. **Query Attio for active context** (VERI / ORCH only) — "Show me the last 5 follow_up or email_reply notes from the past 7 days"
4. **Resume** — Continue from the last recorded decision. If unsure, check with human.

## Approval Queue Protocol

Cold emails, external communications, and any human-actionable writes that affect external parties MUST go through an approval queue before execution. This is a hard boundary — no agent may send external communications without human approval.

### Flow

```
Agent drafts email
    │
    ▼
Writes approval request to Tasks/<topic>-approval.md
    │
    ▼
Notifies human via Telegram with draft content
    │
    ▼
Human responds with "approve" or "reject"
    │
    ├── Approve → Move to Tasks/Review/ for Reviewer audit
    │              → VERI executes via api-proxy
    │              → Logs result to Attio note (type: email_outreach)
    │
    └── Reject  → Stay in Tasks/ root
                    → VERI passes rejection feedback to Coder
                    → Attio note (type: follow_up) with rejection context
```

### Approval Request File Format

Written to `Tasks/<date>-<topic>-approval.md`:

```markdown
# Approval Request — <topic>

**Drafted by**: <agent-id>
**Date**: <ISO 8601 timestamp>
**Action**: <brief description of what will happen>
**Recipient**: <email address or company name>
**Campaign**: <list name from Attio>
**Body**:
<full draft content>

**Status**: PENDING_APPROVAL
**Approved at**: (pending)
**Sent at**: (pending)
**Rejection reason**: (pending)
```

### Telegram Notification Format

When an approval request is created, notify the human via Telegram:
```
📨 Approval Request: <topic>
Drafted by: <agent>
Action: <description>
Recipient: <email>

Body:
<first 300 chars of body...>

Reply "approve" to send, or "reject <reason>" to decline.
```

### Human Response Handling

| Response | Action |
|----------|--------|
| `approve` | VERI executes via api-proxy, moves to Tasks/Review/ |
| `approve and send` | Same as `approve` |
| `reject` | Stay in Tasks/, Coder receives feedback |
| `reject <reason>` | Stay in Tasks/, log reason, Coder receives feedback |
| `edit <new body>` | Update draft, notify again for re-approval |
| No response in 24h | Escalate: notify again with "⚠️ Approval request pending for 24h" |

### VERI's Role

VERI is the execution layer for approved actions:
1. Daily, check `Tasks/` for files with `Status: PENDING_APPROVAL`
2. When human responds "approve": execute via api-proxy, update file, move to `Tasks/Review/`, log to Attio
3. When human responds "reject": update file, leave in `Tasks/`, log to Attio, pass feedback to Coder

## Output Format Standards

### Handoff File Formats

| Format | Primary Use | Example | Notes |
|--------|-------------|---------|-------|
| `.md` | **Primary handoff format** — plans, deliverables, feedback, PACT scorecards, audit reports, approval requests, continuity summaries | Session plans in `Tasks/`, feedback files, namespace logs | Human-readable, git-friendly, supports rich formatting |
| `.json` | Structured data for programmatic consumption — tool results, API responses, config fragments, batch data | AQE tool output, Attio API responses, lead data | **Never inline in shell commands** (see Temp File Rule) |
| `.html` | Visual/rendered data for human review — formatted reports, rendered outreach emails, CRO analysis results | CRO analysis reports, email drafts with formatting | Only when visual presentation matters more than machine-readability |

### Temp File Rule

Any structured data (JSON, complex strings, multi-line content) passed between agents or through shell commands MUST be written to a temp file first, then referenced by path. Never inline in command-line arguments.

```powershell
# GOOD — write to temp file, pass as --file
$json = '{"key": "value", "nested": ["a", "b"]}'
Set-Content -Path "$env:TEMP\data.json" -Value $json -Encoding UTF8
./script.ps1 --file "$env:TEMP\data.json"

# BAD — inline JSON in shell arguments; breaks on quotes, special chars, long strings
./script.ps1 --json '{"key": "value", "nested": ["a", "b"]}'
```

Temp file locations:
- **Linux containers** (`/tmp/`): `Set-Content -Path "/tmp/$sessionId-data.json" -Value $json`
- **Windows host** (`$env:TEMP`): `Set-Content -Path "$env:TEMP\$sessionId-data.json" -Value $json`
- **Shared workspace** (cross-agent): `Set-Content -Path "/workspace/data/$sessionId-tool-output.json" -Value $json`

### Handoff File Content Standards

Every handoff `.md` file SHOULD contain:
1. **Header**: Task reference (session ID, plan name), source agent, timestamp
2. **Summary**: What was done, status (complete / partial / blocked / needs-review)
3. **Artifacts**: Paths to generated files (code diffs, temp files, reports)
4. **Issues**: Any issues found, decisions deferred, questions for next agent

## Logging Protocol

All agents follow `docs/Reference/Logging.md` for log levels, format, and verbosity control. The `ORCHESTRATOR_LOG_LEVEL` env var controls verbosity — set to `DEBUG` during setup/onboarding, `INFO` for normal operations.

**Workflow Events Log**: Agents also write and read `Tasks/Logs/workflow-events.log` via `Write-WorkflowEvent` and `Get-WorkflowEvents` (ORCHESTRATOR.Core) for cross-agent collision prevention and session visibility. See `Skills/Create/Skill-Authoring/workflow-primitives.md § Workflow Events Log` for the event catalog and touchpoints.

## Self-Evolution

No task is considered "Closed" until:
1. Technical lessons from namespace logs (via `Get-NamespaceLog`) are mirrored into `tools.md` or `MEMORY.md`.
2. When a new failure mode is discovered, it is added to the audit rubric immediately.
3. In team mode, ORCH is notified so the lesson can propagate to VERI's `tools.md` files.