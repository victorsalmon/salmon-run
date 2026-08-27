# MCP Server Catalog — Canonical Reference

This catalog lists every MCP server in the ORCHESTRATOR fleet, their tools, ports, auth model, and reachability. Read this first when you need to know which server handles a given tool.

## Server Inventory

| Server | Image | Internal Port | Host Port | Networks | Auth Model | `GET /tools/list` | Registered in opencode.json? | Owner |
|--------|-------|--------------|-----------|----------|------------|:-----------------:|------------------------------|-------|
| **mcp_opencode** | `opencode:local` | 21000 (health), 21001 (MCP) | none | `service_net` | Internal opencode keys (`OPENCODE_GO#_KEY`) | ❌ | No (host server) | Orchestrator |
| **mcp_web** ~~retired 2026-08-22~~ | `mcp_web:local` (removed) | 21005 (retired) | none | `service_net` | `web_mcp_secrets_bundle` + fleet auth | ❌ | Registration stale — see `/web-research` skill | Fleet |
| **mcp_aqe** ~~deprecated~~ | `mcp_aqe:local` | 21004 | `127.0.0.1:21004` | `service_net` | Fleet auth (`FLEET_API_TOKEN_AQE`) | ✅ (REST) | No (REST bridge only — no SSE entry) | Fleet |
| **mcp_browserless** | `mcp_browserless:local` | 3003 | none | `service_net` | Fleet auth (`FLEET_API_TOKEN_BROWSERLESS`) | ✅  | No | Fleet |
| **mcp_docusign** ~~retired~~ | `docusign:local` | 21007 | none | `service_net` | Fleet auth + SMTP creds | ✅ (SSE) | No | Fleet |
| _Retired 2026-08-19 — signing migrated to the self-hosted Upscale Havens backend using the shared @clocklobster/signing-* packages. Image and scripts retained as reference._ | | | | | | | | |
| **ops-funnel-proxy** | `nginx:1.27-alpine` | 21009 | none (Tailscale tunnel) | standalone | Fleet token in nginx config | ❌ (proxy) | No | Fleet |
| **is-bookkeeping** | `bookkeeping:local` | 21008 | `21008:21008` | `service_net` | `bookkeeping_secrets_bundle` + fleet auth | ✅ | **Yes** | Bookkeeper |
| **is-sentry** | `sentry:local` | 21002 (health), **21014 (MCP)** | 21014 | `service_net`, `management_net` | Fleet auth (`FLEET_API_TOKEN_SENTRY`) | ✅ (REST) / ✅ (MCP proxy) | **Yes** | Sentry |

## Per-Server Details

### mcp_opencode

**Image**: `opencode:local`
**Internal ports**: 21000 (health), 21001 (MCP server)
**Host ports**: none (opencode MCP port is not published; gateway services publish their own host ports like 20100 for ORCH)
**Auth**: Internal opencode keys (`OPENCODE_GO#_KEY`) — no `FLEET_API_TOKEN` required for opencode-MCP communication.
**Reachability**: `service_net` containers only
**Standard tools**: opencode CLI tools (bash, read, write, edit, glob, grep, task, skill, webfetch, voice, todowrite)
**Related skill**: `Skills/MCP/mcp_opencode.md`
**Connected to**: mcp_web (via `FLEET_API_TOKEN_WEB` injection — now retired) and mcp_aqe (via opencode.json — now retired)

---

### mcp_web (retired)

> **Status**: Retired 2026-08-22. Container, image build, compose service, port 21005, and source files (`Infrastructure/web-mcp-server.js`, `Infrastructure/mcp_web.Dockerfile`, `Infrastructure/entrypoint-web-mcp.sh`) removed. <!-- doc-lint: exempt --> Replacements:
> - Web search / scraping: cross-harness `/web-research` skill (`Skills/DevOps/Web/SKILL.md`)
> - Rent tracking: `upscale-havens/backend` `/api/rent/*` routes (`Skills/DevOps/Web/rent-tracking.md`)

