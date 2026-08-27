# Plan 2: Native CLI Inside Agent Containers (Deprecated)

**Status**: Archived — superseded by Plan 3 (n8n-orchestrated elastic CODE containers)

**Date**: 2026-05-02

---

## What This Approach Did

Instead of standalone CODE containers, coding CLI tools (`opencode`, `z.ai`) were installed directly inside ORCHESTRATOR agent containers (ORCH/VERI/WORK/BASE). The agent's `entrypoint.sh` probed for available API keys at startup and exported the first available key as `CODE_CLI_KEY`.

## Why It Was Replaced

1. **Agent bloat** — Every agent container needed Node.js, Python, and CLI binaries, increasing image size
2. **Key exposure** — All agents had access to coding keys, violating least-privilege
3. **No elasticity** — Static key mounting meant no dynamic scaling based on task complexity
4. **Resource contention** — Coding tasks competed with gateway inference for CPU/memory inside the same container

## Architecture

```
ORCH agent container
  ├── ORCHESTRATOR gateway (main process)
  ├── opencode CLI (installed at runtime or build time)
  ├── z.ai CLI (optional)
  └── Kimi Code CLI (optional)
```

## Files Involved

| File | Purpose |
|------|---------|
| `Modules/ORCHESTRATOR.CLI/ORCHESTRATOR.CLI.ps1` | Module manifest |
| `Modules/ORCHESTRATOR.CLI/Public/Find-AvailableCodingCli.ps1` | Auto-discovery of installed CLIs |
| `Modules/ORCHESTRATOR.CLI/Public/Get-BestCodingCli.ps1` | Priority-based selection |
| `Modules/ORCHESTRATOR.CLI/Public/Install-CodingCli.ps1` | On-demand install |
| `Modules/ORCHESTRATOR.CLI/Public/Invoke-CodingTask.ps1` | Task execution wrapper |
| `Modules/ORCHESTRATOR.CLI/Private/Resolve-CodeKeyPair.ps1` | Key cycling logic |
| `Modules/ORCHESTRATOR.CLI/Private/Test-CliHealth.ps1` | Health check |

## How to Revive

1. Restore `Modules/ORCHESTRATOR.CLI/` from this archive
2. Add coding secrets back to agent `secrets:` blocks in `Generate-FleetCompose`
3. Add `CODE_CLI_AUTO_INSTALL` and `CODE_CLI_PREFERRED` env vars to agent services
4. Restore CLI discovery block in `Infrastructure/entrypoint.sh`
5. Remove n8n-orchestrated CODE container workflow (Plan 3)

## Key Differences from Plan 3

| Aspect | Plan 2 (CLI in agents) | Plan 3 (n8n + elastic containers) |
|--------|----------------------|-----------------------------------|
| Coding keys | On every agent | Only on CODE containers + n8n |
| Docker access | None (agents), drone has sock | None (agents), n8n calls drone |
| Scaling | Static | Dynamic via n8n webhook |
| Resource isolation | Shared with gateway | Dedicated per-task containers |
| Lifetime | Infinite (key mounted forever) | Ephemeral (1 min to 2 hours) |
