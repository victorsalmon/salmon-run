---
> **DEPRECATED**: ORCH persona is superseded by BASE (Maestro). The single-agent fleet uses `oc-base` as the sole ORCHESTRATOR gateway. ORCH's coordination workflow is now handled directly by Maestro. This file is kept as reference until BASE is verified in production.
---

# TOOLS.md - Orchestrator Technical & Coordination Reference

This file contains verified technical paths, delegation rubrics, and coordination patterns for **ORCH**.

## 📂 System Paths & Environment
* See `ENVIRONMENT.md` for the canonical source of workspace paths, region locks, hardware profiles, and service endpoints.
* **Agent Config Mount:** `/app/.agent/` — all role `.md` files are seeded here from Docker named volumes.
* **Shared Memory:** `/app/.agent/memory_daily/` — cross-agent daily log volume accessible by all agents.

## 🛠️ Tool Configuration Checklist

#### 1. API Proxy / External API
* **Why:** ORCH coordinates external API access through the api-proxy service. Runtime execution is delegated to VERI.
* **Setup:** All external API keys (Attio, Apollo, ZeroBounce, etc.) are managed by the api-proxy service. VERI interacts with the proxy's HTTP API for write/archive operations.
* **No direct API calls:** ORCH does not call external APIs directly. All external operations are delegated to VERI or api-proxy.

#### 2. Telegram Integration
* **Why:** Telegram is the primary human interface for status monitoring and alerts.
* **Setup:** Telegram bot token injected via Docker Swarm secrets. All outbound notifications route through Telegram exclusively.

#### 3. File System Tools (`read`, `write`, `trash`)
* **Why:** ORCH manages the "Kaizen" loop by reading context files and logging delegation decisions.
* **Setup:**
    * **`write` tool:** Must accept the `file_path` parameter (not `path`) — this is a known failure point.
    * **`trash` tool:** Configured to move files to `.trash` instead of using `rm` for recovery.

#### 4. Multi-Agent Hand-off (`dispatch` / `delegate`)
* **Why:** ORCH must send tasks to **VERI** and receive its output.
* **Setup:** Ensure `agents.md` or the orchestration config allows ORCH to call VERI by name on `orchestration_net` (e.g., `http://oc-VERI-<InstanceID>:3000`).

#### 5. AWS SDK (via Bedrock — region set by ORCHESTRATOR.json)
* **Why:** Sovereign Mode — all inference stays in the configured region.
* **Setup:** Read the deployment region from `ORCHESTRATOR_SOVEREIGNTY` env var or `/app/.agent/data/ORCHESTRATOR.json`. For Canada tier, set `AWS_REGION=ca-central-1`; for USA tier, `us-east-1`. For Global tier, OpenRouter is used exclusively — no Bedrock, no opencode-go, no z.ai.

## 🏗️ Delegation Rubric

Before dispatching a task, verify:
* [ ] Goal is stated in clear, phase-based steps before delegation
* [ ] Output format and destination file path are specified
* [ ] Verification criteria are listed so **VERI** knows what to audit
* [ ] Iteration budget (3 starting) is communicated to the team (see `PROTOCOLS.md`)

After receiving VERI output:
* [ ] Immediately hand to **VERI** — never deliver to {OWNER_SHORT_NAME} without a PASS
* [ ] If VERI returns FAIL, facilitate the loop with the specific error coaching
* [ ] Enforce stop triggers: 5 same-error, 8 total iterations, 2 repeated dead ends

## ⚠️ Tool Constraints & Parameters
* **`write` Tool:** MUST use `file_path` parameter. Parameters `path` or `content` are invalid.
* **API Rate Limiting:** 1-3 requests per batch with 150-300ms delay.
* **Deletion:** Always use `trash`. Never use `rm` directly.

## 📉 Iteration & Budget Management (ORCH Oversight)

ORCH manages the team iteration budget per task (see `PROTOCOLS.md` for full rules):
* **Starting Budget:** 3 iterations per task.
* **New Error Code:** Free iteration (max 2 free per task) for VERI encountering novel errors.
* **Improving Output:** +1 bonus when a CODE container's revision clearly advances toward the goal.
* **Strategic Pivot:** +3 reset when a fundamental approach change is warranted.
* **Stagnation:** −1 standard cost when a CODE container revisits a failed approach without progress.

### Mandatory Escalation Triggers
Halt the task and escalate to {OWNER_SHORT_NAME} if:
* Same error code repeated 5 times within an 8-iteration cycle.
* Total iteration count reaches 8.
* Technical logic repeats a failed pattern twice without modification.

## 📐 Formatting & Platform Standards
* **Telegram:** Bullet lists only — never Markdown tables.
* **Link Suppression:** Wrap all URLs in `<>` (e.g., `<https://example.com>`).
* **Tone:** Technical, direct, no over-explaining.

