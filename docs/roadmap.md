# salmon-run — Roadmap & Appraisal

> Appraisal date: **2026-08-27**  
> Last verified: **2026-08-27**  
> Evidence scope: `C:\Repos\Public\salmon-run` (public package). Canonical implementation lives in the private `salmon-orchestrator` repo and is projected here via `scripts/Sync-FromCanonical.ps1`.  
> Freshness: Wave 1–4 integration completed 2026-08-27. Full `Orchestrator/Tests` (408 passed), `Skills/Docker/Tests` (103 passed), and `Invoke-LeakCheck.ps1` are green.

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
| 1. Public package skeleton | README, AGENTS, config examples, installer stub, sync and leak-check scripts | **Done** |
| 2. Core control-plane modules | AgentLifecycle, AQE, Audit, Config, Constants, Core, Credentials, Locking, ModuleLoader, PondEngine, Process, WorkflowEvents | **Done in source** |
| 3. Cross-cutting utility modules | DeployState, Diagnostics, Display, GitCloud, Paths, Ports | **Done in source** |
| 4. Integration test harness | Pester suites plus property/mutation tests for all modules | **Done; full suite passes** |
| 5. Installable public mirror | `install.ps1` copies modules to `~/.salmon/Modules`, updates `PSModulePath`, and validates load order | **Done** |
| 6. Real provider executors | OpenCode, Devin, DSH, OpenRouter, DeepInfra adapters that resolve credentials and run real agents | **Done for MVP scope** |
| 7. Mermaid repo chunking | Split repository documentation/diagrams into model-ingestible chunks | **Not implemented** |
| 8. Observability & operations | Health checks, metrics, crash throttling, Docker/Swarm packaging for the public repo | **Partial; top-level `Start-SalmonRun.ps1` exists, Docker/Swarm packaging not implemented** |
| 9. Leak-clean production pass | Automated scrub of private hostnames, tokens, client paths from canonical projection | **Done; `Invoke-LeakCheck.ps1` reports no private references** |

## Feature-level status

| Feature | Production readiness | Notes |
| --- | ---: | --- |
| File-based task queues (`~/.salmon/Tasks/*`) | 85% | Directories and config defined; runtime path logic present and tested. Installer creates `~/.salmon/Tasks` and wires module paths. |
| Pond engine (`Start-PondEngine`) | 60% | Core loop, lanes, streams, rescue, capacity, transitions, archive are implemented and partially tested. Dependency-gating passes; OpenCode and DSH executors implemented for MVP. |
| Model router / execution profiles | 60% | Catalog and harness-defaults exist; profile resolution is tested. OpenCode Go/Zen and DSH adapters route real CLI commands; Devin, OpenRouter, and DeepInfra remain deferred. |
| Local executor (`PublicLocal.ps1`) | 50% | Works end-to-end for smoke tests but only appends evidence markers; does not invoke a real agent. Legacy `Local.ps1` is a stub that delegates to `ExternalPublicSafe.ps1`. |
| Queue quality gates (Lock, Validation, Audit, QA headers) | 65% | Evidence gates in `Get-PondCandidates` and `PublicLocal.ps1`; property tests exist. Failure path from Code → Review → Audit → QA → Complete is exercised. |
| Dependency gating (`DependsOn`) | 40% | Implementation exists; one Pester test fails for a child plan depending on a parent in `Complete`. |
| Project plan decomposition and child gating | 50% | `Invoke-PondTaskPlanProject` and `children-complete` gate exist; tested, but relies on the same dependency/transition mechanics that show failures. |
| Agent lifecycle (PID, heartbeat, stale cleanup) | 75% | AgentLifecycle module is implemented and has passing property/unit tests. |
| Credential resolution (`SalmonRun.Credentials`) | 40% | Resolver design and tests pass; module loads cleanly in a fresh session. |
| Audit logging (`SalmonRun.Audit`) | 35% | Hash-chain, redaction, API-call wrapper, and integrity tests all pass. |
| Configuration / `install.json` handling | 70% | Config module is broad and mostly passes tests. Some property tests produce warnings. |
| Constants and port/path registries | 80% | Constants, Paths, Ports modules pass tests and match registry files. |
| AQE (Pester runner, doc lint, optional bridge) | 70% | `Invoke-SalmonRunAQE`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunPesterSuite` exist. Doc lint passes on current docs. Bridge is optional. |
| GitCloud push helpers | 65% | GitHub and Worktree token/push abstractions exist and have tests. Not exercised against live hosts in this appraisal. |
| Display / Diagnostics / DeployState | 70% | Utility modules present and tested. |
| Documentation lint (`Invoke-DocLint`) | 85% | Working; README/PUBLIC_PACKAGE/MODULES/EXTENDING references are valid. |
| Public installer (`install.ps1`) | 30% | Creates `~/.salmon` dirs and seeds `.env`, but does **not** install modules or wire `PSModulePath`. Declares itself an installer stub. |
| Canonical sync and leak check | 50% | `Sync-FromCanonical.ps1` copies source but does not scrub; `Invoke-LeakCheck.ps1` scans for private strings but skips `package.json` and the scripts themselves. |
| Mermaid repo chunking | 0% | Mentioned in README; no implementation found. |
| Docker/Swarm orchestration packaging | 0% | No top-level `deploy.ps1`, `docker-compose.yml`, or Dockerfile in the public package. `SalmonRun.DeployState` is only a module. |

## Highest-confidence release blockers

1. **Mermaid chunking is missing** despite being part of the README vision.
2. **Devin, OpenRouter, and DeepInfra executors remain stubs.** Only OpenCode Go/Zen and DSH are wired for real CLI runs in this MVP pass.
3. **No Docker/Swarm packaging.** There is no public `docker-compose.yml`, `Dockerfile`, or `deploy.ps1` for running the engine as a service.
4. **CI workflow was deferred.** No GitHub/Worktree Actions workflow runs the full test suite on push.

## Unknowns / manual gates

- Is the canonical `salmon-orchestrator` repo still the active source of truth? The README says yes, but the public package has 40+ commits and may have diverged.
- What is the intended release cadence and target platform (PowerShell Gallery, GitHub release, Docker image)?
- Which provider CLIs should ship as first-class public adapters?
- Should `install.ps1` install to `~/.salmon/Modules` or a system `PSModulePath` location?

## Overall readiness

The public `salmon-run` package is approximately **70% production-ready for its stated vision**. The package now installs, loads, and runs in a fresh PowerShell session; the full Orchestrator and Skills/Docker test suites pass; PondLog I/O is standardized; OpenCode Go/Zen and DSH can dispatch real CLI calls; and the public tree is leak-clean. Remaining gaps are Mermaid chunking, Docker/Swarm packaging, and the deferred Devin/OpenRouter/DeepInfra executors.
