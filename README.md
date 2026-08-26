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

The public package is now an installable, leak-clean control plane. Wave 1–4
(PondLog I/O standardization, packaging, OpenCode, and DSH executors) are
integrated on `main`, with passing `Orchestrator/Tests` (408) and
`Skills/Docker/Tests` (103). `Invoke-LeakCheck.ps1` reports no private
references.

The canonical source-of-truth remains the private `salmon-orchestrator`
implementation; `salmon-run` is the scrubbed, generalized mirror.

## Quick start

```powershell
.\install.ps1
Start-SalmonRun.ps1 -DryRun
```

`install.ps1` copies modules to `~/.salmon/Modules`, wires `PSModulePath`, and
verifies a fresh `Import-Module SalmonRun.PondEngine`.


## Personal data layout

| Data | Location |
|------|----------|
| Task queues (Intake, Code, Review, QA, Audit, Working, Complete, Archive, Failed, Manual, Handoffs, Temp, Logs) | `~/.salmon/Tasks/*` |
| Runtime cache | `~/.salmon/cache` |
| User/runtime secrets | `~/.salmon/secrets` |
| Local config | `~/.salmon/config.json` (copied from `config.example.json`) |
| Installed modules | `~/.salmon/Modules` or `$PSModulePath` |
| PID and heartbeat files | `~/.salmon/Tasks/Logs` |
