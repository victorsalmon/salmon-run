# ENVIRONMENT.md - Canonical System Configuration

This file is the single source of truth for workspace paths, cloud region locks, hardware profiles, and service endpoints. All agents reference this file instead of hardcoding paths in their role-specific files.

When deployment configuration changes, update this file. All other files inherit from here.

> **2026-08-21/2026-08-25 Retirement**: The MCP/Hermes/openclaw and schedule-poller container retirement removed all containers except `is-fleet`. The host-side local orchestrator (`Invoke-Orchestrate.ps1`) now handles code/research/bookkeeping/marketing execution via cross-harness skills. Sections below that reference retired services (mcp_opencode, oc-base, is-marketer, is-bookkeeping, mcp_web, mcp_browserless, is-hermes, ops-funnel-proxy, the schedule poller) are preserved for historical reference but those services are no longer deployed. See `fleet-topology.md` for the current 1-container topology.

## Workspace Paths
* **Root Workspace:** `/home/ubuntu/.ORCHESTRATOR/workspace/` (agent-local persistent volume)
* **Shared Repos:** `/workspace/<reponame>/` — shared `interclaw_workspace` volume mounted on all agents and mcp_opencode containers; git repositories cloned from `INSTALL_WORKSPACE_REPOS` live here
* **Git Repo Registry:** `Skills/ORCHESTRATOR/Personas/Shared/git-repos.md` — human-readable documentation of all repos in `INSTALL_WORKSPACE_REPOS` (purpose, agent ownership, branch conventions, secret handling)
* **Agent Config Mount:** `/app/.agent/`
* **Daily Memory (Deprecated):** `/app/.agent/memory_daily/` — use `Write-NamespaceLog` instead
* **Temporary Storage:** `/tmp/` — use for volatile data; move persistent artifacts to the workspace.

## Node.js Modules
* **docx Library:** `/home/ubuntu/.ORCHESTRATOR/workspace/node_modules/docx/dist/index.mjs`
  * Import pattern: `const docx = await import('/home/ubuntu/.ORCHESTRATOR/workspace/node_modules/docx/dist/index.mjs');`
  * Use ESM dynamic imports; `.mjs` distribution is required.

## Data Residency & Cloud

Your deployment's **sovereignty tier** is defined in the active `ORCHESTRATOR.json` configuration (mounted at `/app/.agent/data/ORCHESTRATOR.json`). Read this file at session startup to determine which region applies.

### Sovereignty Regions

| Tier | Region | AI Providers |
|------|---------|-------------|
| **Canada** | `ca-central-1` (AWS Montreal) | Amazon Bedrock: Nova Pro, Nova Lite, Llama 4 Scout (CA inference profile) |
| **USA** | `us-east-1` (AWS Virginia) | Amazon Bedrock: Nova Pro, Nova Lite, Llama 4 Scout (US inference profile) |
| **Global** | No regional lock | **opencode-go primary** (`deepseek-v4-flash` effort:max / `deepseek-v4-pro` effort:high) with **OpenRouter fallback** (Kimi K2.6, MiMo). No Bedrock. opencode-go uses `OPENCODE_GO_KEY` env var. |

* **Regional Lock (Canada/USA):** All AWS API calls must target your configured region (`ca-central-1` or `us-east-1`). The lock is non-negotiable — see `BOUNDARIES.md` for enforcement details.
* **Gateway:** Internal gateway communication runs on the Docker overlay network; no external internet routing for agent-to-agent traffic.

## Docker & Networking
* **Service Network:** `service_net` — connects agents to shared services.
* **Orchestration Network:** `orchestration_net` — inter-agent control plane (retired — preserved for backward compatibility).
* **Management Network:** `management_net` — isolated network for is-fleet only.
* **Gateway Ports (role-specific):** BASE=20300. Each role has a fixed base with index offset.
* **Opencode Ports:** `30100 + (CodeId × 100)` (e.g., mcp_opencode → 30200).

## Hardware Profile
* **Testing Environment:** Lenovo M70q (11th Gen i5) for local inference and script testing.
* **Cloud:** AWS (region per `BOUNDARIES.md`: Canada=`ca-central-1`, USA=`us-east-1`, Global=fallback `us-east-1`) for production inference and data processing.

## Credential Access
* **Environment Variables:** Credentials are injected via Docker Swarm secrets mounted at `/run/secrets/`.
* **Pattern:** Read secrets from `_FILE` environment variables (e.g., `AWS_ACCESS_KEY_ID_FILE=/run/secrets/aws_id`).
* **Never Hardcode:** See `BOUNDARIES.md` for the complete credential handling policy.

## Coding API Key Management

Coding API keys (`opencode_go_key1` through `opencode_go_key4`) are sourced from AWS Secrets Manager and injected as Docker Swarm secrets. mcp_opencode containers receive all keys. Key priority: `OPENCODE_GO_KEY1` (defined in `Get-CodingKeyPriority`).

