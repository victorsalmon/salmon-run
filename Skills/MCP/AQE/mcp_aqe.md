# mcp_aqe — Agentic Quality Engineering MCP Server (DEPRECATED)

> **Retirement status**: The `mcp_aqe` container is being replaced by the cross-harness `aqe` skill (`Skills/AQE/SKILL.md`). Use `/aqe` or the `mcp-aqe` plugin in any supported harness (Devin, OpenCode, Codex, Z-Code) instead of calling the container's HTTP API directly. The container remains available for legacy callers that have not yet migrated, but new work should use the cross-harness skill.

**Image**: `mcp_aqe:local`
**Port**: 21004
**Auth**: `FLEET_API_TOKEN_MCP_AQE` (inter-service bearer token)

## Overview

`mcp_aqe` provides quality engineering and code intelligence tools via SSE-based MCP. It wraps the upstream `aqe-mcp` CLI tool, connecting to an AQE daemon for test generation, coverage analysis, defect prediction, and memory operations.

## Tools (MCP SDK)

| Tool | Description |
|------|-------------|
| `register_domains` | Register AQE domains (test-generation, coverage-analysis, etc.) |
| `task_submit` | Submit a quality engineering task for execution |
| `reset_index` | Reset HNSW index for memory operations |
| `memory_store` | Store a value in AQE memory by key |
| `memory_retrieve` | Retrieve a value from AQE memory by key |
| `memory_query` | Query AQE memory by pattern |
| `memory_delete` | Delete a value from AQE memory by key |
| Generic tool proxy | Forward any tool call to the AQE MCP daemon (`POST /tools/:tool`) |

## REST Endpoints (non-MCP HTTP API)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Liveness check (`{status, service, version, uptime, tools, connected}`) |
| GET | `/api/ready` | Readiness probe (checks AQE MCP connection) |
| GET | `/api/credentials` | Credential validity |
| GET | `/api/routes` | Route discovery |
| GET | `/api/version` | Version info |
| POST | `/tools/register_domains` | Register AQE domains (JSON body) |
| POST | `/tools/task_submit` | Submit AQE task |
| POST | `/tools/reset_index` | Reset HNSW index |
| POST | `/tools/:tool` | Generic tool proxy |

## Fleet Domains

The AQE system manages 12 fleet domains: `test-generation`, `test-execution`, `coverage-analysis`, `quality-assessment`, `defect-intelligence`, `requirements-validation`, `code-intelligence`, `security-compliance`, `contract-testing`, `visual-accessibility`, `chaos-resilience`, `learning-optimization`.

## Related Skills

- `Skills/AQE/aqe-pester-coverage.ps1` — Pester test coverage analysis
- `Skills/AQE/aqe-script-analyzer.ps1` — PowerShell script analysis
- `Skills/AQE/aqe-compare-baseline.ps1` — Baseline comparison
- `Skills/AQE/aqe-full-evaluation.ps1` — Full evaluation suite
- `Skills/AQE/Invoke-ORCHESTRATORDefectPredict.ps1` — Defect prediction
- `Skills/AQE/aqe-sprint-quality-gate.ps1` — Sprint quality gate
- `Skills/AQE/aqe-veri-review-gate.ps1` — VERI review gate
- `Skills/MCP/mcp-catalog.md` — MCP server catalog

## Common Usage

Trigger phrases: "run Pester coverage", "analyze scripts", "compare baselines", "evaluate quality".

## Source Code

- `Infrastructure/aqe-mcp-server.js` — Server implementation <!-- doc-lint: exempt -->
- `Infrastructure/mcp_aqe.Dockerfile` — Container build
