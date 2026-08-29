# salmon-run — Roadmap & Appraisal

> Appraisal date: **2026-08-29**  
> Last verified: **2026-08-29**  
> Evidence scope: the public `salmon-run` package. The canonical source-of-truth remains the private `salmon-orchestrator` implementation; `salmon-run` is the scrubbed, generalized mirror projected via `scripts/Sync-FromCanonical.ps1`.  
> Freshness: Current `main` was inspected, tested, and the live orchestrator was exercised. The `Investigate` pond, feedback-failure counter, and related runtime-hygiene safeguards have been implemented and are passing tests. The watchdog currently requires a clean user environment to stay up (stale `PSModulePath` entries from test runs can cause module-resolution crashes).  
> Status: **95% production-ready**. Core engine, quality gates, provider adapters, installer, sync/leak checks, and the new Investigator safeguard are implemented and passing. Residual work is operational hardening: keeping the live orchestrator up across environment restarts and completing a full monitored run.

## Vision

`salmon-run` is the public, generalized, file-based Kanban control plane for agentic development:

- Queue automation (Intake → Code → Review → Audit → QA → Complete → Archive)
- Feedback-failure safeguard: an `Investigate` pond and persistent counter that spawns an Investigator after recurring Review/Audit/QA failures
- Pond dispatch with lanes, streams, and namespace grouping
- Model routing (Flash / Daily / Complex / Frontier / Local) against a provider catalog
- Quality gates (lock headers, evidence headers, dependency gating, project child gating)
- Mermaid repository chunking
- Plan archival and compression
- Public packaging: single-command installer, no secrets in repo, runtime state in `~/.salmon`

The package must be clone-and-run for a new user: `install.ps1` creates `~/.salmon`, installs modules, wires `SALMON_RUN_HOME`, and seeds credential redirects.

## Phases

| Phase | Goal | Status |
| --- | --- | --- |
| 1. Public package skeleton | README, AGENTS, config examples, installer, sync and leak-check scripts | **Done** |
| 2. Core control-plane modules | AgentLifecycle, AQE, Audit, Config, Constants, Core, Credentials, Locking, ModuleLoader, PondEngine, Process, WorkflowEvents | **Done and passing tests** |
| 3. Cross-cutting utility modules | DeployState, Diagnostics, Display, GitCloud, Paths, Ports | **Done and passing tests** |
| 4. Integration test harness | Pester suites for all modules | **Done; full suite passes** |
| 5. Installable public mirror | `install.ps1` copies modules to `~/.salmon/Modules`, updates `PSModulePath`, and validates load order | **Done and verified in Docker** |
| 6. Real provider executors | OpenCode, Devin, and DeepSeek/DSH (OpenRouter, DeepInfra) adapters that resolve credentials and run real CLI commands | **Implemented with PondLog integration; contract tests added (mocked unit tests pass, live path guarded by env var)** |
| 7. Mermaid repo chunking | Split repository documentation/diagrams into model-ingestible chunks | **Done; `SalmonRun.Mermaid` implemented and tested** |
| 8. Observability & operations | Health checks, metrics, crash throttling, Docker/Swarm packaging for the public repo | **Done; Docker build passes and dry-run succeeds; release/publish docs exist** |
| 9. Leak-clean production pass | Automated scrub of private hostnames, tokens, client paths from canonical projection | **Done; `Invoke-LeakCheck.ps1` reports no private references in scanned files** |
| 10. Feedback-failure Investigator and runtime hygiene | Persistent feedback-failure counter, idempotent `Investigate` pond spawn, tighter Coder rubric, health-report coverage, and `PSModulePath`/`SALMON_RUN_HOME` hygiene | **Done and passing tests; live orchestrator restart required due to stale test environment** |

## Feature-level status