### Key Timeout Pattern (Optional)
To support intelligent key rotation when subscription limits are hit, each key may include an associated timeout field in the AWS Secrets Manager JSON blob:
* **Field name:** `opencode_go_key<N>_timeout`
* **Format:** Unix timestamp (seconds since epoch) or ISO 8601 string
* **Behavior:** Before dispatching work to a mcp_opencode container, check the timeout. If `now < timeout`, the key is in cooldown — rotate to the next key by selecting a different mcp_opencode container or updating the env var. When `now >= timeout`, the key is available again.
* **Fallback:** If no timeout fields are present, use round-robin across all four keys and retry once on rate-limit errors before escalating.

## Key Isolation Matrix

| Key | oc-base | mcp_opencode | is-marketer | is-fleet |
|-----|---------|-------------|--------|----------|
| `OPENROUTER_ORCH_KEY` | Yes | No | No | No |
| `OPENROUTER_CODE_KEY` | No | Yes | No | No |
| `OPENCODE_GO_KEY1`-`5` | No | Yes | No | No |
| `ATTIO_READ_KEY` | Yes | No | No | No |
| `ATTIO_WRITE_KEY` | No | No | Yes | No |

**Policy:**
- Coding subscription keys (`OPENCODE_GO_KEY`) are mcp_opencode sidecar only.
- oc-base never mounts coding keys. All coding task dispatch goes through mcp_opencode HTTP API.
- No container mounts API keys it does not require. If a container lacks needed keys, the infrastructure must be fixed — the container fails hard rather than borrowing keys from another service.

## Fleet Container Inventory

> **Canonical source**: [`Skills/DevOps/Fleet/fleet-topology.md`](Skills/DevOps/Fleet/fleet-topology.md) — this table mirrors the service inventory there.

All Docker services run on the `service_net` overlay network. Use these existing containers instead of rebuilding their capabilities:

| Container | Image | Port(s) | Purpose |
|---|---|---|---|---|
| `oc-base` | `ORCHESTRATOR:local` | 20300 | Autonomous fleet orchestrator — single agent, full lifecycle |
| `mcp_opencode` | `opencode:local` | 21000 (health), 21001 (MCP gateway) | OpenCode server — code execution via HTTP API |
| `is-marketer` | `is-marketer:local` | 21014 | Marketing CRM (Attio, Apollo, Smartlead, Hunter) — holds elevated credentials |
| `Bookkeeper` | `bookkeeping:local` | 21008 | Weekly bank sync, monthly reconciliation engine |
| `is-fleet` | `is-fleet:local` | 21002 | Fleet operations — health checks, auto-remediation, Docker socket |
| `mcp_web` | `mcp_web:local` | 21005 | Web scraping / content fetching (Tavily + Firecrawl MCP) |
| `mcp_aqe` | `mcp_aqe:local` | 21004 | AgenticQE — quality engineering MCP tools |
| `mcp_browserless` | `mcp_browserless:local` | 21006 (HTTP + WS) | Headless browser automation — connect via `ws://FRAD_mcp_browserless:21006?token=${BROWSERLESS_TOKEN}` |
| `mcp_docusign` | `mcp_docusign:local` | 21007 | Docusign SMTP/API integration for envelope management |
| `ops-funnel-proxy` | `ops-funnel-proxy:local` | 21009 | Tailscale funnel proxy for public HTTPS ingress |

**Rule: Always use existing MCPs/containers before rebuilding.** If you need browser automation, use `mcp_browserless`. If you need web fetching, use `mcp_web`. If you need quality engineering, use `mcp_aqe`. Install dependencies inside throwaway Docker containers (e.g. `node:20-slim`) rather than on the host. Only install on the host when no container provides the capability.

## Service Integration
* **is-marketer:** Available on `service_net` at `http://is-marketer:21014`. Holds elevated API keys (Attio write/archive, Apollo, ZeroBounce, Browserless, Smartlead). Exposes capability-scoped REST endpoints. No ports published to host.
* **Telegram:** Primary human interface via @IntersiteFRADbot. Bot token injected via Docker Swarm secret (`TELEGRAM_BOT_TOKEN_ORCH_FILE=/run/secrets/telegram_bot_token_orch`). Owner Telegram username and user ID are configured via `0config.ps1` and injected as Docker Swarm secrets.
* **Google Drive:** Read/write via api-proxy Drive endpoints. Uses a service account JWT for authentication (no user-facing OAuth). Agents can upload, download, list, create folders, and move files. See the Google Drive Integration section below for endpoint references and folder conventions.

### Google Drive Integration

| Item | Value |
|------|-------|
| **Base URL** | `http://is-marketer:21014` |
**Fallback convention (local deliverables):**
If Drive is unavailable (`drive.health` returns `degraded`), the orchestrator should instead:
1. Write the output to `/home/node/.ORCHESTRATOR/workspace/deliverables/<task-id>-<type>.md`
2. Note in the delivery summary that Drive was unavailable and the file is in the local deliverables folder

## Inter-Agent Inbox Paths

File-based handoffs between agents. Each inbox has a `signal.md` file created when new content is ready and deleted by the receiving agent on acknowledgment.

