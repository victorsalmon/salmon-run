# salmon-run — Roadmap & Appraisal

> Appraisal date: **2026-08-27**  
> Last verified: **2026-08-27**  
> Evidence scope: the public `salmon-run` package. The canonical source-of-truth remains the private `salmon-orchestrator` implementation; `salmon-run` is the scrubbed, generalized mirror projected via `scripts/Sync-FromCanonical.ps1`.  
> Freshness: Current `main` was inspected and exercised directly on this date. Earlier appraisals in this file are preserved in git history.

## Vision

`salmon-run` is the public, generalized, file-based Kanban control plane for agentic development:

- Queue automation (Intake → Code → Review → Audit → QA → Complete → Archive)
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
| 6. Real provider executors | OpenCode, Devin, OpenRouter, DeepInfra/Codex adapters that resolve credentials and run real CLI commands | **Implemented with PondLog integration; not validated against live provider APIs in this appraisal** |
| 7. Mermaid repo chunking | Split repository documentation/diagrams into model-ingestible chunks | **Done; `SalmonRun.Mermaid` implemented and tested** |
| 8. Observability & operations | Health checks, metrics, crash throttling, Docker/Swarm packaging for the public repo | **Partial; top-level `Start-SalmonRun.ps1`, Dockerfile, compose files, `deploy.ps1`, and CI workflows exist. Health/metrics and crash throttling are exercised only in unit tests.** |
| 9. Leak-clean production pass | Automated scrub of private hostnames, tokens, client paths from canonical projection | **Done; `Invoke-LeakCheck.ps1` reports no private references in scanned files** |

## Feature-level status

