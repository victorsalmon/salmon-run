# salmon-run — Feature Guide

`salmon-run` is a public, file-based Kanban control plane for agentic development. It coordinates plans through a multi-stage workflow, dispatches them to the right model and provider, and keeps all runtime state outside the source repo.

This guide describes what the package does and how the major features fit together.

---

## 1. What salmon-run is

At its heart, `salmon-run` is a **queue-driven workflow engine** that uses the filesystem as its task board:

- Work is represented by markdown **plan files** that live in queue folders under `~/.salmon/Tasks`.
- Each queue is called a **pond**. Plans move from pond to pond as they are picked up, worked on, reviewed, audited, tested, and archived.
- A pond can spawn an **agent** (a local PowerShell executor or an external provider CLI) to do the work.
- The engine routes a plan to a **model/provider** based on its `Challenge` tier and the configurable model catalog.
- All mutable state — queues, logs, cache, secrets — lives in `~/.salmon` (or `%SALMON_RUN_HOME%`). The repo itself contains only code, docs, and tooling.

This repository is the public source of truth for the packaged engine. Projection tooling and `scripts/Invoke-LeakCheck.ps1` keep runtime-specific paths, hosts, and credentials out of distributable code.

---

## 2. File-based task queues

`salmon-run` uses a simple, inspectable folder layout. The installer creates these directories in `~/.salmon/Tasks`:

| Folder | Purpose |
| --- | --- |
| `Intake` | New plans and feature-discovery stubs |
| `Code` | Plans ready for implementation |
| `Review` | Implementation evidence awaiting review |
| `Audit` | Reviewed plans awaiting best-practice/safety audit |
| `QA` | Plans ready for property/mutation testing |
| `Complete` | Finished plans before archival |
| `Archive` | Compressed archived plans |
| `Failed` | Plans that failed after retries |
| `Working` | Plans currently in progress (with lock files) |
| `Project` / `ProjectReview` | Large plans split into child plans |
| `Investigate` | Plans that diagnose recurring feedback failures and improve the engine/prompts |
| `Paused` | Plans held for human triage after a non-retryable or engine failure |
| `Manual` / `Handoffs` / `Temp` / `Schedules` / `Logs` | Human action stubs, handoffs, drafts, schedules, and runtime logs |

Plan files are markdown with YAML-ish front-matter headers (`Status`, `Scope`, `Challenge`, `DependsOn`, etc.). The engine reads and rewrites these files as it advances them through the pipeline.

See `docs/PUBLIC_PACKAGE.md` for the full separation between repo paths and the runtime home.

---

## 3. The pond engine

`Start-PondEngine` is the main orchestration loop. It is configured by a list of `Pond` objects (defaults come from `Get-SalmonRunPonds`) and a set of `PondStream` objects (one stream per branch/worktree).

Each pond has:

- A **folder** to watch and a **role** to perform (`planner`, `coder`, `reviewer`, `auditor`, `qa`, `project-planner`, `project-reviewer`, `investigator`, `archiver`).
- **Operators** that control parallelism (`ParallelCount`, `MinGuarantee`, `MaxNewPerIteration`).
- An **entry gate** with `EvidenceGate` and `RequiredHeaders` so plans can only enter when they have the right evidence.
- A **task pipeline**: `Claim → Prepare → ModelRoute → Spawn → Monitor → Transition` (most ponds) or specialized tasks such as `PlanProject` and `Archive`.
- **Success/failure transitions**, with retries and a final fallback.

The engine performs one loop per pond:

1. **Recover** only lease-proven orphaned lanes; engine errors fail closed to `Paused`.
2. **Get candidates** that satisfy the pond's entry gate.
3. **Group** candidates by namespace or file name.
4. **Select** groups within capacity limits.
5. **Assign a free lane** (a per-stream work directory).
6. **Run the pond's task pipeline**.
7. **Validate and transition** the plan atomically, then enqueue Git synchronization.

Key engine behaviors:

- **Lease recovery / crash throttling**: recovery requires a dead PID, stale heartbeat, unchanged lease generation, and no completed result. `Get-PondCapacity` throttles new work after recent crashes.
- **Capacity and lanes**: `Get-FreePondLane` and `Select-PondGroups` enforce per-pond and per-stream limits.
- **Archive**: `Invoke-PondTaskArchive` compresses completed plans older than 7 days.

See `Modules/SalmonRun.PondEngine/Public/Start-PondEngine.ps1` and `Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1`.

---

## 4. Plan lifecycle and quality gates