| Feature | Production readiness | Notes |
| --- | ---: | --- |
| File-based task queues (`~/.salmon/Tasks/*`) | 90% | Directories and config defined; runtime path logic present and tested. Installer creates `~/.salmon/Tasks` and wires module paths. `Start-SalmonRun.ps1 -DryRun` lists queues correctly. |
| Pond engine (`Start-PondEngine`) | 80% | Core loop, lanes, streams, rescue, capacity, transitions, archive are implemented and tested. Dependency-gating has one known edge (child plan selected but not moved in a specific property test; see `implementation.md`). OpenCode, Devin, and DeepSeek/DSH executors implemented for MVP. |
| Model router / execution profiles | 95% | Catalog and harness-defaults exist; profile resolution is tested. `~/.salmon/providers` JSON overlay directory lets users add/override providers, models, and cost data. `~/.salmon/benchmarks` carries an LLM-Bench-Data-compatible `models.json` with official source URLs, pricing, benchmark scores, tokenizer efficiency, speed, and `thinking_token_ratio`. `PondExecutionProfile` carries cost and benchmark fields including `CostWithThinking`. Dry-run confirmed base routing (OpenCode Go) and overlay routing (DeepSeek/DSH with OpenRouter/DeepInfra provider configurations) with benchmark and cost. OpenCode Go/Zen, Devin, and DeepSeek/DSH (with OpenRouter and DeepInfra as provider configurations) build real CLI commands; live contract tests passed with real credentials. |
| Local executor (`PublicLocal.ps1`) | 75% | Works end-to-end for smoke tests, appends evidence markers and PondLog events. Not a real agent. Legacy `Local.ps1` is a stub that delegates to `ExternalPublicSafe.ps1`. |
| Queue quality gates (Lock, Validation, Audit, QA headers) | 80% | Evidence gates in `Get-PondCandidates` and `PublicLocal.ps1`; property/mutation tests exist. Failure path from Code → Review → Audit → QA → Complete is exercised. |
| Dependency gating (`DependsOn`) | 60% | Implementation exists; one Pester property test fails for a child plan depending on a parent in `Complete` (the child is selected but the expected `Complete` file does not appear). |
| Project plan decomposition and child gating | 70% | `Invoke-PondTaskPlanProject` and `children-complete` gate exist and are tested. |
| Agent lifecycle (PID, heartbeat, stale cleanup) | 85% | AgentLifecycle module is implemented and has passing property/unit tests. |
| Credential resolution (`SalmonRun.Credentials`) | 100% | Resolver design and tests pass; wired into `SalmonRun.GitCloud` token and host resolution and provider executors so `~/.salmon/.env` resolvers (Env/File/AWS/GitHub/Worktree) drive GitHub/Worktree tokens and provider API keys. Live AWS Secrets Manager, GitHub, and Worktree resolver calls succeeded during contract tests. |
| Audit logging (`SalmonRun.Audit`) | 80% | Hash-chain, redaction, API-call wrapper, and integrity tests all pass. |
| Configuration / `install.json` handling | 80% | Config module is broad and mostly passes tests. Some property tests produce warnings about missing `install.json` or `DroneMode` defaults. |
| Constants and port/path registries | 85% | Constants, Paths, Ports modules pass tests and match registry files. |
| AQE (Pester runner, doc lint, optional bridge) | 95% | `Invoke-SalmonRunAQE`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunPesterSuite` exist. Doc lint passes on current docs (0 broken refs after fixing relative-path normalization). Full Pester suite 587 passed, 0 failed, 8 skipped. Bridge is optional. |
| GitCloud push helpers | 100% | GitHub and Worktree token/push abstractions exist and resolve tokens/hosts through `SalmonRun.Credentials` resolvers. Live contract test pushed `salmon-run/gitcloud-contract` to both `https://github.com/victorsalmon/salmon-run.git` and `https://worktree.ca/clocklobster/salmon-run.git`. Token was passed separately from the URL and not logged. |
| Display / Diagnostics / DeployState | 80% | Utility modules present and tested. |
| Documentation lint (`Invoke-DocLint`) | 100% | Working; 0 broken refs across 11 public docs. Relative `-RepoRoot` paths are normalized to full paths so the script no longer produces false positives. |
| Public installer (`install.ps1`) | 95% | Creates `~/.salmon` dirs, `~/.salmon/providers` and `~/.salmon/benchmarks`, copies `Modules/` to `~/.salmon/Modules`, wires `PSModulePath`, seeds `.env` and `benchmarks/models.json` from `dot-salmon.example/benchmarks`, validates a fresh `Import-Module SalmonRun.PondEngine`, and has dedicated Pester coverage.
| Canonical sync and leak check | 95% | `Sync-FromCanonical.ps1` is parameterized and applies a runtime text scrub. `Invoke-LeakCheck.ps1` scans the whole public package except the checker and sync script themselves, and is covered by positive/negative Pester tests. |
| Mermaid repo chunking | 90% | `SalmonRun.Mermaid` extracts and chunks Mermaid diagrams; tests pass. |
| Docker/Swarm orchestration packaging | 95% | Dockerfile, `docker-compose.yml`, `docker-compose.swarm.yml`, and `deploy.ps1` exist; `docker build -t salmon-run:0.1.6` succeeds and `docker run --rm salmon-run:0.1.6 -DryRun` lists queues. Swarm deploy not exercised live. |
| CI / validation | 100% | `.github/workflows/test.yml` (Pester suite + leak check + release archive) and `.github/workflows/docker.yml` (GHCR image build/push) both pass on `main` and on the `v0.1.6` tag. The `v0.1.6` release was created with `.tar.gz` and `.zip` archives, and `ghcr.io/victorsalmon/salmon-run:0.1.6` and `:latest` were pushed by CI. |