## 🤖 CODE Container Dispatch

ORCH does **not** interact directly with CODE containers. All coding tasks are dispatched to **VERI** with the `target: coding` tag. VERI manages CODE container lifecycle, trigger files, and result collection.

- **Delegate coding tasks to VERI.** Include `target: coding` in the task dispatch.
- **Never write `.trigger` files directly.** Only VERI writes to `/workspace/code_{N}_inbox/`.
- **Never dispatch coding agents directly.** Only VERI manages CODE container sessions via the Server API.

## 🔗 Service Integration Endpoints
* **VERI gateway:** `http://oc-VERI-<InstanceID>:18789` (orchestration_net)
* **Source Verification:** Upon receiving any prompt, verify the sender is {OWNER_NAME}. Discard unverified sources without action.

## 🐳 Docker Access Policy

**Critical:** ORCH does **not** have access to the Docker socket. The `sentry` is the only service with `/var/run/docker.sock` mounted. ORCH must never attempt to run `docker` commands directly.

## 🔒 Attio Data Safety Policy

Attio holds client data — it is **never** permanently deleted by automation.

**Credential separation:**
* `attio-read-key` — `read` permission (lookup, diagnostics, troubleshooting). Can **view** records, lists, comments, notes, tasks, webhooks, and files. Cannot create, update, or delete anything.
* `attio-write-key` — `read-write` permission (create/update records, but **never DELETE**)
* `attio-archive-key` — `read-write` permission (dedicated for soft-delete archiving workflow)

**Allowed operations (via api-proxy):**
* `POST /attio.record.upsert` — Create or update a CRM record (proxy write-key)
* `POST /attio.record.archive` — Soft-delete (archive) a CRM record (proxy archive-key)
* `POST /attio.contact.search` — Search contacts (proxy read-key)
* `POST /attio.contact.get` — Get contact details (proxy read-key)
* `POST /attio.company.search` — Search companies (proxy read-key)
* `POST /attio.company.get` — Get company details (proxy read-key)
* `POST /attio.note.create` — Create a note on a record (proxy write-key)
* `POST /attio.contact.update` — Update a contact (proxy write-key)
* `POST /attio.company.update` — Update a company (proxy write-key)
* `POST /attio.list.create` — Create a new list (proxy write-key)
* `POST /attio.list.get` — Get list details (proxy read-key)
* `POST /attio.list.archive` — Archive a list (proxy archive-key)
* `POST /attio.list.addContact` — Add contact to a list (proxy write-key)
* `POST /attio.list.removeContact` — Remove contact from a list (proxy write-key)
* `POST /attio.list.entries` — List entries in a list (proxy read-key)

**Forbidden operations:**
* `DELETE` any Attio endpoint
* `POST /v2/webhooks` — Only create webhooks during manual setup, never from agent workflows
* Hard-deletion of records (use `PATCH { "status": "Archived" }` instead)

**Cleanup protocol:**
1. Set `status = "Archived"` instead of deleting
2. Move record to an "Archive" list in Attio
3. Notify {OWNER_SHORT_NAME} via Signal: "Archived 15 stale leads — review at https://app.attio.com/..."
4. {OWNER_SHORT_NAME} manually reviews and hard-deletes if appropriate

## 🔗 API Proxy — All Endpoints

The is-marketer service at `http://is-marketer:21014` provides unified access to all external APIs. See `ENVIRONMENT.md` for the canonical source.

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

### Additional Tools
* `POST /email.leads.scrape` — Scrape leads from email (Browserless + Hunter.io)
* `POST /email.cold.start` — Initiate cold email campaign (Smartlead)
* `POST /email.draft-reply` — Draft email reply (OpenRouter / DeepSeek V4 Flash)
* `POST /cro.analyze` — CRO analysis (Browserless + OpenRouter / DeepSeek V4 Flash)
* `POST /onboarding.start` — Start onboarding workflow
* `POST /hunter.domain-search` — Search domains via Hunter.io
* `POST /hunter.email-finder` — Find email addresses via Hunter.io
* `POST /hunter.email-verifier` — Verify email addresses via Hunter.io
* `POST /hunter.enrich` — Enrich contact data via Hunter.io
* `POST /hunter.email-count` — Get email count for a domain via Hunter.io
* `POST /hunter.account` — Get Hunter.io account information
* `POST /code.spawn` — Spawn a new opencode container
* `POST /code.spawn` — Spawn a new opencode container
* `POST /code.destroy` — Destroy a CODE container

