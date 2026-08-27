# TOOLS.md — Maestro (BASE) Technical & Audit Reference

This file contains verified technical paths, fleet service endpoints, execution patterns, and self-audit rubrics for **Maestro**.

## 📂 System Paths & Environment
* See `ENVIRONMENT.md` for the canonical source of workspace paths, region locks, hardware profiles, and service endpoints.
* See `../DevOps/Fleet/fleet-topology.md` for canonical fleet topology, credential mounts, and bind mounts.

## 🌐 Fleet Service Map

| Service | Host:Port | MCP? | Purpose |
|---------|-----------|------|---------|
| mcp_opencode | mcp_opencode:21001 | SSE | Code execution, file ops |
| mcp_web | mcp_web:21005 | SSE | Tavily search, Firecrawl scrape |
| mcp_aqe | mcp_aqe:21004 | SSE | Quality engineering analysis |
| mcp_docusign | mcp_docusign:21007 | SSE | E-signature |
| is-marketer | is-marketer:21014 | REST | Marketing CRM (Attio, Apollo, Smartlead, Hunter) |
| is-fleet | is-fleet:21002 | REST | Health, logs, Docker operations |
| is-bookkeeping | is-bookkeeping:21008 | REST | Bookkeeping pipeline |
| mcp_browserless | via is-marketer | REST proxy | Browser automation |

> **Self-discovery**: Run `GET http://<service>:<port>/tools/list` on any MCP service to discover available tools.

## 🤖 mcp_opencode — Server API

Dispatch code work to mcp_opencode when the task involves multi-file edits, refactoring, long-running scripts, or subagent work.

### Endpoints

```
POST   http://mcp_opencode:21001/session               → { "session_id": "<id>" }
POST   http://mcp_opencode:21001/session/<id>/prompt_async  — dispatch task
GET    http://mcp_opencode:21001/session/<id>/message        — poll for results
GET    http://mcp_opencode:21001/session/<id>/diff           — get file changes
POST   http://mcp_opencode:21001/session/<id>/abort          — cancel runaway session
```

### Health check
```
GET http://mcp_opencode:21000  → { "status": "idle"|"busy"|"error" }
```

### Session strategy
- **One session per discrete task.** Create a new session for each task via `POST /session`.
- **Parallelize across multiple sessions** when tasks are independent.
- **Limit subagent depth to 2 levels** to avoid runaway context consumption.

### Key cycling
Coding API keys (`opencode_go_key1–5`) are mounted as Docker secrets in mcp_opencode. When a key hits a subscription limit, the container fails with an auth error. Check key timeouts via `GET /session/<id>/message` and re-dispatch with a different key if needed.

## 🛠️ Execution Patterns

* **Write-then-Execute:** Never execute complex scripts or those containing backticks directly via `exec`. Always use the `write` tool to create a `.js` or `.py` file first, then run it.
* **ESM Compatibility:** When using `docx` in Node.js, use dynamic imports: `const docx = await import('...');`. See `ENVIRONMENT.md` for the current module path.
* **String Manipulation:** Use `.trimEnd()` for Node.js string operations. Do not use Python's `rstrip()` in JavaScript environments.

## ⚠️ Tool Constraints & Parameters
* **`write` Tool:** You MUST use the `file_path` parameter. The parameters `path` or `content` are invalid and will cause failure.
* **API Rate Limiting:** Limit batch operations to 1-3 requests with a 150-300ms delay to prevent socket hangs.
* **Deletion:** Always use the `trash` tool for file removal. The `rm` command is prohibited for operational safety.

## 🛡️ Self-Verification Audit Rubric

Before delivering any output, verify against these criteria:

### Technical Correctness
* [ ] Output matches the original goal stated in the plan phase
* [ ] Tool parameters use correct names (`file_path`, not `path`)
* [ ] Scripts follow Write-then-Execute pattern (no inline heredocs for complex code)
* [ ] String methods match the runtime (`.trimEnd()` for JS, not `rstrip()`)
* [ ] mcp_opencode session diff confirms all intended changes were applied

### Security & Formatting
* [ ] No plain-text credentials in output (env vars or Docker secrets only)
* [ ] No Markdown tables in Telegram-bound content (use bullet lists)
* [ ] All URLs wrapped in `<>` to suppress embeds
* [ ] All data processing within your deployment's configured region per `BOUNDARIES.md` (Canada=`ca-central-1`, USA=`us-east-1`, Global=no lock)
* [ ] No secrets, tokens, or keys leaked in logs, commits, or handoff files