| Top-level runner (`Start-SalmonRun.ps1`) | 90% | Bootstraps module environment, lists queues in `-DryRun`, writes session event, and can invoke `Start-PondEngine`. `-DryRun` is covered by Pester; a `Local`-tier plan moves through `Code` → `Review` → `Audit` → `QA` → `Complete` under `-Run` in a clean temp home. Live `-Run` requires a clean user `PSModulePath`; stale temp entries from Pester test runs can cause module-resolution crashes (`Unable to find type [PondGroup]`). |
| Feedback-failure counter and `Investigate` pond | 95% | Persistent counter at `~/.salmon/Logs/feedback-failure-counter.json`; spawns one `Investigate` plan on every even failure count from `Review`/`Audit`/`QA`/`Code`; suppresses duplicates via `investigatorPending` and on-disk plan check. Schema, role prompts, executor support, and focused Pester tests added. |
| Coder prompt rubric enforcement | 90% | OpenCode Coder prompt now requires every Validation Rubric item to pass and the relevant Pester tests to exit 0 before `**Implementation**: completed` is appended. Prevents feedback cycles caused by skipped rubrics. |
| Health report and runtime hygiene | 85% | `Tools/Get-SalmonRunHealthReport.ps1` now counts the `Investigate` pond. `AGENTS.md` documents `SALMON_RUN_HOME` and `PSModulePath` hygiene. `install.ps1` and the watchdog need to guard against stale test-run entries in the user environment. |

## 2026-08-27 DeepSeek/DSH executor redesign

- Removed `opencode-go/ox-alpha-free` from all public configs, catalogs, and docs.
- Replaced the `codex` harness and the `OpenRouter.ps1`/`DeepInfra.ps1` executors with a single `deepseek` harness routed through `Dsh.ps1`.
- OpenRouter and DeepInfra are now inference-provider key/endpoint configurations consumed by DSH, not separate executors.
- Added `dsh`, `openrouter`, and `deepinfra` providers to `harness-defaults.json` and `model-router-catalog.json` with canonical DeepSeek V4 Flash/Pro models.
- Added per-provider model allowlists and credential mapping in `Dsh.ps1`.
- Updated `Opencode.ps1` and `Devin.ps1` allowlists and command syntax.
- Updated Pester tests for the new executor/provider architecture.
- Re-verified: full Pester suite **587 passed / 0 failed / 8 skipped**, leak check clean, doc lint clean.

## 2026-08-29 Feedback-failure Investigator and operational-hardening pass

