# salmon-run

**A free, open-source, file-based Kanban control plane for agentic development.**

`salmon-run` turns a directory of markdown plans into a multi-stage workflow engine — moving work through Intake → Code → Review → Audit → QA → Complete → Archive while dispatching each job to the right model and provider through a clean, extensible adapter layer. It is the product of many months of iteration, real-world experimentation, and several complete rebuilds, redesigned from scratch to be effective, observable, and safe to share in public.

---

## What it is, in one minute

The whole system is built around three simple ideas:

1. **Plans are files.** Every unit of work is a markdown file in a queue folder under `~/.salmon/Tasks`. Headers like `Status`, `Scope`, `Challenge`, and `DependsOn` drive behavior.
2. **Ponds are workflow stages.** Each pond watches a folder, picks up eligible plans, spawns an executor, and moves the plan to the next pond on success or `Failed` on error.
3. **Executors are provider adapters.** A *harness* is a backend family (OpenCode, Devin, DeepSeek, Codex), a *provider* is the CLI/API it talks to, and an *executor* is the PowerShell adapter that actually runs the session and writes completion sentinels.

That separation means you can add a new model or provider without touching the engine, and you can run the entire pipeline locally with the `PublicLocal` smoke-test executor before you connect a real external API.

---

## Why salmon-run exists

Most agentic workflow tools either lock you into a vendor, hide state in a database, or require you to orchestrate many moving parts by hand. We wanted something different:

- **Human-inspectable:** queue state is just files and folders.
- **Provider-agnostic:** one engine, many adapters.
- **Safe to share:** all runtime state lives in `~/.salmon`; the repo contains no secrets, hostnames, or client paths.
- **Rebuilt for efficacy:** this public package is the result of months of iteration, experimentation, and hard-won lessons from the private `salmon-orchestrator` project. It was rewritten from scratch to be generalized, installable, and genuinely useful as public infrastructure.

`salmon-run` is free and open source under the [MIT License](./LICENSE).

---

## Core features

| Feature | What it does |
| --- | --- |
| **File-based Kanban queues** | Plans are markdown files in `~/.salmon/Tasks/{Intake,Code,Review,Audit,QA,Complete,Archive,Failed,Working,Project,ProjectReview,Manual,Handoffs,Temp,Schedules,Logs}`. |
| **Pond engine** | `Start-PondEngine` runs a configurable loop of ponds, each with entry gates, task pipelines, parallelism limits, and success/failure transitions. |
| **Model routing** | `Resolve-PondExecutionProfile` selects a `Harness` × `Provider` × `Model` × `Effort` based on the plan's `Challenge` tier and a JSON catalog. |
| **Executor adapters** | `PublicLocal.ps1` runs in-process smoke tests; `Opencode.ps1`, `Devin.ps1`, `Dsh.ps1`, `OpenRouter.ps1`, and `DeepInfra.ps1` build real CLI commands for external providers. |
| **Quality gates** | Evidence headers (`Implementation`, `Reviewed`, `Audit`, `QA`) and `PondLog` events are checked before a plan can advance. `DependsOn` and `children-complete` gating handle dependencies and project plans. |
| **Rescue and crash throttling** | Stale `Working` and cooled `Failed` plans are rescued back to `Code`; recent crashes throttle the engine with exponential backoff. |
| **Audit and credentials** | `SalmonRun.Audit` writes hash-chain JSONL logs with redaction; `SalmonRun.Credentials` resolves redirects from `~/.salmon/.env` without storing secrets in the repo. |
| **Mermaid chunking** | `SalmonRun.Mermaid` extracts Mermaid diagrams from markdown and splits them into model-ingestible chunks. |
| **AQE / testing** | `SalmonRun.AQE` runs the Pester suite and a documentation lint. The Orchestrator suite has **423 passing** tests and the Docker/Skills suite has **103 passing** tests. |
| **Docker & Swarm packaging** | `Dockerfile`, `docker-compose.yml`, `docker-compose.swarm.yml`, and `deploy.ps1` support local container and Swarm deploys. |
| **Canonical sync & leak check** | `scripts/Sync-FromCanonical.ps1` copies from the private source with a runtime scrub; `scripts/Invoke-LeakCheck.ps1` verifies no private references are committed. |