A plan advances through the default pipeline:

`Intake → Code → Review → Audit → QA → Complete → Archive`

Semantic failures receive one targeted repair after the initial attempt, then escalate to `Investigate`. Transport receives two retries before `Paused`; identical repeated failures escalate immediately. Invalid configuration, missing mutation tooling, and other human choices route directly to `Intake`. The full lifecycle is shown in `docs/orchestrator-architecture.md`.

Each step emits a structured gate result. For compatibility and human inspection, the coordinator maintains bounded current evidence on the plan:

- `Code` adds an `**Implementation**:` header and a `PondLog` `implement` event.
- `Review` checks for implementation evidence and adds `**Reviewed**:`.
- `Audit` runs secrets/docs, lint/static, build, focused regression, then AQE; 4C is invoked only for a discovered defect.
- `QA` builds the complete applicable test pipeline and must name a validated JSON proof with at least 95% raw changed-code mutation coverage.

`PublicLocal.ps1` (the in-process PowerShell smoke-test executor) writes the legacy evidence markers and canonical `PondLog` entries. External executors write `spawn`, `external-complete`, and `external-fail` events.

### Quality gates

`Get-PondCandidates` enforces the pond's `EvidenceGate` and `RequiredHeaders`. For example, a plan in `Review` must have `**Implementation**:` evidence (or a matching `PondLog` action). Invalid plans are moved to `Paused`.

### Dependency gating

A plan can list `**DependsOn**` headers. `Test-PlanDependencySatisfied` holds the child in `Code` until all named parent plans are in `Complete`, `Archive`, or `ProjectReview`. Implementation and property tests are green.

### Project plans

The `Project` pond runs `Invoke-PondTaskPlanProject` to split a large plan into child `Code` plans plus a `ProjectReview` plan. The `ProjectReview` pond waits until all child plans are `Complete` (`children-complete` gate) before finishing.

### Bounded rework and Investigator

Retry state is stored per plan and gate, so restarts cannot reset the budget. Transport and semantic failures have separate bounded attempts. A repeated identical failure signature trips the circuit breaker on its second occurrence; six transitions without forward progress in 30 minutes pause the family. Feedback is an attempt-linked sidecar on the canonical plan rather than a second circulating plan family.

When repeated semantic failure requires diagnosis, the plan escalates to the `Investigate` pond. Investigator is a writer role and therefore shares the same canonical-repository exclusion as Code, Audit, and QA.

See `Modules/SalmonRun.PondEngine/Private/PondAttemptState.ps1`, `PondFeedbackSidecar.ps1`, and `PondTasks/Invoke-PondTaskTransition.ps1`.

---

## 5. Model routing and executor adapters

Before `Spawn`, the router resolves every execution field independently from confirmed plan overrides, pond configuration, global configuration, and finally the provider catalog. Invalid or over-budget combinations route to Intake without spawning.

### Execution profile

A `PondExecutionProfile` has these dimensions:

| Field | Meaning | Example |
| --- | --- | --- |
| `Tier` | Plan difficulty / cost tier | `Flash`, `Daily`, `Complex`, `Frontier`, `Local` |
| `Harness` | Backend family | `local`, `opencode`, `devin`, `deepseek`, `codex` |
| `Provider` | CLI/API that talks to the model | `local`, `opencode-go`, `opencode`, `devin`, `dsh`, `openrouter`, `deepinfra`, `codex` |
| `Model` | Provider-specific model slug | `opencode-go/mimo-v2.5`, `opencode-go/deepseek-v4-flash`, `swe-1-7`, `deepseek-v4-flash`, `gpt-5.6-luna` |
| `Effort` | Model effort/depth hint | `max`, `medium`, `default`, `low`, `high` |
| `Cli` | The actual executable name | `opencode`, `devin`, `dsh`, `codex`, `powershell` |
| `ExecutorFile` | The Salmon Run adapter to launch | `Opencode`, `Devin`, `Dsh`, `Codex`, `PublicLocal` |
| `TimeoutMinutes` | Subprocess timeout | `30` |
| `Credentials` | Credential name(s) to resolve | `OPENCODE_GO_KEY`, `DEVIN_API_KEY`, `OPENAI_API_KEY`, etc. |

### Why "executor"?

In salmon-run, **provider** is the service/CLI you are calling, **harness** is the backend family, and **model** is the specific endpoint. The **executor** is the Salmon Run PowerShell adapter that actually runs the session: it resolves credentials, builds the CLI command, starts the process, monitors it, writes `.complete`/`.failed` sentinels, and appends `PondLog` events. It is the bridge between the pond engine and the provider CLI.