* **Worker Inbox:** `/home/ubuntu/.ORCHESTRATOR/workspace/worker-inbox/`
  * Orchestrator writes execution plans here (`{task-id}-plan-pass-{N}.md`)
  * mcp_opencode containers read plans and delete `signal.md` after acknowledgment
* **Verifier Inbox:** `/home/ubuntu/.ORCHESTRATOR/workspace/verifier-inbox/`
  * mcp_opencode containers write deliverables here (`{task-id}-deliverables-pass-{N}.md`)
  * Orchestrator reads deliverables and deletes `signal.md` after acknowledgment
* **Orchestrator Outbox:** `/home/ubuntu/.ORCHESTRATOR/workspace/orchestrator-outbox/`
  * Orchestrator writes final polished output here (`{task-id}-final.md`)
  * Orchestrator reads final output and delivers to {OWNER_SHORT_NAME}

File naming convention (Three Passes Workflow):
* Plans: `{task-id}-plan-pass-{N}.md` (e.g., `research-042-plan-pass-1.md`)
* Deliverables: `{task-id}-deliverables-pass-{N}.md` (e.g., `research-042-deliverables-pass-1.md`)
* Final output: `{task-id}-final.md` (e.g., `research-042-final.md`)
* Signal file: `signal.md` (contains the task-id, pass number, and timestamp)

## mcp_opencode container Environment Variables

mcp_opencode containers are deployed with the following environment variables:

| Variable | Source | Description |
| :--- | :--- | :--- |
| `OPENCODE_MCP_ROLE` | Compose generator | Set to `"code-worker"` — identifies the container as a worker |
| `OPENCODE_MCP_ID` | Compose generator | Numeric ID (1–5), used for container identification |
| `WORKSPACE_REPOS` | `INSTALL_WORKSPACE_REPOS` or `CODE_REPOS` | Comma-separated git URLs auto-cloned to `/workspace/` on startup |
| `OPENCODE_GO_KEY1`–`4` | AWS SM → Docker secret | OpenCode Go API keys with sequential fallback on rate-limit |


Deployment toggle: Set `opencode.count` (0–5) in `install.json` under `features.opencode` or pass `-InstallCodeContainers N` to `1Deploy.ps1`.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `INSTALL_AGENTIC_QA` | — | Removed. AQE tools are MCP-provided in mcp_opencode via `agentic-qe` package + `mcp_aqe` config |
| `SALES_ENV` | `beta` | Controls whether production sales pipeline operations are allowed. `beta` blocks production sends. `production` enables them. |

## Selective Test Execution

The test suite supports tag-based filtering via Pester 6's `-Tag` parameter. Use the `Invoke-ModuleTest` helper (exported by `ORCHESTRATOR.Core`) to run tests for a specific module:

```powershell
# Run only Config tests (~45 tests)
Invoke-ModuleTest -Module "Config"

# Run Deploy tests with pass-through result
Invoke-ModuleTest -Module "Deploy" -PassThru

# Run only Core tests
Invoke-ModuleTest -Module "Core"
```

### Tag taxonomy

| Tag | Test file(s) | Approx. count |
|-----|-------------|:-------------:|
| `Core` | `ORCHESTRATOR.Core.Tests.ps1` | 18 |
| `Config` | `ORCHESTRATOR.Config.Tests.ps1`, `0Config.Tests.ps1`, `0Helpers.Tests.ps1` | ~66 |
| `Setup` | `0Setup.Tests.ps1` | 12 |
| `Deploy` | `1Deploy.Tests.ps1`, `ORCHESTRATOR.Deploy.Tests.ps1` | ~56 |
| `Secrets` | `ORCHESTRATOR.Secrets.Tests.ps1` | 16 |
| `Provision` | `1Provision.Tests.ps1`, `ORCHESTRATOR.Provision.Tests.ps1`, `0Helpers.Tests.ps1` | ~29 |
| `Sentry` | `1Drone.Tests.ps1` | 27 |
| `Proxy` | `ORCHESTRATOR.ApiProxy.Tests.ps1`, `ORCHESTRATOR.ApiProxy.Runtime.Tests.ps1` | ~303 |
| `Host` | `ORCHESTRATOR.Host.Tests.ps1`, `0Helpers.Tests.ps1` | ~30 |
| All others | One-to-one with file name | See `Get-TestTagMap` |

Run the git-aware test suite before committing (only tests for changed modules, per workflow-primitives.md § Complete CC):

```powershell
# Git-aware: only tests covering changed modules. See workflow-primitives.md § Complete CC.
```

Regression-Only edge-case tests (Governance, TwoAgent, CredentialIsolation, Proxy Runtime edge cases) are run as part of Coder implementation of alignment plans via `Invoke-Pester -Path Tests -Tag "Regression-Only"` during standard workflow.

---

### Maintenance
* **When this file changes:** All agents automatically pick up the new configuration on next session startup.
* **Path verification:** Heartbeat checks should verify that paths listed here still exist and are accessible.