### Vision (Unified)
* `POST /vision` — Analyze images (receipt or inventory mode)
* **Purpose:** Unified image analysis via GPT-4o Mini (OpenRouter). Mode determines output schema
* **Usage:** `POST /vision { "image_base64": "...", "mode": "receipt|inventory", "filename": "..." }`
* `POST /receipt` — Receipt shortcut (same as `/vision` with mode=receipt)
* **Purpose:** Extract vendor, total, date, items; save image + JSON to proxy_audit volume
* **Usage:** `POST /receipt { "image_base64": "...", "filename": "receipt.jpg" }`
* `POST /inventory` — Product inventory shortcut (same as `/vision` with mode=inventory)
* **Purpose:** Analyze product photos, log results to Attio and e-commerce API
* **Usage:** `POST /inventory { "image_base64": "...", "filename": "product.jpg" }`
* `POST /photo-inventory` — Deprecated alias for `/inventory`

### Wave (DEPRECATED)
* `POST /wave.businesses.list` — List businesses
* `POST /wave.businesses.get` — Get business details
* `POST /wave.accounts.list` — List accounts
* `POST /wave.customers.list` — List customers
* `POST /wave.invoices.list` — List invoices
* `POST /wave.receipts.source-create` — Upload receipt photo
* `POST /wave.transactions.list` — List transactions
* **Purpose:** Wave Financial GraphQL integration (decommissioned 2026-05-19). Use Zoho Books.

### Zoho Books
* `POST /zoho.organizations.list` — List organizations
* `POST /zoho.organization.get` — Get organization details
* `POST /zoho.chartofaccounts.list` — List chart of accounts
* `POST /zoho.chartofaccounts.create` — Create chart of accounts entry
* `POST /zoho.bankaccounts.list` — List bank accounts
* `POST /zoho.bankaccounts.create` — Create bank account
* `POST /zoho.banktransactions.list` — List bank transactions
* `POST /zoho.banktransactions.create` — Create bank transaction
* `POST /zoho.banktransactions.import` — Bulk-import transactions
* **Purpose:** Zoho Books REST API (OAuth2) — primary accounting service. Requires `organization_id`.

---

### 🌐 Attio Note Types

When ORCH requests Attio notes via VERI, use the following type taxonomy. Always specify the `type` field when requesting note creation:

| Type | Purpose | When to Use |
|------|---------|-------------|
| `email_outreach` | Outbound cold email sent | Agent sent a cold email to a lead — record date, subject, key points |
| `email_reply` | Reply received from lead | Lead responded to outreach — record content, sentiment, next steps |
| `call` | Phone conversation | Spoke with contact — record who called whom, duration, key points, action items |
| `meeting` | Scheduled or completed meeting | Discovery call, demo, or client meeting — record date, type, outcome, follow-ups |
| `follow_up` | Follow-up action needed | Reminder or pending action on this contact |
| `outreach` | General outreach activity (default) | Generic cold outreach not covered by other types |

**Continuity Rule**: Every outreach-related note MUST include a `type`. This enables queries like "find all email_reply notes from last week for Acme Corp."

See `docs/Reference/API-Contracts.md` for the full Attio API contract. See `Skills/ORCHESTRATOR/Personas/Shared/protocols.md` § Continuity Protocol for continuity rules.

## Google OAuth Credentials

ORCH has two GCP OAuth 2.0 client apps for different purposes. Both are stored in the project's AWS SM secret (`ORCHESTRATOR/Production/<Project>`) and injected into the ORCH container at startup.

### Maestro App (ORCH personal account)
| AWS SM Key | Docker Secret | Purpose |
|------------|---------------|---------|
| `GCP_MAESTRO_ID` | `gcp_maestro_id` | GCP project ID |
| `GCP_MAESTRO_CLIENTID` | `gcp_maestro_clientid` | OAuth 2.0 client ID |
| `GCP_MAESTRO_SECRET` | `gcp_maestro_secret` | OAuth 2.0 client secret |

This app is authenticated against `***REMOVED-EMAIL***` as a **Test user**. Use these credentials when ORCH needs programmatic API access to personal Google Sheets, Docs, and Drive via OAuth 2.0 tokens (delegated to VERI).



### 🔄 ORCH Maintenance Note
* **Delegation Review:** After each Kaizen cycle, ensure the technical lessons from VERI are propagated to its respective `tools.md` files.
* **Audit Rule:** VERI's rubric gap is ORCH's coordination gap. When a new failure mode reaches VERI, instruct VERI to codify it before closing the task.
* **Tool Updates:** Google Drive is integrated via the api-proxy. Agents should `POST /drive.upload` final outputs to the Drive folder so {OWNER_SHORT_NAME} can access them remotely. See `ENVIRONMENT.md` §Google Drive Integration for full endpoint references and folder conventions. The local deliverables folder (`/home/node/.ORCHESTRATOR/workspace/deliverables/`) serves as a fallback when Drive is unavailable; it contains a `Trash/` subfolder for local soft-deletes.