See `Modules/SalmonRun.PondEngine/Classes/Pond.ps1`, `Resolve-PondExecutionProfile.ps1`, `Get-PondExecutorCommand.ps1`, and `Get-PondExecutorRegistry.ps1`.

### Executor adapters

`Modules/SalmonRun.PondEngine/Executors/` contains the runtime adapters:

| Executor | What it does | Real-provider status |
| --- | --- | --- |
| `PublicLocal.ps1` | In-process PowerShell smoke-test executor. Appends role evidence, writes `.complete`, and logs events. No real agent is called. | Fully working for smoke tests. |
| `Opencode.ps1` | Runs `opencode run --command <prompt> --model ... --variant ... --auto -f ...` | Builds real commands; live CLI/API not validated in this appraisal. |
| `Devin.ps1` | Runs the `devin` CLI with `DEVIN_API_KEY`. | Builds real commands; live API not validated. |

| `Dsh.ps1` | Runs `dsh --profile headless` for the `deepseek` harness; routes to official DeepSeek, OpenRouter, or DeepInfra by selecting endpoint, credential, and model slug. | Builds real commands; live API not validated. |
| `Codex.ps1` | Runs `codex exec -m <model> -C <workdir> -c model_reasoning_effort=<effort> --output-last-message <out> -` with the prompt piped via stdin. Supports `gpt-5.6-luna`, `gpt-5.6-terra`, and `gpt-5.6-sol`. | Live `gpt-5.6-luna` validated. |
| `Local.ps1` | Legacy stub that delegates to `ExternalPublicSafe.ps1`. | Not a real executor. |
| `ExternalPublicSafe.ps1` | Public-safe placeholder for providers not yet configured. | Not a real executor. |

The default model/harness/provider mapping lives in `Modules/SalmonRun.PondEngine/Config/model-router-catalog.json` and `harness-defaults.json`.

---

## 6. Agent lifecycle and locking

### Agent lifecycle

`SalmonRun.AgentLifecycle` tracks agents:

- `Write-AgentPidFile` and `Write-AgentHeartbeat` record which agents are running.
- `Test-AgentAlive` checks a PID/heartbeat to detect crashes.
- `Clear-StaleAgentFiles` removes leftover PID and heartbeat files.

### Locking

`SalmonRun.Locking` provides file- and namespace-based locking so multiple agents can safely pick plans from the same queue:

- `Lock-File` / `Unlock-File` for plan-level file locks.
- `Register-Namespace` / `Remove-NamespaceReservation` for namespace reservations.

These are used by the pond engine when claiming files and lanes.

---

## 7. Credentials and security

Runtime credentials live in `~/.salmon/.env` as *redirects*, not as committed secrets. Git-hosting tokens are additionally stored in `~/.salmon/git/` (seeded from `dot-salmon.example/git/` by `install.ps1`) and referenced from `.env` with the `File` resolver. `SalmonRun.Credentials` supports several resolver types:

- `Env` — read from a process environment variable.
- `File` — read from a file path such as `~/.salmon/git/worktree-api-token`.
- `AWS` — read from AWS Secrets Manager or `~/.aws/credentials`/`~/.aws/config`.
- `GitHub` / `Worktree` — read from the respective secret stores.
- Literal values and custom resolvers.

`SalmonRun.GitCloud` token helpers (`Get-GitHubToken`, `Get-WorktreeToken`, `Get-SalmonRunGitCloudToken`) and `Get-WorktreeHost` now fall back to `SalmonRun.Credentials` when a token or host is not in a process environment variable, so `~/.salmon/.env` redirects drive GitCloud without duplicating secrets. Secret values are never logged.

`SalmonRun.Audit` provides JSONL audit logging with:

- Hash-chain integrity (`New-HashChainEntry`, `Test-AuditChainIntegrity`).
- Secret redaction in URIs, headers, and JSON (`Invoke-RedactSecrets`).
- A wrapped `Invoke-ApiCall` helper.

`scripts/Invoke-LeakCheck.ps1` scans the public package for private hostnames, tokens, client paths, and credential-like strings. The installer seeds `dot-salmon.example/.env.example` so the user can supply redirects without editing the repo.

---

## 8. Configuration

`SalmonRun.Config` loads and validates the runtime configuration:

- `Read-InstallJson` / `Update-InstallJsonKey` for `install.json`.
- `Get-ConfigValue` resolves config with the precedence chain: env > alias > `install.json` > default.
- `Resolve-StringPlaceholders` replaces placeholders such as `{Owner}` and `{Project}`.
- `Test-SalmonRunConfigSchema` validates the config against a schema.

The installer creates `~/.salmon/config.json` from `dot-salmon.example/config.example.json`.

---

## 9. Mermaid repository chunking

`SalmonRun.Mermaid` extracts Mermaid diagrams from repository markdown and splits them into model-ingestible chunks:

- `Get-RepoMermaidChunks` collects Mermaid fenced blocks.
- `Split-RepoMermaidChunks` writes per-file chunk outputs.

This is intended to feed context into intake/planning ponds.

---

## 10. Agentic Quality Engineering (AQE)

`SalmonRun.AQE` is the public test runner:

- `Invoke-SalmonRunPesterSuite` runs the full Pester suite.
- `Invoke-SalmonRunDocLint` checks `docs/`, `AGENTS.md`, and `Skills/**/*.md` for broken file references.
- `Invoke-SalmonRunAQEBridge` optionally reports results to an AQE bridge when `SALMON_AQE_BRIDGE_URI` is set.

The repo has a single flattened test suite under `Tests/`:

- Module and engine tests for the control-plane modules.
- Cross-cutting utility-module tests for helpers, setup, display, and git/CI.

All tests pass in the latest appraisal (**686 passed, 0 failed, 10 skipped**).

---

## 11. GitCloud helpers

`SalmonRun.GitCloud` abstracts git-hosting operations:

- Token resolution (`Select-SalmonRunGitCloudToken`) that falls back to `SalmonRun.Credentials` resolvers.
- Authenticated pushes (`Push-WorktreeRepository`, `Push-GitHubRepository`).
- CI run status (`Get-WorktreeCiRun`).
- Repo secret setting (`Set-WorktreeRepositorySecret`).

It supports GitHub and a generic Gitea-compatible host (Worktree). Token and host values can be resolved from `~/.salmon/.env` via `Env`, `File`, `AWS`, `GitHub`, or `Worktree` resolvers. Live push integration is not part of the current test suite.

---

## 12. Docker and deployment

The package is containerized:

- `Dockerfile` builds a `salmon-run` image.
- `docker-compose.yml` runs a local container.
- `docker-compose.swarm.yml` deploys to Docker Swarm.
- `deploy.ps1` handles local (`docker compose up --build`) and swarm (`docker stack deploy`) modes.

A dry run in Docker succeeds:

```bash
docker build -t salmon-run .
docker run --rm salmon-run -DryRun
```

---

## 13. CI and canonical sync

GitHub and Worktree workflows:

- `.github/workflows/test.yml` runs the Pester suite and leak check on `windows-latest`.
- `.github/workflows/docker.yml` builds the Docker image on `ubuntu-latest`.
- `.worktree/workflows/validate.yml` mirrors the GitHub test flow.

This public repository is canonical. `scripts/Sync-ToPrivate.ps1` copies only entries in `scripts/public-to-private.manifest.json` to a private consumer; `Test-PrivateParity.ps1` fails on drift. Runtime queues, credentials, deployment extensions, plugins, and internal docs are protected. `Sync-FromCanonical.ps1` is retired, and the public leak check remains a release gate.

---

## 14. Top-level runner

`Start-SalmonRun.ps1` is the user-facing entry point:

- Bootstraps the module environment (`Initialize-InterclawEnvironment`).
- Confirms or creates `~/.salmon` runtime directories.
- `-DryRun` lists ponds, stream count, and current queue counts without spawning agents.
- `-Run` invokes `Start-PondEngine` to process plans.

`Run-SalmonRun.ps1` is the unattended supervisor/watchdog. It runs `Start-PondEngine` in a loop, manages the process `PSModulePath` hygiene, and restarts the engine on failure. It is intended for long-running orchestration, not for interactive use.

`install.ps1` is the single-command installer:

- Creates `~/.salmon` and all task queue folders.
- Copies `Modules/` and `Modules/` to `~/.salmon/Modules/`.
- Wires `SALMON_RUN_HOME` into the user `PSModulePath`.
- Seeds `~/.salmon/.env` and `~/.salmon/git/` from `dot-salmon.example/`.
- Validates a fresh `Import-Module SalmonRun.PondEngine`.

---

## 15. Module architecture

The package is split into two module trees. `docs/MODULES.md` has the full catalog. Highlights:

### Control-plane modules

- `SalmonRun.PondEngine` — engine, pond classes, dispatch, model routing, executor registry.
- `SalmonRun.AgentLifecycle` — PID/heartbeat/stale cleanup.
- `SalmonRun.AQE` — Pester runner, doc lint, optional AQE bridge.
- `SalmonRun.Audit` — JSONL audit, hash chain, redaction, API wrapper.
- `SalmonRun.Config` — config loading, validation, placeholders.
- `SalmonRun.Constants` — environment, port, path, and exit-code constants.
- `SalmonRun.Core` — shared helpers (backoff, native invocation, JSON atomics).
- `SalmonRun.Credentials` — credential resolvers.
- `SalmonRun.Locking` — file and namespace locking.
- `SalmonRun.Mermaid` — Mermaid diagram extraction and chunking.
- `SalmonRun.ModuleLoader` — module discovery and legacy-name fallbacks.
- `SalmonRun.Process` — safe `cmd`/`docker`/`aws` invocation.
- `SalmonRun.WorkflowEvents` — event journal and namespace logs.

### Cross-cutting utility modules

- `SalmonRun.DeployState` — setup checkpoint state.
- `SalmonRun.Diagnostics` — step-by-step diagnostic capture.
- `SalmonRun.Display` — console output helpers.
- `SalmonRun.GitCloud` — git-hosting push/token/CI helpers; resolves tokens and host through `SalmonRun.Credentials`.
- `SalmonRun.Paths` — canonical Salmon Run path resolution.
- `SalmonRun.Ports` — port allocation and registry.

---

## 16. Public package layout

`salmon-run` keeps the source tree clean:

- The repo contains `Modules/`, `Skills/`, `docs/`, `Tests/`, `install.ps1`, `Start-SalmonRun.ps1`, Docker files, and CI workflows.
- All task queues, logs, cache, secrets, and installed modules live under `~/.salmon`.
- The `Tasks/` folder at the repo root is ignored by git and should not be used for real runtime state.

See `docs/PUBLIC_PACKAGE.md` for the full path table.

---

## 17. What is proven vs. what remains

### Working and tested

- Pond definitions, the core engine loop, and plan transitions (Intake → Code → Review → Audit → QA → Complete → Archive) with the `Local` tier in a clean `~/.salmon` home.
- `PublicLocal.ps1` end-to-end smoke runs.
- Model profile resolution and executor command construction for OpenCode Go/Zen, Devin, DeepSeek/DSH (OpenRouter and DeepInfra as inference-provider configurations), and Codex.
- Provider contract tests for OpenCode, Devin, and DeepSeek/DSH; OpenCode Go is the supported external golden path and the others are beta.
- Module loading, config, credentials, audit, locking, agent lifecycle, workflow events, Mermaid chunking, and the Pester suites.
- `install.ps1` and Docker build/dry-run.
- GitHub and Worktree live pushes via `SalmonRun.GitCloud` and `SalmonRun.Credentials` resolvers.
- Manifest-driven public-to-private sync, parity checks, and public leak check.
- GitHub Actions CI: Pester suite + leak check + release archive creation, plus Docker build/push to public GHCR.

### Not yet validated against live systems

- A full `Start-SalmonRun.ps1 -Run` with an external-provider plan has not been exercised end-to-end in a clean environment. The `PublicLocal` smoke-test path is validated; external-provider dispatch is unit- and contract-tested but remains a manual live gate.
- The required representative OpenCode Go lifecycle/failure canaries and four-hour unattended soak have not yet been recorded for the MVP release commit.
- Docker Swarm orchestration has not been deployed live.
- PowerShell Gallery publish has not been performed (the `SalmonRun` nupkg builds locally and `Publish-SalmonRunModule.ps1` is ready).

### Known rough edges

- `PublicLocal.ps1` is a smoke-test harness, not a real agent. Real agentic work requires an external-provider executor with a configured credential.
- Some feature-level readiness scores in `docs/roadmap.md` remain below 100% because long-running stress/integration tests are not yet in CI, even though the main paths are green.

---

## See also

- `docs/PUBLIC_PACKAGE.md` — repo-vs-runtime path layout.
- `docs/MODULES.md` — module catalog.
- `docs/EXTENDING.md` — adding harness adapters, ponds, and skills.
- `docs/implementation.md` — evidence ledger with per-feature readiness scores.
- `docs/roadmap.md` — remaining release blockers and vision.
- `README.md` — quick start, installer, and Docker commands.