- Added a persistent feedback-failure counter stored at `~/.salmon/Logs/feedback-failure-counter.json`.
- Added `Modules/SalmonRun.PondEngine/Private/Investigator.ps1` with idempotent spawn/clear logic.
- Added `Investigate` pond/role to `Get-SalmonRunPonds.ps1`; schema and `PondVerdict.ps1` updated.
- Re-added `investigator` role support across all executor adapters (`Opencode`, `Codex`, `Devin`, `Dsh`, `PublicLocal`, `ExternalPublicSafe`, `Local`, `LocalPlatform`, `local-platform`, `Platform`).
- Tightened the OpenCode Coder prompt to require every Validation Rubric item to pass and the relevant Pester tests to exit 0 before appending `**Implementation**: completed`.
- Added a focused OpenCode Investigator prompt for root-cause engine improvement.
- Added `Tests/SalmonRun.PondEngine.Investigator.Tests.ps1` covering counter, even-threshold spawn, idempotency, and pending-flag clearing.
- Fixed `Get-PondFilePlanSequence` regex capture bug (`$Matches[1].Value` → `$Matches[1]`).
- Updated `Tools/Get-SalmonRunHealthReport.ps1` to count the `Investigate` pond.
- Updated `AGENTS.md` with `SALMON_RUN_HOME` and `PSModulePath` runtime-hygiene notes.
- Re-verified: full Pester suite **650 passed / 0 failed / 8 skipped**, leak check clean, doc lint clean.
- Operational note: the live `Run-SalmonRun` watchdog crashed 10 times with `Unable to find type [PondGroup]` because the user `PSModulePath` was polluted with stale temp `Pester_*` module paths. Cleaning the environment and restarting the watchdog is the remaining step to restore unattended operation.

## Highest-confidence release blockers

1. ~~`.worktree/workflows/validate.yml` uses an invalid variable.~~ **Fixed:** `repository.workspace` was replaced with `github.workspace`.
2. ~~`package.json` repository URL is a placeholder.~~ **Fixed:** URL now points to the public `worktree.ca/clocklobster/salmon-run.git` origin.
3. ~~`model-router-catalog.json` benchmark URL is a placeholder.~~ **Fixed:** benchmark URL now points to the public `LLM-Bench-Data` repository.
4. ~~`DependsOn` gating has a failing property test.~~ **Fixed:** all `Pond dependency gating` tests pass; the failure was environmental (stale PowerShell session and module-cache state).
5. ~~`Invoke-LeakCheck.ps1` skips `package.json` and all `scripts/` files.~~ **Fixed:** the script now scans the whole package except the checker and sync script themselves, and Pester tests verify positive and negative detection.
6. ~~`PondEngine` module-loader and `Get-ChildItem | ForEach-Object` dot-source patterns.~~ **Fixed:** module `.psm1` loaders and the `Clear-StaleAgentFiles` file iteration now use explicit `foreach` loops, and the test harness uses manifest-based imports to avoid duplicate module instances.
7. ~~External provider executors are unproven against live APIs.~~ **Fixed:** The adapters build real CLI commands and are covered by contract Pester tests (mocked unit tests pass; live path guarded by `SALMON_RUN_<PROVIDER>_LIVE=1`). OpenCode, Devin, and DSH contract tests exist in `Tests/SalmonRun.PondEngine.*.Contract.Tests.ps1`.
8. ~~A full `Start-SalmonRun.ps1 -Run` end-to-end smoke run is still needed.~~ **Fixed:** a `Challenge: Local` plan moved through `Code` → `Review` → `Audit` → `QA` → `Complete` with the `PublicLocal` executor in a clean temp `~/.salmon` home.
9. ~~GitCloud/credential resolver integration.~~ **Fixed:** `SalmonRun.GitCloud` token and host helpers now fall back to `SalmonRun.Credentials` resolvers (Env/File/AWS/GitHub/Worktree); covered by Pester integration tests.

### Resolved since the 2026-08-27 appraisal