### Integrity
* [ ] File content verified by reading back from disk (not just checking exit codes)
* [ ] Factual claims checked against local files or web sources before stating them
* [ ] Deletion operations use `trash`, not `rm`
* [ ] mcp_opencode session completed successfully (not aborted or timed out)

## 📉 Iteration & Self-Verification Budget

* **Starting Budget:** 3 iterations per task.
* **New Error Code:** Free iteration (max 2 free per task).
* **Improving Output:** +1 bonus (max 5 total).
* **Strategic Pivot:** +3 reset (max 8 total).
* **Stagnation:** −1 standard cost.

### Mandatory Self-Stop Triggers
Stop and escalate to {OWNER_SHORT_NAME} if:
* Same error code encountered 5 times within an 8-iteration cycle.
* Total iteration count reaches 8.
* Technical logic repeats a failed pattern twice without modification.

When a self-stop triggers, document the failure pattern via `Write-NamespaceLog -Namespace errors -Type FAILURE_PATTERN -Detail "<pattern>"` and add it to this audit rubric.

## 🔗 API Proxy Endpoints

The is-marketer service provides unified access to external APIs at `http://is-marketer:21014`. See `ENVIRONMENT.md` for the canonical endpoint reference.

### Health & Readiness
* `GET /health` — Health check
* `GET /ready` — Readiness probe

### Drive CRUD
* `POST /drive.upload` — Upload file to Google Drive
* `POST /drive.download` — Download file from Google Drive
* `POST /drive.list-files` — List files in a Drive folder
* `POST /drive.create-folder` — Create a new Drive folder
* `POST /drive.move-file` — Move/rename a Drive file
* `POST /drive.soft-delete` — Soft-delete a Drive file
* `POST /drive.restore` — Restore a soft-deleted Drive file
* `GET /drive.health` — Drive integration health check

### Attio CRM
* `POST /attio.record.upsert` — Create or update a CRM record
* `POST /attio.record.archive` — Soft-delete a CRM record
* `POST /attio.contact.search` — Search contacts
* `POST /attio.contact.get` — Get contact details
* `POST /attio.company.search` — Search companies
* `POST /attio.company.get` — Get company details
* `POST /attio.note.create` — Create a note on a record
* `POST /attio.contact.update` — Update a contact
* `POST /attio.company.update` — Update a company
* `POST /attio.list.create` — Create a new list
* `POST /attio.list.get` — Get list details
* `POST /attio.list.archive` — Archive a list
* `POST /attio.list.addContact` — Add contact to a list
* `POST /attio.list.removeContact` — Remove contact from a list
* `POST /attio.list.entries` — List entries in a list

### Vision
* `POST /vision` — Analyze images (receipt or inventory mode)
* `POST /receipt` — Receipt shortcut (`/vision` with mode=receipt)
* `POST /inventory` — Product inventory shortcut (`/vision` with mode=inventory)

### Zoho Books
* `POST /zoho.organizations.list` — List accessible organizations
* `POST /zoho.organization.get` — Get organization details
* `POST /zoho.chartofaccounts.list` — List chart of accounts
* `POST /zoho.chartofaccounts.create` — Create chart of accounts entry
* `POST /zoho.bankaccounts.list` — List bank accounts
* `POST /zoho.bankaccounts.create` — Create a bank account
* `POST /zoho.banktransactions.list` — List bank transactions
* `POST /zoho.banktransactions.create` — Create a single bank transaction
* `POST /zoho.banktransactions.import` — Bulk-import bank transactions

---

### 🌐 Attio Note Types

When requesting Attio notes, always specify the `type` field:

| Type | Purpose | When to Use |
|------|---------|-------------|
| `email_outreach` | Outbound cold email sent | Agent sent a cold email to a lead |
| `email_reply` | Reply received from lead | Lead responded to outreach |
| `call` | Phone conversation | Spoke with contact |
| `meeting` | Scheduled or completed meeting | Discovery call, demo, or client meeting |
| `follow_up` | Follow-up action needed | Reminder or pending action on this contact |
| `outreach` | General outreach activity (default) | Generic cold outreach not covered by other types |

**Continuity Rule**: Every outreach-related note MUST include a `type`.

### 🔄 Maintenance Note
* **Documentation Rule:** If a new library is installed, a shell command is verified as the "gold standard," or a self-caught failure occurs, add it here immediately.
* **Audit Rule:** Every failure caught during self-verification should become a new rubric entry. The rubric grows sharper with every cycle.