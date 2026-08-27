# mcp_opencode — OpenCode MCP Server

**Image**: `opencode:local` (from Docker registry)
**Ports**: 21000 (health), 21001 (MCP server), 20100–20199 (gateway ports for `oc-orch`)
**Auth**: Internal opencode keys (`OPENCODE_GO#_KEY` / `OPENCODE_GO#_ON`) — no `FLEET_API_TOKEN` required for opencode-MCP communication.

## Overview

`mcp_opencode` runs `opencode serve` as a fleet service, exposing the full opencode CLI toolset via SSE-based MCP protocol. It is the primary workhorse container for concurrent multi-session code execution. Each instance supports up to 5 concurrent sessions by default.

## Tools (provided by opencode serve)

- `bash` — shell command execution
- `read` — file reading
- `write` — file writing
- `edit` — file editing
- `glob` — file pattern matching
- `grep` — content search
- `task` — subagent task spawning
- `skill` — skill loading
- `webfetch` — URL content fetching
- `voice` — audio recording
- `todowrite` — task list management

## MCP Client Connections

`mcp_opencode` connects to downstream MCP servers defined in its `opencode.json` config:

| Server | URL | Auth Token |
|--------|-----|------------|
| `mcp_web` | `http://mcp_web:21005/mcp/sse` | `FLEET_API_TOKEN_WEB` |

> **AQE (agentic-qe)**: AQE tools are now accessed via direct HTTP REST calls to `http://mcp_aqe:21004/tools/:tool` — not through an MCP SSE connection. Use `Invoke-RestMethod -Uri "http://mcp_aqe:21004/tools/<tool>" -Method POST -Headers @{Authorization="Bearer <FLEET_API_TOKEN_AQE>"}`. See `docs/Reference/API-Contracts.md § 13. AQE Bridge` for the full REST contract.

## Related Skills

- `Skills/Workflows/Code/workflow.md` — Code mode workflow
- `Skills/Workflows/Review/workflow.md` — Review mode workflow
- `Skills/MCP/mcp-catalog.md` — MCP server catalog

## Common Usage

An opencode container (`oc-orch`, `oc-veri`, `oc-base`) calls `mcp_opencode` by configuring it as an MCP server in `opencode.json`. The entrypoint (`Infrastructure/opencode/entrypoint.sh`) handles secret hydration, key cycling, and config injection automatically.

## Source Code

- `Infrastructure/opencode/entrypoint.sh` — Entrypoint script
- `Infrastructure/opencode/Dockerfile` — Container build
- `Infrastructure/opencode/coding-opencode.json` — Coder persona config
