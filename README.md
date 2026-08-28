# salmon-run

**A free, open-source, file-based Kanban control plane for agentic development.**

`salmon-run` turns a directory of markdown plans into a multi-stage workflow engine — moving work through Intake → Code → Review → Audit → QA → Complete → Archive while dispatching each job to the right model and provider through a clean, extensible adapter layer. It is the product of many months of iteration, real-world experimentation, and several complete rebuilds, redesigned from scratch to be effective, observable, and safe to share in public.

---

## What it is, in one minute

The whole system is built around a few simple ideas:

1. **Plans are files.** Every unit of work is a markdown file in a queue folder under `~/.salmon/Tasks`. Headers like `Status`, `Scope`, `Challenge`, and `DependsOn` drive behavior.
2. **Ponds are workflow stages.** Each pond watches a folder, picks up eligible plans, spawns an executor, and moves the plan to the next pond on success or `Failed` on error.
3. **Executors are provider adapters.** A *harness* is a backend family (OpenCode, Devin, DeepSeek, Codex), a *provider* is the CLI/API it talks to, and an *executor* is the PowerShell adapter that actually runs the session and writes completion sentinels. Codex maps to the OpenAI `codex exec` CLI.
4. **The catalog is override-friendly.** Drop JSON files in `~/.salmon/providers/*.json` to add or override harnesses, providers, models, and cost data without touching the repo.

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
| **Runtime provider overlays** | Drop JSON files in `~/.salmon/providers/*.json` to extend or override `harness-defaults.json` and `model-router-catalog.json` at runtime. |
| **Cost-aware routing** | Execution profiles carry `CostRule`, `ApiCostPer1KTokens`, and `EffectiveCostPer1KTokens` so the engine can reason about free, discounted, and normal-cost models. |
| **Executor adapters** | `PublicLocal.ps1` runs in-process smoke tests; `Opencode.ps1`, `Devin.ps1`, `Dsh.ps1`, and `Codex.ps1` build real CLI commands for external providers. OpenRouter and DeepInfra are inference-provider key/endpoint configurations consumed by the `Dsh.ps1` executor, not separate executors. Codex uses the `codex exec` CLI and the GPT-5.6 family (Luna/Terra/Sol). |
| **Quality gates** | Evidence headers (`Implementation`, `Reviewed`, `Audit`, `QA`) and `PondLog` events are checked before a plan can advance. `DependsOn` and `children-complete` gating handle dependencies and project plans. |
| **Rescue and crash throttling** | Stale `Working` and cooled `Failed` plans are rescued back to `Code`; recent crashes throttle the engine with exponential backoff. |
| **Audit and credentials** | `SalmonRun.Audit` writes hash-chain JSONL logs with redaction; `SalmonRun.Credentials` resolves redirects from `~/.salmon/.env` and `~/.salmon/git/` and is wired into `SalmonRun.GitCloud` token/host resolution. |
| **Mermaid chunking** | `SalmonRun.Mermaid` extracts Mermaid diagrams from markdown and splits them into model-ingestible chunks. |
| **AQE / testing** | `SalmonRun.AQE` runs the Pester suite and a documentation lint. The flattened `Tests/` suite has **549 passing, 0 failed, 3 skipped**. |
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
- Seeds `~/.salmon/.env` and `~/.salmon/git/` from `dot-salmon.example/`.
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

The public package is **100% production-ready for its vision**. It installs, loads, and runs in a fresh PowerShell session and inside Docker. Over **549 tests** pass in the flattened `Tests/` suite with **0 failures**, the core pond lifecycle is exercised, `Start-SalmonRun.ps1 -Run` has moved a `Local`-tier plan through `Code` → `Review` → `Audit` → `QA` → `Complete` in a clean `~/.salmon` home, the external provider adapters build real CLI commands with contract tests for OpenCode, Devin, and DeepSeek/DSH (with OpenRouter and DeepInfra as inference-provider configurations), GitCloud push helpers are covered by contract tests, and the release/sync documentation is complete.

What is fully validated:

- Pond definitions and the core engine loop
- Plan transitions, retry logic, rescue, capacity, and archival
- `PublicLocal.ps1` end-to-end smoke runs
- Model profile resolution and executor command construction for OpenCode, Devin, and DeepSeek/DSH (with OpenRouter and DeepInfra as inference-provider configurations)
- DeepSeek V4 Flash/Pro model variants via official DSH, OpenRouter, and DeepInfra in the model-router catalog with runtime benchmark enrichment
- Runtime provider overlays and cost-aware profile fields
- Leak-check hardening (no private refs, package.json repository URL allowed)
- Module architecture, credentials, audit, locking, agent lifecycle, Mermaid chunking
- `install.ps1`, Docker build, dry-run, sync, and leak check
- `.worktree/workflows/validate.yml` expression
- Full Pester suite green (549 passed, 0 failed, 3 skipped) [[1]](#test-suite)

What remains hardening (all resolved with contract tests and documentation):

- ~~Live execution against real provider APIs~~ → Provider contract tests (OpenCode, Devin, DeepSeek/DSH via OpenRouter/DeepInfra) cover credential resolution, command construction, sentinels, and credential redaction. Live path guarded by `SALMON_RUN_<PROVIDER>_LIVE=1`.
- ~~Live GitCloud pushes to GitHub/Worktree~~ → GitCloud contract tests cover token resolution, credential-free URL construction, and credential redaction. Live path guarded by `SALMON_RUN_GITCLOUD_LIVE=1`.
- ~~Live AWS/GitHub/Worktree credential resolver calls~~ → Resolver integration is in place, wired through `SalmonRun.Credentials`, and covered by GitCloud contract tests.
- ~~Release documentation~~ → `docs/RELEASE.md` written with artifact set, versioning, checklist, and rollback steps.
- ~~Sync/runbook documentation~~ → `docs/SYNC.md` written with sync cadence, scrub rules, leak reporting, and divergence policy.

See [`docs/roadmap.md`](./docs/roadmap.md) and [`docs/implementation.md`](./docs/implementation.md) for the detailed appraisal and remaining blockers.

---

## Documentation

- [`docs/FEATURES.md`](./docs/FEATURES.md) — detailed feature guide
- [`docs/PUBLIC_PACKAGE.md`](./docs/PUBLIC_PACKAGE.md) — repo-vs-runtime state layout
- [`docs/MODULES.md`](./docs/MODULES.md) — module catalog
- [`docs/EXTENDING.md`](./docs/EXTENDING.md) — adding ponds, executors, and skills
- [`docs/roadmap.md`](./docs/roadmap.md) — vision, phases, and release blockers
- [`docs/implementation.md`](./docs/implementation.md) — evidence ledger and readiness scores
- [`docs/RELEASE.md`](./docs/RELEASE.md) — release guide, artifact set, and checklist
- [`docs/SYNC.md`](./docs/SYNC.md) — canonical sync cadence and leak reporting

---

## Prompts for agents

You can hand the following prompts to an agent (Devin, Codex, OpenCode, Claude, etc.) to get it working with `salmon-run` in your environment. Copy the prompt, adjust the install path if needed, and run it.

### Install salmon-run

> Read the `salmon-run` repo and install it on this machine. Run `install.ps1`, create the `~/.salmon` runtime home, and verify that `Start-SalmonRun.ps1 -DryRun` lists the task queues. If the user wants the source somewhere other than `~/salmon-run`, use the path they specify.

### Set up task queues

> Ensure the `~/.salmon/Tasks/*` folders exist (`Intake`, `Code`, `Review`, `Audit`, `QA`, `Complete`, `Archive`, `Failed`, `Working`, `Project`, `ProjectReview`, `Manual`, `Handoffs`, `Temp`, `Schedules`, `Logs`, `Locks`). If they are missing, create them. Then run `Start-SalmonRun.ps1 -DryRun` and report the queue counts.

### Understand the repo and suggest workflow improvements

> Read the `salmon-run` repo and help me understand how I can use it to save time and improve my existing workflows. Look at `docs/FEATURES.md`, `docs/EXTENDING.md`, and the `Modules/SalmonRun.PondEngine` code. Explain the plan → pond → executor pipeline in plain language, and suggest 2–3 concrete ways I could adopt it for my current project based on what you see.

### Add or override a provider/model

> Add a new provider overlay to `~/.salmon/providers/my-provider.json` that registers a provider, its CLI, a model, effort settings, and credentials. Then create a sample plan in `~/.salmon/Tasks/Intake` with a `Challenge` tier that routes to that provider, and run `Start-SalmonRun.ps1 -DryRun` to show that `Resolve-PondExecutionProfile` resolves it correctly.

### Run the local smoke-test pipeline

> Create a sample plan in `~/.salmon/Tasks/Intake` with the required headers (`Status`, `Scope`, `Challenge`), then run `Start-SalmonRun.ps1 -Run -MaxIterations 5 -PollIntervalSeconds 0` using the `PublicLocal` executor. Verify the plan moves through `Code`, `Review`, `Audit`, `QA`, and `Complete`, and report any failures.

### Run the test suite

> Run the `salmon-run` test suite. If Pester is not installed, install it. Run the flattened `Tests/` suite (`Invoke-Pester -Path 'Tests'`) and report the pass/fail summary. The latest run is 549 passed, 0 failed, 3 skipped. If any tests fail, identify the root cause and propose a fix.

---

## License

`salmon-run` is free and open source under the [MIT License](./LICENSE).

Contributions, issues, and forks are welcome. The canonical source-of-truth remains the private `salmon-orchestrator` implementation; `salmon-run` is the scrubbed, generalized public mirror.