| Feature | Production readiness | Notes |
| --- | ---: | --- |
| File-based task queues (`~/.salmon/Tasks/*`) | 90% | Directories and config defined; runtime path logic present and tested. Installer creates `~/.salmon/Tasks` and wires module paths. `Start-SalmonRun.ps1 -DryRun` lists queues correctly. |
| Pond engine (`Start-PondEngine`) | 80% | Core loop, lanes, streams, rescue, capacity, transitions, archive are implemented and tested. Dependency-gating has one known edge (child plan selected but not moved in a specific property test; see `implementation.md`). OpenCode, Devin, OpenRouter, DeepInfra executors implemented for MVP. |
| Model router / execution profiles | 88% | Catalog and harness-defaults exist; profile resolution is tested. `~/.salmon/providers` JSON overlay directory lets users add/override providers, models, and cost data. `~/.salmon/benchmarks` carries an LLM-Bench-Data-compatible `models.json` with official source URLs, pricing, benchmark scores, tokenizer efficiency, speed, and `thinking_token_ratio`. `PondExecutionProfile` carries cost and benchmark fields including `CostWithThinking`. Dry-run confirmed base routing (OpenCode Go) and overlay routing (OpenRouter/DeepInfra) with benchmark and cost. OpenCode Go/Zen, Devin, OpenRouter, DeepInfra adapters build real CLI commands; no live provider execution in this appraisal. |
| Local executor (`PublicLocal.ps1`) | 75% | Works end-to-end for smoke tests, appends evidence markers and PondLog events. Not a real agent. Legacy `Local.ps1` is a stub that delegates to `ExternalPublicSafe.ps1`. |
| Queue quality gates (Lock, Validation, Audit, QA headers) | 80% | Evidence gates in `Get-PondCandidates` and `PublicLocal.ps1`; property/mutation tests exist. Failure path from Code → Review → Audit → QA → Complete is exercised. |
| Dependency gating (`DependsOn`) | 60% | Implementation exists; one Pester property test fails for a child plan depending on a parent in `Complete` (the child is selected but the expected `Complete` file does not appear). |
| Project plan decomposition and child gating | 70% | `Invoke-PondTaskPlanProject` and `children-complete` gate exist and are tested. |
| Agent lifecycle (PID, heartbeat, stale cleanup) | 85% | AgentLifecycle module is implemented and has passing property/unit tests. |
| Credential resolution (`SalmonRun.Credentials`) | 75% | Resolver design and tests pass; wired into `SalmonRun.GitCloud` token and host resolution so `~/.salmon/.env` resolvers (Env/File/AWS/GitHub/Worktree) drive GitHub/Worktree tokens. No live AWS Secrets Manager or GitHub/Worktree API integration verified. |
| Audit logging (`SalmonRun.Audit`) | 80% | Hash-chain, redaction, API-call wrapper, and integrity tests all pass. |
| Configuration / `install.json` handling | 80% | Config module is broad and mostly passes tests. Some property tests produce warnings about missing `install.json` or `DroneMode` defaults. |
| Constants and port/path registries | 85% | Constants, Paths, Ports modules pass tests and match registry files. |
| AQE (Pester runner, doc lint, optional bridge) | 80% | `Invoke-SalmonRunAQE`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunPesterSuite` exist. Doc lint passes on current docs. Bridge is optional. |
| GitCloud push helpers | 70% | GitHub and Worktree token/push abstractions exist and now resolve tokens/hosts through `SalmonRun.Credentials` resolvers. Not exercised against live hosts in this appraisal. |
| Display / Diagnostics / DeployState | 80% | Utility modules present and tested. |
| Documentation lint (`Invoke-DocLint`) | 85% | Working; README/PUBLIC_PACKAGE/MODULES/EXTENDING references are valid. |
| Public installer (`install.ps1`) | 95% | Creates `~/.salmon` dirs, `~/.salmon/providers` and `~/.salmon/benchmarks`, copies `Modules/` to `~/.salmon/Modules`, wires `PSModulePath`, seeds `.env` and `benchmarks/models.json` from `dot-salmon.example/benchmarks`, validates a fresh `Import-Module SalmonRun.PondEngine`, and has dedicated Pester coverage.
| Canonical sync and leak check | 95% | `Sync-FromCanonical.ps1` is parameterized and applies a runtime text scrub. `Invoke-LeakCheck.ps1` scans the whole public package except the checker and sync script themselves, and is covered by positive/negative Pester tests. |
| Mermaid repo chunking | 90% | `SalmonRun.Mermaid` extracts and chunks Mermaid diagrams; tests pass. |
| Docker/Swarm orchestration packaging | 85% | Dockerfile, `docker-compose.yml`, `docker-compose.swarm.yml`, and `deploy.ps1` exist; `docker build` succeeds and `docker run -DryRun` works. Swarm deploy not exercised live. |
| CI / validation | 90% | `.github/workflows/test.yml` and `.github/workflows/docker.yml` exist and look correct. `.worktree/workflows/validate.yml` now uses the valid `github.workspace` expression, and the public package has dedicated installer, dry-run, leak-check, and benchmark Pester tests. |
| Top-level runner (`Start-SalmonRun.ps1`) | 90% | Bootstraps module environment, lists queues in `-DryRun`, writes session event, and can invoke `Start-PondEngine`. `-DryRun` is covered by Pester; a real `-Run` end-to-end with live external providers remains a manual gate. |

## 2026-08-27 Public-package grooming pass

- Removed the entire `Skills/` tree and 16 fleet-only `Tools/Documentation/Scripts/` helpers from the public package.
- Removed the `Dsh.ps1` executor and the `dsh`/`deepseek` harness; DeepSeek models now route through `opencode-go`.
- Fixed public `Invoke-DocLint.ps1` to scan only public docs and accept a `-RepoRoot`.
- Updated `dot-salmon.example/benchmarks`, tests, and all public docs to match the OpenCode Go/DeepSeek routing.
- Re-verified: full Pester suite **548 passed / 0 failed / 3 skipped**, leak check clean, doc lint clean, Docker build and `docker run --rm -DryRun` green.

## Highest-confidence release blockers

1. ~~`.worktree/workflows/validate.yml` uses an invalid variable.~~ **Fixed:** `repository.workspace` was replaced with `github.workspace`.
2. ~~`package.json` repository URL is a placeholder.~~ **Fixed:** URL now points to the public `worktree.ca/clocklobster/salmon-run.git` origin.
3. ~~`model-router-catalog.json` benchmark URL is a placeholder.~~ **Fixed:** benchmark URL now points to the public `LLM-Bench-Data` repository.
4. ~~`DependsOn` gating has a failing property test.~~ **Fixed:** all `Pond dependency gating` tests pass; the failure was environmental (stale PowerShell session and module-cache state).
5. ~~`Invoke-LeakCheck.ps1` skips `package.json` and all `scripts/` files.~~ **Fixed:** the script now scans the whole package except the checker and sync script themselves, and Pester tests verify positive and negative detection.
6. ~~`PondEngine` module-loader and `Get-ChildItem | ForEach-Object` dot-source patterns.~~ **Fixed:** module `.psm1` loaders and the `Clear-StaleAgentFiles` file iteration now use explicit `foreach` loops, and the test harness uses manifest-based imports to avoid duplicate module instances.
7. **External provider executors are unproven against live APIs.** The adapters build real CLI commands but have not been run against real OpenCode, Devin, OpenRouter, or DeepInfra/Codex endpoints.
8. ~~A full `Start-SalmonRun.ps1 -Run` end-to-end smoke run is still needed.~~ **Fixed:** a `Challenge: Local` plan moved through `Code` → `Review` → `Audit` → `QA` → `Complete` with the `PublicLocal` executor in a clean temp `~/.salmon` home.
9. ~~GitCloud/credential resolver integration.~~ **Fixed:** `SalmonRun.GitCloud` token and host helpers now fall back to `SalmonRun.Credentials` resolvers (Env/File/AWS/GitHub/Worktree); covered by Pester integration tests.

## Unknowns / manual gates

- What is the intended public release artifact (PowerShell Gallery module, GitHub release, Docker image, all three)?
- Which provider CLIs should ship as first-class public adapters, and are they available on the target platforms?
- Is the canonical `salmon-orchestrator` repo still the active source of truth? The README says yes, but `salmon-run` has 40+ commits and may have diverged.
- Should `install.ps1` install to `~/.salmon/Modules` (current behavior) or a standard system `PSModulePath` location?
- Has `Start-SalmonRun.ps1 -Run` been exercised with a real plan end-to-end, including archive and rescue?

## Overall readiness

The public `salmon-run` package is approximately **95% production-ready for its stated vision**.

It installs, loads, and runs in a fresh PowerShell session and in a Docker container; the core `Tests` suite passes (548 passed, 0 failed, 3 skipped) with the new installer, dry-run, leak-check, and benchmark coverage; CI workflows now use a valid expression; PondLog I/O is standardized; OpenCode Go/Zen, Devin, OpenRouter, and DeepInfra/Codex can build real CLI commands; the public tree is now free of the internal `Skills/` tree and fleet-only tooling; Mermaid repository chunking is implemented; `Sync-FromCanonical.ps1` is parameterized and leak-clean; `Invoke-LeakCheck.ps1` scans the full public package; `Start-SalmonRun.ps1 -Run` has moved a `Local`-tier plan through the full lifecycle in a clean `~/.salmon` home; `SalmonRun.GitCloud` token and host resolution now falls back to `SalmonRun.Credentials` resolvers; and the public tree contains no private references in the scanned files.

The remaining 5% is **manual/live-provider acceptance**: proving the external adapters against real APIs, confirming a live GitCloud push to GitHub or Worktree with a resolver-redirected token, and deciding the final release artifact format.
