# salmon-run

A file-based Kanban control plane with queue automation, dispatch, model routing,
quality gates, Mermaid repository chunking, archival, and public packaging.

This is the public, generalized package. It strips environment-specific
hostnames, tokens, and client paths so a new user can clone the repo and run a
single-command installer.

## Quick start

```powershell
.\install.ps1
```

The installer:
- creates your runtime home at `~/.salmon`
- places task queues, logs, cache, and runtime secrets under `~/.salmon`
- installs modules and wires `SALMON_RUN_HOME`

The source repo only contains code, docs, and tooling. No personal task data,
logs, or secrets are committed.

## State

The public package is now an installable, containerized, leak-clean control
plane. Items 1–7 of the remaining MVP scope are complete on `main`:
Devin/OpenRouter/DeepInfra executors, Mermaid repository chunking,
Docker/Swarm packaging, CI workflows, a parameterized `Sync-FromCanonical.ps1`,
branch/worktree cleanup, and completed plan routing.

Latest validation: `Orchestrator/Tests` **423 passed**, `Skills/Docker/Tests`
**103 passed**, `Invoke-LeakCheck.ps1` green, Docker build and dry-run green.

The canonical source-of-truth remains the private `salmon-orchestrator`
implementation; `salmon-run` is the scrubbed, generalized mirror.

## Quick start

```powershell
.\install.ps1
Start-SalmonRun.ps1 -DryRun
```

`install.ps1` copies modules to `~/.salmon/Modules`, wires `PSModulePath`, and
verifies a fresh `Import-Module SalmonRun.PondEngine`.

## Docker quick start

```powershell
.\deploy.ps1          # local: docker compose up --build
.\deploy.ps1 -Mode swarm  # Swarm: docker build + docker stack deploy
```

Or directly:

```bash
docker build -t salmon-run .
docker run --rm salmon-run -DryRun
```


## Personal data layout

| Data | Location |
|------|----------|
| Task queues (Intake, Code, Review, QA, Audit, Working, Complete, Archive, Failed, Manual, Handoffs, Temp, Logs) | `~/.salmon/Tasks/*` |
| Runtime cache | `~/.salmon/cache` |
| User/runtime secrets | `~/.salmon/secrets` |
| Local config | `~/.salmon/config.json` (copied from `config.example.json`) |
| Installed modules | `~/.salmon/Modules` or `$PSModulePath` |
| PID and heartbeat files | `~/.salmon/Tasks/Logs` |
