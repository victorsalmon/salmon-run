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

This repository is a public packaging skeleton. The canonical source-of-truth
remains the private `salmon-orchestrator` implementation. The `scripts/` folder
contains a sync-and-scrub toolkit; the actual canonical projection will land
here after a full leak-clean pass.

## Personal data layout

| Data | Location |
|------|----------|
| Task queues (Intake, Code, Review, QA, Audit, Working, Complete, Archive, Failed, Manual, Handoffs, Temp, Logs) | `~/.salmon/Tasks/*` |
| Runtime cache | `~/.salmon/cache` |
| User/runtime secrets | `~/.salmon/secrets` |
| Local config | `~/.salmon/config.json` (copied from `config.example.json`) |
| Installed modules | `~/.salmon/Modules` or `$PSModulePath` |
| PID and heartbeat files | `~/.salmon/Tasks/Logs` |