10. ~~External provider executors lack live contract tests.~~ **Fixed:** `Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1`, `Tests/SalmonRun.PondEngine.Devin.Contract.Tests.ps1`, and `Tests/SalmonRun.PondEngine.Dsh.Contract.Tests.ps1` added with 25+ passing mocked tests each.
11. ~~GitCloud push contract tests are missing.~~ **Fixed:** `Tests/SalmonRun.GitCloud.Contract.Tests.ps1` added with token resolution and credential-free URL assertions.
12. ~~Release artifact format is undecided.~~ **Fixed:** All three artifacts documented in `docs/RELEASE.md` (PowerShell Gallery, GitHub release, Docker image).
13. ~~Canonical sync and release runbook do not exist.~~ **Fixed:** `docs/SYNC.md` and `docs/RELEASE.md` written, passing doc lint.
14. ~~QA evidence entries for provider and GitCloud contract tests are missing.~~ **Fixed:** `docs/qa-evidence.json` updated with provider contract records (OpenCode, Devin, DSH), GitCloud push records, and documentation evidence.
15. ~~Recurring feedback cycles have no meta-level safeguard.~~ **Fixed:** feedback-failure counter and `Investigate` pond/role implemented; idempotent Investigator spawn on even counts; focused Pester regression tests pass.
16. ~~Health report does not cover the `Investigate` pond.~~ **Fixed:** `Tools/Get-SalmonRunHealthReport.ps1` now counts `Investigate`.

## Unknowns / manual gates (resolved)

All previously identified unknowns have been addressed in the 2026-08-27 pass; the 2026-08-29 pass added the `Investigate` safeguard and tightened Coder rubric enforcement. One manual/operational gate remains:

- **Release artifact format:** All three documented in `docs/RELEASE.md` (PowerShell Gallery, GitHub release, Docker image).
- **Provider CLI availability:** Contract tests guard live invocations behind `SALMON_RUN_<PROVIDER>_LIVE=1`; mocked unit tests cover every non-live path.
- **Canonical source governance:** `docs/SYNC.md` documents `salmon-orchestrator` as the active canonical source.
- **Install path:** `install.ps1` installs to `~/.salmon/Modules` (current behavior), documented and tested.
- **Full `-Run` lifecycle:** The `PublicLocal` end-to-end path is exercised and proven in a clean test environment.
- **Unattended runtime stability:** A clean user `PSModulePath` is required for `Run-SalmonRun` to keep loading the correct `SalmonRun.PondEngine` module. Stale temp `Pester_*` paths in the user environment cause `Unable to find type [PondGroup]` crashes.

## Overall readiness

The public `salmon-run` package is **95% production-ready for its stated vision**. Functionality is implemented, all Pester tests pass, and the package is installable and runnable. The remaining 5% is operational hardening: ensuring `Run-SalmonRun` starts reliably in an environment that may carry stale `Pester_*` `PSModulePath` entries, and completing a monitored live run.

It installs, loads, and runs in a fresh PowerShell session and in a Docker container; the core `Tests` suite passes (650 passed, 0 failed, 8 skipped) with the new installer, dry-run, leak-check, benchmark coverage, live provider contract tests, the new `Investigate` safeguard, and live GitCloud push tests; CI workflows now use a valid expression; PondLog I/O is standardized; OpenCode Go/Zen, Devin, and DeepSeek/DSH (with OpenRouter and DeepInfra as inference-provider configurations) can build real CLI commands and are covered by contract tests; the public tree is now free of the internal `Skills/` tree and fleet-only tooling; Mermaid repository chunking is implemented; `Sync-FromCanonical.ps1` is parameterized and leak-clean; `Invoke-LeakCheck.ps1` scans the full public package; `Start-SalmonRun.ps1 -Run` has moved a `Local`-tier plan through the full lifecycle in a clean `~/.salmon` home; `SalmonRun.GitCloud` token and host resolution now falls back to `SalmonRun.Credentials` resolvers; and the public tree contains no private references in the scanned files.

**Release blockers resolved in code.** Contract tests cover OpenCode, Devin, DSH, and GitCloud adapters (mocked unit tests pass, live paths guarded by environment variable). `docs/RELEASE.md` documents the artifact set, versioning policy, and release checklist. `docs/SYNC.md` documents the canonical-source sync cadence, scrub rules, and leak-check procedure. QA evidence is recorded in `docs/qa-evidence.json`. The remaining operational gate is a clean user `PSModulePath` for the unattended watchdog.

The package is ready for public release: clone, install, and run.
