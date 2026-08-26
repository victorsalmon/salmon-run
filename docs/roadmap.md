# salmon-run — Roadmap & Appraisal

> Appraisal date: **2026-08-26**  
> Last verified: **2026-08-26**  
> Evidence scope: `C:\Repos\Public\salmon-run` (public package). Canonical implementation lives in the private `salmon-orchestrator` repo and is projected here via `scripts/Sync-FromCanonical.ps1`.  
> Freshness: Most module code and tests were last committed 2026-08-25/26. The public package is explicitly described by its own README as a **public packaging skeleton** whose full projection is still pending.

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
| 4. Integration test harness | Pester suites plus property/mutation tests for all modules | **Present; 25 failures in full Orchestrator suite** |
| 5. Installable public mirror | `install.ps1` copies modules to `~/.salmon/Modules`, updates `PSModulePath`, and validates load order | **Not done** |
| 6. Real provider executors | OpenCode, Devin, DSH, OpenRouter, DeepInfra adapters that resolve credentials and run real agents | **Stubs only** |
| 7. Mermaid repo chunking | Split repository documentation/diagrams into model-ingestible chunks | **Not implemented** |
| 8. Observability & operations | Health checks, metrics, crash throttling, Docker/Swarm packaging for the public repo | **Partial; no top-level orchestrator entry script** |
| 9. Leak-clean production pass | Automated scrub of private hostnames, tokens, client paths from canonical projection | **Partial; leak-check script exists, sync is copy-only** |

## Feature-level status

| Feature | Production readiness | Notes |
| --- | ---: | --- |
| File-based task queues (`~/.salmon/Tasks/*`) | 85% | Directories and config defined; runtime path logic present and tested. Installer does not create them today (it does, but without module wiring). |
| Pond engine (`Start-PondEngine`) | 60% | Core loop, lanes, streams, rescue, capacity, transitions, archive are implemented and partially tested. Dependency-gating test fails; external executors are stubs. |
| Model router / execution profiles | 60% | Catalog and harness-defaults exist; profile resolution is tested. All non-local executors are public-safe stubs. |
| Local executor (`PublicLocal.ps1`) | 50% | Works end-to-end for smoke tests but only appends evidence markers; does not invoke a real agent. Legacy `Local.ps1` is a stub that delegates to `ExternalPublicSafe.ps1`. |
| Queue quality gates (Lock, Validation, Audit, QA headers) | 65% | Evidence gates in `Get-PondCandidates` and `PublicLocal.ps1`; property tests exist. Failure path from Code → Review → Audit → QA → Complete is exercised. |
| Dependency gating (`DependsOn`) | 40% | Implementation exists; one Pester test fails for a child plan depending on a parent in `Complete`. |
| Project plan decomposition and child gating | 50% | `Invoke-PondTaskPlanProject` and `children-complete` gate exist; tested, but relies on the same dependency/transition mechanics that show failures. |
| Agent lifecycle (PID, heartbeat, stale cleanup) | 75% | AgentLifecycle module is implemented and has passing property/unit tests. |
| Credential resolution (`SalmonRun.Credentials`) | 40% | Resolver design and most tests exist, but the test container fails to load due to module dependency / `break` / `continue` label errors. |
| Audit logging (`SalmonRun.Audit`) | 35% | Hash-chain, redaction, API-call wrapper, integrity tests are written, but the whole module test container fails at `BeforeAll` with a break/continue label error. |
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

1. **Installer does not install.** `install.ps1` stops after creating directories and copying `.env.example`. A new user cannot actually import the modules after running it.
2. **Module load order is fragile.** `Orchestrator/Modules/*.psd1` declare `RequiredModules` on `SalmonRun.Paths`, `SalmonRun.Ports`, `SalmonRun.Diagnostics`, etc., which live under `Skills/Docker/Modules`. Unless `Initialize-InterclawEnvironment` pre-seeds `PSModulePath`, direct `Import-Module` fails. This blocks any out-of-box usage and several test files.
3. **Two whole module test containers crash on load.** `SalmonRun.Audit` and `SalmonRun.Credentials` `BeforeAll` fail with a PowerShell `break`/`continue` label error, preventing regression coverage of security-sensitive code.
4. **Pond dependency gating has a failing test.** A child plan whose `DependsOn` parent is already `Complete` does not reach `Complete` in the expected single iteration.
5. **All external agent executors are stubs.** The package cannot run real agents through OpenCode, Devin, DSH, OpenRouter, or DeepInfra without user-supplied adapters.
6. **Mermaid chunking is missing** despite being part of the README vision.
7. **No top-level orchestrator runner.** There is `Start-PondEngine`, but no `deploy.ps1` or equivalent public entry point that wires the engine to a schedule or service.

## Unknowns / manual gates

- Is the canonical `salmon-orchestrator` repo still the active source of truth? The README says yes, but the public package has 40+ commits and may have diverged.
- What is the intended release cadence and target platform (PowerShell Gallery, GitHub release, Docker image)?
- Which provider CLIs should ship as first-class public adapters?
- Should `install.ps1` install to `~/.salmon/Modules` or a system `PSModulePath` location?

## Overall readiness

The public `salmon-run` package is approximately **40–45% production-ready for its stated vision**. The control-plane architecture is largely designed and the core PondEngine is partially functional, but the package is not installable, not all modules load cleanly, several key tests fail, the real agent harnesses are stubs, and advertised features such as Mermaid chunking and a one-command installer are incomplete.