For a deeper feature walkthrough, see [`docs/FEATURES.md`](./docs/FEATURES.md).

---

## Quick start

### Install

Requires PowerShell 7 or later.

```powershell
.\install.ps1
```

What it does:

- Creates `~/.salmon` for all runtime state.
- Copies modules to `~/.salmon/Modules`.
- Wires `SALMON_RUN_HOME` into your user `PSModulePath`.
- Seeds `~/.salmon/.env` from `dot-salmon.example/.env.example`.
- Verifies `Import-Module SalmonRun.PondEngine` loads cleanly.

### Preview the queues

```powershell
.\Start-SalmonRun.ps1 -DryRun
```

This lists the pond configuration, stream count, and the number of plans in each queue without spawning agents.

### Run the engine

```powershell
.\Start-SalmonRun.ps1 -Run -MaxIterations 1 -PollIntervalSeconds 0
```

For a single iteration without sleeping between polls.

---

## Docker quick start

```powershell
.\deploy.ps1                    # local: docker compose up --build
.\deploy.ps1 -Mode swarm        # Swarm: docker build + docker stack deploy
```

Or directly:

```bash
docker build -t salmon-run .
docker run --rm salmon-run -DryRun
```

---

## Runtime data layout

All mutable state stays outside the repo:

| Data | Location |
| --- | --- |
| Task queues | `~/.salmon/Tasks/*` |
| Runtime cache | `~/.salmon/cache` |
| User/runtime secrets | `~/.salmon/secrets` |
| Local config | `~/.salmon/config.json` (from `dot-salmon.example/config.example.json`) |
| Installed modules | `~/.salmon/Modules` |
| PID and heartbeat files | `~/.salmon/Tasks/Logs` |

The repo itself only contains code, docs, and tooling. No personal task data, logs, or secrets are committed.

---

## Project status

The public package is approximately **80% production-ready for its vision**. It installs, loads, and runs in a fresh PowerShell session and inside Docker. The full test suites pass, the core pond lifecycle is exercised, the local executor works end-to-end, and the external provider adapters build real CLI commands.

What is fully validated:

- Pond definitions and the core engine loop
- Plan transitions, retry logic, rescue, capacity, and archival
- `PublicLocal.ps1` end-to-end smoke runs
- Model profile resolution and executor command construction for OpenCode, Devin, DSH, OpenRouter, and DeepInfra/Codex
- Module architecture, credentials, audit, locking, agent lifecycle, Mermaid chunking
- `install.ps1`, Docker build, dry-run, sync, and leak check

What remains hardening:

- Live execution against real provider APIs
- One `DependsOn` property-test edge case
- Replacing placeholder URLs in `package.json` and `model-router-catalog.json`
- Fixing a `.worktree/workflows/validate.yml` expression
- A full end-to-end `Start-SalmonRun.ps1 -Run` with real plans

See [`docs/roadmap.md`](./docs/roadmap.md) and [`docs/implementation.md`](./docs/implementation.md) for the detailed appraisal and remaining blockers.

---

## Documentation

- [`docs/FEATURES.md`](./docs/FEATURES.md) — detailed feature guide
- [`docs/PUBLIC_PACKAGE.md`](./docs/PUBLIC_PACKAGE.md) — repo-vs-runtime state layout
- [`docs/MODULES.md`](./docs/MODULES.md) — module catalog
- [`docs/EXTENDING.md`](./docs/EXTENDING.md) — adding ponds, executors, and skills
- [`docs/roadmap.md`](./docs/roadmap.md) — vision, phases, and release blockers
- [`docs/implementation.md`](./docs/implementation.md) — evidence ledger and readiness scores

---

## License

`salmon-run` is free and open source under the [MIT License](./LICENSE).

Contributions, issues, and forks are welcome. The canonical source-of-truth remains the private `salmon-orchestrator` implementation; `salmon-run` is the scrubbed, generalized public mirror.