**Former image**: `mcp_web:local`
**Former internal port**: 21005 (now in the port registry's `retired` section)
**Auth**: `web_mcp_secrets_bundle` (Tavily API key, Firecrawl API key, IMAP credentials) + fleet auth (`FLEET_API_TOKEN_WEB`)
**Tool domains (historical)**: Tavily (web_search, web_extract), Firecrawl (web_scrape, web_crawl, web_browse, web_screenshot), Rent tracking (16 rent_* tools)
**Related skills**:
- `Skills/DevOps/Web/SKILL.md` — replacement for Tavily/Firecrawl tools
- `Skills/DevOps/Web/rent-tracking.md` — replacement for rent tracking tools

---

### mcp_aqe (Agentic Quality Engineering, deprecated)

> **Status**: Deprecated 2026-08-20. Replacement: cross-harness `/aqe` skill (`Skills/AQE/SKILL.md`).

**Image**: `mcp_aqe:local`
**Internal port**: 21004
**Host port**: `127.0.0.1:21004` (loopback only — not exposed on LAN)
**Auth**: Fleet auth (`FLEET_API_TOKEN_AQE`); host callers retrieve it via `Skills/AQE/Get-AqeAuthToken.ps1`
**Reachability**: `service_net` containers (overlay DNS `http://mcp_aqe:21004`) AND host agents/audits (`http://localhost:21004` — auto-resolved by `Skills/AQE/Resolve-AqeBridgeUrl.ps1`)
**Tool domains**: test-generation, test-execution, coverage-analysis, quality-assessment, defect-intelligence, requirements-validation, code-intelligence, security-compliance, contract-testing, visual-accessibility, chaos-resilience, learning-optimization
**Related skill**: `Skills/MCP/AQE/mcp_aqe.md`

---

### mcp_browserless

**Image**: `mcp_browserless:local` (based on `ghcr.io/browserless/chromium`)
**Internal port**: 3003
**Host port**: none
**Auth**: Fleet auth (`FLEET_API_TOKEN_BROWSERLESS`)
**Reachability**: `service_net` containers only

**Purpose**: Headless Chrome browser automation service. Used by Playwright scripts and browser-automation skills (Zoho Books reconciliation, Amazon receipt download, CloudTax filling, etc.).

**Related skill**: `Skills/DevOps/Playwright/browserless.md`
**Health endpoint**: `/pressure` on port 3003

---

### mcp_docusign (retired)

**Status**: Retired 2026-08-19.

**Replacement**: Signing is now self-hosted in the Upscale Havens backend using the shared `@clocklobster/signing-*` packages (`signing-core`, `signing-pdf`, `signing-email`, `signing-provider`). The `docusign:local` image and build scripts are retained as reference for the migration period.

**Image**: `docusign:local`
**Internal port**: 21007
**Host port**: none
**Auth**: Fleet auth (`FLEET_API_TOKEN_DOCUSIGN`) + SMTP credentials (SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS)
**Reachability**: `service_net` containers only; webhooks previously arrived via ops-funnel-proxy
**Tool domains**: send_document_for_signature, send_pdf_for_signature (with fillable form fields), check_document_status, list_documents
<!-- doc-lint: exempt -->
**Related skill**: `Skills/MCP/mcp_docusign.md`

---

### ops-funnel-proxy

**Image**: `nginx:1.27-alpine`
**Internal port**: 21009
**Host port**: none (Tailscale Funnel at `FRAD-funnel.vdeskgame-richmond.ts.net:443`)
**Auth**: Fleet token from `/run/secrets/fleet_api_token` (injected into nginx config)
**Reachability**: Public internet (via Tailscale Funnel) → general-purpose fleet webhook proxy.

**Purpose**: Reverse proxy for fleet webhooks. The DocuSign webhook ingress (port 21007 /mcp_docusign) has been retired; signing is now self-hosted in the Upscale Havens backend.

**Related skill**: `Skills/MCP/ops-funnel-proxy.md`

---

### is-bookkeeping

**Image**: `bookkeeping:local`
**Internal port**: 21008
**Host port**: `21008:21008`
**Auth**: `bookkeeping_secrets_bundle` + fleet auth (`FLEET_API_TOKEN_IS_BOOKKEEPING`)
**Reachability**: `service_net` containers AND host (port 21008)

**Purpose**: Bookkeeping server — receives processed receipts, manages Zoho Books API calls, runs reconciliation workflows. Not an MCP-SSE server; REST API via Express.
**Tool domains**: zoho (expenses, invoices, contacts, chart-of-accounts, bank-transactions), receipt processing, reconciliation, email fetching
**Discovery endpoints**: `GET /api/openapi.json` (OpenAPI 3.0 schema), `GET /api/tools` (legacy tool list), `GET /api/rate-limit-status` (Zoho circuit breaker state)

### Rate-Limiting

The is-bookkeeping container maintains an in-memory circuit breaker for Zoho API calls:

- When Zoho returns HTTP 429 (rate limited), the circuit breaker is set for the duration of the `Retry-After` header + 5 seconds.
- When any handler receives a 401 (token expired), it automatically attempts one token refresh. If the refresh also fails, the circuit breaker is set for 65 seconds.
- Call `GET /api/rate-limit-status` before batch operations to check if the circuit breaker is active.
- All Zoho handlers share the same circuit breaker state (via `Auth.ps1`), so a 429 from any endpoint blocks all subsequent Zoho calls until the breaker expires.

### Receipt uploads

Prefer `ReceiptPath` over `ReceiptBase64` for attaching receipt files. The `ReceiptPath` parameter reads the file from the container filesystem, avoiding the E2BIG error that occurs when passing large base64 strings as PowerShell arguments. Supported on `POST /zoho/expense` and `POST /zoho/expense/:ExpenseId/receipt`.

**Related skill**: `Plugins/clock-lobster-books/SKILL.md`

## Runtime Discovery — `Discover-FleetCapabilities.ps1`

For the most current view of fleet capabilities, run `C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Discover-FleetCapabilities.ps1`. This script polls each container's `GET /tools/list` endpoint and produces:

- A Mermaid flowchart and service table (`Tasks/Logs/fleet-capabilities-<timestamp>.md`)
- JSON output for programmatic consumption (`-AsJson`)
- The Mermaid diagram alone (`-AsMermaid`)

This catalog is the **fallback index** when containers are unreachable or the fleet is undeployed. Run the discovery script first; reference this catalog only for static details (ports, auth model, image names) that live discovery cannot provide.

## Platform-First Resolution Order

When the fleet is deployed (containers are running), ALL agents MUST follow this priority order for accessing credentials, data, and service capabilities. Do NOT reach for AWS Secrets Manager or local config files unless the platform path fails.

### Priority (highest to lowest)

| Priority | Method | When to use |
|----------|--------|-------------|
| **1st** | **Cross-harness skills** (`/web-research`, `/aqe`, `/rent-tracking`) — the retired MCP containers (`mcp_web`, `mcp_aqe`, `mcp_docusign`, `mcp_browserless`) were replaced by skills | Any task that maps to an existing skill. |
| **2nd** | **Container REST APIs** (non-SSE services — `is-bookkeeping:21008`) | When no skill exists for the task. Call via `docker exec` (from host) or `Invoke-RestMethod`/`curl` using `${service_name}:${port}` (from within `service_net`). |
| **3rd** | **Host-side scripts** (PowerShell/Node.js/Python under `Skills/`) | When the fleet container is not running, or the task requires direct filesystem access that no container API provides. |
| **4th** | **External APIs directly** (AWS SM, Zoho API, Tavily API, etc.) | **Last resort only.** Only when no platform service exposes the needed capability. For AWS SM specifically, see the read-only policy in AGENTS.md. |

### Checklist for every task

Before calling any external API (including AWS Secrets Manager), run this check:

```
1. Is the fleet deployed?  → docker ps (check for FRAD_* containers)
2. Is there an MCP tool?    → check opencode.json registered servers, then mcp-catalog.md
3. Is there a REST endpoint? → check mcp-catalog.md per-server details
4. Fall through to host script or direct API
```

### Why this matters

- **Security**: Container credentials are scoped and ephemeral; fewer agents touch long-lived AWS SM secrets.
- **Resilience**: Container APIs encapsulate retry logic, rate limiting, and credential refresh.
- **Consistency**: The platform provides the same interface regardless of which agent or host calls it.
- **Audit**: Container APIs log every call via the audit trail; direct AWS SM access bypasses fleet audit.

### Tool Discovery

Each container exposes `GET /tools/list` (or MCP SSE `tools/list` for SSE servers) for runtime capability discovery. To find which server hosts a capability:

1. **Run runtime discovery** —`Discover-FleetCapabilities.ps1` polls every container's `GET /tools/list` and produces a live capability map.
2. **Check `opencode.json`** — the `mcp_web` SSE registration that remains in `Infrastructure/opencode/config/opencode.json` is stale (the container was retired 2026-08-22); do not rely on it. Use the cross-harness `/web-research` skill instead.
3. **For non-SSE servers** — reach them via REST API by calling `GET http://<service>:<port>/tools/list` with the appropriate `FLEET_API_TOKEN_*` as Bearer auth.
4. **For `mcp_opencode`** — standard opencode CLI tools (bash, read, write, etc.). Its `GET /tools/list` is not exposed via REST.
5. **Cross-reference** the per-server skill files listed above for detailed API documentation.

## Adding a New MCP Server

See `Skills/DevOps/Fleet/create-mcp/SKILL.md` for the full MCP server creation workflow: Express server code, SDK integration, Dockerfile, secret bundle, compose entry, image build function, port registry registration, and MCP registration in opencode.json.

## Common Pitfalls

- **Host cannot reach `service_net` containers**: Services like `mcp_browserless` (port 3003) have no host port mapping — they are only reachable from within the Docker overlay network. `mcp_docusign` (port 21007) and `mcp_web` (port 21005) have been retired.
- **Auth token required**: All fleet MCP servers require `Authorization: Bearer <FLEET_API_TOKEN_*>` on every request. The retired `mcp_web` additionally injected API keys from `web_mcp_secrets_bundle` at startup.
- **Per-agent rate limits**: The retired `mcp_web` had Tavily and Firecrawl rate limits; the `/web-research` skill documents its own limits. `mcp_aqe` registration operations are idempotent but have processing latency.
- **SSE vs REST**: Only the now-retired `mcp_web` and `mcp_aqe` spoke the MCP SSE protocol. All remaining servers use plain REST APIs — you must call their endpoints directly with HTTP requests.
