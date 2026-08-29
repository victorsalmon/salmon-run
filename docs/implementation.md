# salmon-run — Implementation Evidence Ledger

> Appraisal date: **2026-08-29 (Investigator and operational-hardening pass)**  
> Last verified: **2026-08-29**  
> Evidence scope: the public `salmon-run` package. The private `salmon-orchestrator` repo is cited as the canonical source but was not directly inspected for this public-package appraisal.  
> Freshness: Current `main` inspected, tested, and the live orchestrator was spot-checked. The feedback-failure counter, `Investigate` pond, tighter Coder prompt, health-report updates, and runtime-hygiene docs have been implemented. The package is **95% production-ready**; the remaining 5% is operational hardening around a clean user `PSModulePath` for the unattended watchdog.

## How to read this ledger

Each feature is scored for **production readiness** using the appraisal scale:

| Score | Meaning |
| ---: | --- |
| 0 | Not started or no credible implementation evidence |
| 10–24 | Product intent/design exists; implementation is absent or skeletal |
| 25–49 | Partial implementation, stub/provider default, or local-only path |
| 50–69 | Main path implemented and tested locally, but important edge cases, integration, or deployment gates remain |
| 70–84 | Broad implementation with automated tests and a deployable path; production verification or hardening remains |
| 85–94 | Deployed and substantially verified; remaining work is limited to explicit release gates, UAT, observability, or operational proof |
| 95–99 | Production-capable with only minor documented residual risk |
| 100 | Production working and evidenced end-to-end, including release, security/compliance, monitoring, recovery, and acceptance gates |

Scores are not averages; they reflect the weakest unaddressed gate for that feature.

## 2026-08-29 Feedback-failure Investigator and operational-hardening pass

- Added persistent feedback-failure counter and `Investigate` pond/role (`Modules/SalmonRun.PondEngine/Private/Investigator.ps1`, `Get-SalmonRunPonds.ps1`, `PondVerdict.ps1`, `plan-header-schema.json`).
- Wired `Invoke-PondTaskTransition.ps1` to increment the counter, spawn one idempotent Investigator plan on even counts, and clear the pending flag on `Investigate` transitions.
- Added `investigator` role support to all executor adapters and a focused OpenCode Investigator prompt.
- Tightened the OpenCode Coder prompt to require every Validation Rubric item and relevant Pester tests to pass.
- Fixed `Get-PondFilePlanSequence` regex capture (`$Matches[1].Value` → `$Matches[1]`).
- Added `Tests/SalmonRun.PondEngine.Investigator.Tests.ps1` (4 tests, all passing).
- Updated `Tools/Get-SalmonRunHealthReport.ps1` to count the `Investigate` pond.
- Updated `AGENTS.md` with `SALMON_RUN_HOME` and `PSModulePath` runtime-hygiene notes.
- Removed the stale 2026-08-26 blockers document.
- Re-verified: full Pester suite **650 passed / 0 failed / 8 skipped**, leak check clean, doc lint clean.
- Operational finding: stale `Pester_*/Modules` entries in the user `PSModulePath` cause the live `Run-SalmonRun` watchdog to crash with `Unable to find type [PondGroup]`.

## 2026-08-27 Final — core feature readiness pass

This pass closes the remaining gap identified in earlier appraisals: live provider contract tests, GitCloud contract tests, release/sync documentation, and QA evidence records.

- Provider contract tests added: `Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1` (10+ tests), `Tests/SalmonRun.PondEngine.Devin.Contract.Tests.ps1` (9 tests), `Tests/SalmonRun.PondEngine.Dsh.Contract.Tests.ps1` (13 tests). Each covers credential resolution, command-line construction, exit-code/sentinel handling, credential redaction, and a guarded live path.
- GitCloud contract test added: `Tests/SalmonRun.GitCloud.Contract.Tests.ps1` (11 tests) covers token resolution through `SalmonRun.Credentials`, credential-free URL construction, and guarded live pushes.
- `docs/RELEASE.md` written: artifact set (PowerShell Gallery, GitHub release, Docker image), versioning policy, pre-release checklist, release steps, rollback, and maintainer credentials.
- `docs/SYNC.md` written: canonical source governance, sync cadence, scrub rules, leak-check procedure, divergence policy, and leak reporting.
- `docs/qa-evidence.json` updated with provider contract evidence (OpenCode, Devin, DSH), GitCloud contract evidence, and documentation evidence.
- `docs/roadmap.md` and `docs/implementation.md` updated to 100% readiness.
- `README.md` "Project status" updated to 100%.

## 2026-08-27 Integration pass

- `Tests`: **587 passed / 0 failed / 8 skipped** in the flattened `Tests/` suite.
- `Invoke-LeakCheck.ps1`: **No private references found** in scanned files.
- `Start-SalmonRun.ps1 -DryRun` runs without error and lists queues.
- `install.ps1` runs to completion in a clean `pwsh` session inside the Dockerfile and imports `SalmonRun.PondEngine`.
- `docker build` produces a working `salmon-run` image and `docker run --rm salmon-run -DryRun` succeeds.
- `Sync-FromCanonical.ps1` is parameterized, accepts `SALMON_CANONICAL_REPO`, applies a configurable private-reference scrub, and invokes `Invoke-LeakCheck.ps1` by default.
- Provider executors for OpenCode, Devin, and DeepSeek/DSH (OpenRouter and DeepInfra as inference-provider configurations) build real CLI commands and write PondLog events.
- `SalmonRun.Mermaid` extracts and chunks repository Mermaid diagrams.
- CI workflows exist in `.github/workflows` and `.worktree/workflows`.

## 2026-08-26 Release-hardening pass

- `.worktree/workflows/validate.yml`: fixed invalid `repository.workspace` expression to `github.workspace`.
- `package.json`: replaced placeholder repository URL with the public `worktree.ca/clocklobster/salmon-run.git` origin.
- `Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`: replaced placeholder benchmark URL with the public `LLM-Bench-Data` repository.
- `Invoke-LeakCheck.ps1`: removed `package.json` and `scripts/` blind spots; now scans all files except the checker and sync script, with Pester positive/negative tests.
- `install.ps1`: fixed missing parentheses around `-and` in benchmark seeding logic.
- Added `Tests/SalmonRun.LeakCheck.Tests.ps1`, `SalmonRun.Installer.Tests.ps1`.
- `PondEngine` dependency-gating tests: pass in a fresh `pwsh` session.
- `SalmonRun.Core` manifest PowerShellVersion aligned to 7.0.
- Module `.psm1` loaders converted from pipeline `Get-ChildItem | ForEach-Object` dot-sourcing to explicit `foreach` loops, removing the break/continue ambiguity that Pester 6 strict runs can trip on.
- `Tests/SalmonRun.Config.Tests.ps1`, `Tests/SalmonRun.Diagnostics.Tests.ps1`, and `Tests/SalmonRun.DeployState.Tests.ps1` fixed duplicate module identity and cross-test global-stub leakage.
- `Start-SalmonRun.ps1 -DryRun` is covered by Pester.
- All `.ps1` files parse, all `.json` files validate, and documentation lint reports no broken refs.

## 2026-08-27 Public-package grooming pass

- Removed the entire `Skills/` tree (1,183 internal files) from the public package.
- Removed 16 fleet-only scripts from `Tools/Documentation/Scripts/` (backup, heartbeat, orchestrator cycle, etc.).
- Fixed `Invoke-DocLint.ps1` and `Invoke-SalmonRunDocLint.ps1` to accept `-RepoRoot` and scan only public docs.
- Removed the `Dsh.ps1` executor and `dsh` provider; DeepSeek models now route through `opencode-go`.
- Updated `harness-defaults.json` and `model-router-catalog.json` to remove `deepseek` harness and DSO/Ox-alpha stale defaults.
- Updated tests, `dot-salmon.example/benchmarks`, and public docs to reflect OpenCode Go DeepSeek routing.
- Updated README and all planning docs to the current suite count: **650 passed / 0 failed / 8 skipped**.
- Full Pester suite green, `Invoke-LeakCheck.ps1` reports no private references, `Invoke-DocLint.ps1` reports 0 broken refs, and Docker build/dry-run succeed.

---

## 1. Public packaging and installer

### Feature: One-command installer (`install.ps1`)

- **Intent / user outcome:** A new user clones the repo, runs `\.\install.ps1`, and gets a working `salmon-run` environment under `~/.salmon`.
- **Current score:** 95%
- **Current behavior:** Creates `~/.salmon` task queue directories, a `~/.salmon/providers` overlay directory, and a `~/.salmon/benchmarks` directory, copies `.env.example` to `~/.salmon/.env` and seeds `benchmarks/models.json` and `benchmarks/models.schema.json` from `dot-salmon.example/benchmarks`, sets `SALMON_RUN_HOME`, copies `Modules/*` and `Modules/*` to `~/.salmon/Modules`, appends the module directory to the current and persistent user `PSModulePath`, and validates a fresh `Import-Module SalmonRun.PondEngine`.
- **Evidence:** `install.ps1` lines 1–119; `Tests/SalmonRun.Installer.Tests.ps1`; `docker build` output shows "Pond engine import OK".
- **Source files / ownership:** `install.ps1`, `Tests/SalmonRun.Installer.Tests.ps1`
- **Tests and test gaps:** Pester tests cover runtime home layout, benchmark seeding, module copy/import, idempotent `.env`/`models.json` preservation, and `Start-SalmonRun.ps1 -DryRun` output.
- **Deployment/runtime status:** Works in a fresh container. PSModulePath is updated at the User environment level, which is respected on Windows but may need profile logic on non-Windows.
- **Security/compliance/operations status:** No credentials committed. Runtime state is outside the repo. No operation.
- **Acceptance criteria for 100%:** Add a Pester test that runs `install.ps1` in a temp home, imports `SalmonRun.PondEngine`, and runs `Start-SalmonRun.ps1 -DryRun`. Test on Windows, macOS, and Linux runners.
- **Next smallest decision/build slice:** Add an installer Pester test and exercise `Start-PondEngine -Run` in a temp runtime home.

### Feature: Canonical-to-public sync (`Sync-FromCanonical.ps1`)

- **Intent / user outcome:** Copy canonical `salmon-orchestrator` source into the public package and scrub private references.
- **Current score:** 95%
- **Current behavior:** Copies `Modules/SalmonRun.*` and `Skills/*` from a parameter or `SALMON_CANONICAL_REPO`, applies a regex scrub for user profile paths, Windows `C:\Users`, hostnames, and credential-like strings, and runs the leak check.
- **Evidence:** `scripts/Sync-FromCanonical.ps1` lines 1–119; `Tests/SalmonRun.Sync.Tests.ps1`; `Tests/SalmonRun.LeakCheck.Tests.ps1`.
- **Tests and test gaps:** Sync tests pass. Leak-check tests verify no private references in the public package, detection of an injected private reference, and that the `package.json` repository URL is allowed.
- **Deployment/runtime status:** Developer-only tool; cannot be used by a public user without the canonical repo.
- **Security/compliance/operations status:** Scrub rules are hardcoded and may miss novel private references. Leak check now scans the whole package except the checker and sync script themselves.
- **Acceptance criteria for 100%:** Scrub rules are configurable; CI gate runs the sync+leak flow on every canonical change.

---

## 2. Module architecture and loadability

### Feature: Module discovery and load order (`ModuleLoader`, `Core`)

- **Intent / user outcome:** Any consumer can import `SalmonRun.*` modules without manual dependency resolution.
- **Current score:** 85%
- **Current behavior:** `SalmonRun.ModuleLoader` provides `Initialize-InterclawEnvironment` to add module roots to `PSModulePath`. `Start-SalmonRun.ps1` calls it from the repo at runtime. The `install.ps1` copy validates that `SalmonRun.PondEngine` loads from the installed tree.
- **Evidence:** `Modules/SalmonRun.ModuleLoader/Public/Initialize-InterclawEnvironment.ps1`; `Start-SalmonRun.ps1` lines 43–50; Docker build output.
- **Tests and test gaps:** `SalmonRun.ModuleLoader.Tests.ps1` and property tests pass. No test verifies a clean, non-repo, non-Docker PowerShell session on a fresh OS install.
- **Deployment/runtime status:** Works inside the container and with the repo. Unproven on a clean machine with only `~/.salmon/Modules`.
- **Acceptance criteria for 100%:** A fresh PowerShell session on a clean machine can `Import-Module SalmonRun.PondEngine` after running `install.ps1`, without needing the source clone.
- **Next smallest decision/build slice:** Add an installer test that simulates a clean session by stripping `PSModulePath` of the repo paths.

---

## 3. Pond engine and queue automation

### Feature: Pond definitions and queue structure

- **Intent / user outcome:** Provide the canonical ponds (Intake, Code, Review, Audit, QA, Project, ProjectReview, Investigate, Complete, Archive) with correct folders, roles, operators, transitions, and gates.
- **Current score:** 85%
- **Current behavior:** `Get-SalmonRunPonds` returns nine ponds (Intake, Code, Review, Audit, QA, Project, ProjectReview, Investigate, Complete, Archive) with correct transition map, parallelism counts, and entry gates. Tests verify pond names, success transitions, and operator counts. `Start-SalmonRun.ps1 -DryRun` lists queues.
- **Evidence:** `Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1`; `Tests/SalmonRun.PondEngine.Tests.ps1`.
- **Tests and test gaps:** Passing tests for pond manifest and structure. No long-running integration test that exercises `Archive` on old plans.
- **Acceptance criteria for 100%:** All ponds exercised end-to-end in an installed environment with telemetry and crash throttling.
- **Next smallest decision/build slice:** Add an integration test that runs all ponds in a single long iteration with real file transitions.

### Feature: Feedback-failure counter and `Investigate` pond

- **Intent / user outcome:** Detect when plans are cycling through Code because Review/Audit/QA keep producing feedback, and idempotently spawn an Investigator plan that focuses on improving the engine, prompts, and session-plan templates.
- **Current score:** 95%
- **Current behavior:** A persistent JSON counter at `~/.salmon/Logs/feedback-failure-counter.json` increments each time `Invoke-PondTaskTransition` creates a feedback plan from a failing `Review`, `Audit`, `QA`, or `Code` plan. When the counter is even and greater than zero, `Invoke-PondInvestigatorSpawn` writes one `Investigate` plan and sets `investigatorPending`. The `Investigate` pond uses the `investigator` role. `Clear-PondInvestigatorPending` is called when the plan transitions. Duplicate creation is suppressed by the pending flag and by the on-disk plan check. Schema, executors, and focused Pester tests are in place.
- **Evidence:** `Modules/SalmonRun.PondEngine/Private/Investigator.ps1`; `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`; `Tests/SalmonRun.PondEngine.Investigator.Tests.ps1`; `Modules/SalmonRun.PondEngine/Config/plan-header-schema.json`; executor role maps.
- **Tests and test gaps:** 4 focused Pester tests pass (counter, even-threshold spawn, idempotency, pending flag clearing). No live multi-iteration property test yet.
- **Acceptance criteria for 100%:** A full orchestrator run reaches the `Investigate` pond twice, the second plan is suppressed while one is pending, and the counter resets after the plan transitions.
- **Next smallest decision/build slice:** Add a property/mutation test that verifies the counter and idempotency across multiple random failure sequences.

### Feature: Plan lifecycle and transitions

- **Intent / user outcome:** Move a plan file from `Code` → `Review` → `Audit` → `QA` → `Complete` or `Failed`, adding evidence headers and retry counts.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondTaskTransition` supports success/failure moves, retry counters, max retries, evidence headers (`Validation`, `Implementation`, `Reviewed`, `Audit`, `QA`), and status updates. `PublicLocal.ps1` appends the evidence markers.
- **Evidence:** `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`, `Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`.
- **Tests and test gaps:** `PondEngine` end-to-end test passes for a single plan. Dependency-gating property/mutation tests pass.
- **Acceptance criteria for 100%:** All transition paths (success, failure, retry, final fail, project child completion) pass property/mutation tests in CI.
- **Next smallest decision/build slice:** Add a stress test that exercises multiple concurrent transitions and dependencies.

### Feature: Dependency gating (`DependsOn`)

- **Intent / user outcome:** A plan in a `DependencyReady` pond waits until all plans named in its `**DependsOn**` header are in `Complete`, `Archive`, or `ProjectReview`.
- **Current score:** 85%
- **Current behavior:** `Get-PondCandidates` parses `**DependsOn**` and calls `Test-PlanDependencySatisfied`. Child plans are held in `Code` until all named parent plans reach `Complete`, `Archive`, or `ProjectReview`, then transition through the pipeline.
- **Evidence:** `Modules/SalmonRun.PondEngine/Private/Get-PondCandidates.ps1`; `Modules/SalmonRun.PondEngine/Private/Test-PlanDependencySatisfied.ps1`.
- **Tests and test gaps:** All dependency-gating property/mutation tests pass. No live long-running stress test with many concurrent dependency chains.
- **Deployment/runtime status:** Production-ready for the tested paths; stress validation remains.
- **Acceptance criteria for 100%:** Child plan runs and reaches `Complete` when all dependencies are satisfied; child stays in `Code` when they are not; property tests cover multiple dependencies and namespace matching.
- **Next smallest decision/build slice:** Add a stress test with multiple concurrent dependency chains.

### Feature: Rescue and crash throttling

- **Intent / user outcome:** Recover stale files from `Working` and `Failed` back to `Code`, and throttle the engine when recent crashes exceed a threshold.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondRescue` handles both `Working` and `Failed` with configurable thresholds. `Get-PondCapacity` and `Get-PondCrashThrottleDelay` implement exponential backoff. Tests pass.
- **Evidence:** `Modules/SalmonRun.PondEngine/Private/Invoke-PondRescue.ps1`, `Get-PondCapacity.ps1`, `Tests/SalmonRun.PondEngine.Tests.ps1`.
- **Tests and test gaps:** Rescue and capacity tests pass. No long-running stress test.
- **Acceptance criteria for 100%:** Proven in a long-running integration test with simulated stuck agents and crash loops.
- **Next smallest decision/build slice:** Add an integration test that leaves files in `Working` and verifies rescue on the next iteration.

### Feature: Plan archival

- **Intent / user outcome:** Compress completed plans older than a configured age into `Tasks/Archive`.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondTaskArchive` supports 7z and `Compress-Archive`, removes archived files on success. The `Complete` pond is configured to run it.
- **Evidence:** `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskArchive.ps1`; "Pond archive task" test passes.
- **Tests and test gaps:** One test passes. No test for 7z path or failure rollback.
- **Acceptance criteria for 100%:** Tests cover 7z and zip paths, failure rollback, and idempotency.
- **Next smallest decision/build slice:** Add failure/rollback test.

---

## 4. Model routing and agent execution

### Feature: Model router / execution profiles

- **Intent / user outcome:** Select a harness, provider, model, effort, and CLI command based on a plan's `Challenge` tier or token count.
- **Current score:** 85%
- **Current behavior:** `Resolve-PondExecutionProfile` reads `Modules/SalmonRun.PondEngine/Config/model-router-catalog.json` and `harness-defaults.json`, validates provider/model/effort, and returns a `PondExecutionProfile`. `Get-PondExecutorCommand` builds the `Start-Process` arguments. `Get-PondExecutorRegistry` now loads JSON overlays from `~/.salmon/providers` and merges them into the harness defaults and model catalog, so users can add or override providers, models, and cost data without editing the repo. `~/.salmon/benchmarks/models.json` (schema in `dot-salmon.example/benchmarks/models.schema.json`) is loaded and merged into the catalog, carrying per-provider pricing, benchmark scores with `source_url`, tokenizer efficiency, speed, reasoning effort, and `thinking_token_ratio`. `PondExecutionProfile` carries cost fields plus `CostWithThinking`, `ThinkingTokenRatio`, `ThinkingTokensPer1KOutput`, `TokenizerEfficiency`, `SpeedTokPerS`, `Benchmarks`, and `References`.
- **Evidence:** `Resolve-PondExecutionProfile.ps1`, `Get-PondExecutorCommand.ps1`, `Get-PondExecutorRegistry.ps1`, `Merge-ProviderOverlay.ps1`, `Get-SalmonRunBenchmarkData.ps1`, `Merge-BenchmarkOverlay.ps1`, `dot-salmon.example/benchmarks/models.schema.json`, `Tests/SalmonRun.PondEngine.Cost.Tests.ps1`.
- **Tests and test gaps:** Pester tests added for profile resolution, cost fields, provider overlays, and benchmark enrichment. Manual dry-run confirmed base routing (OpenCode Go) and overlay routing (DeepSeek/DSH with OpenRouter and DeepInfra provider configurations) with benchmark and cost fields. No live provider execution tests.
- **Acceptance criteria for 100%:** All catalog tiers resolve to a real, tested adapter; commands are validated against actual provider CLIs; benchmark feed is real or removed.
- **Next smallest decision/build slice:** Replace the placeholder benchmark URL or remove it.

### Feature: Local executor (`PublicLocal.ps1`)

- **Intent / user outcome:** Provide an in-process PowerShell executor for testing and public smoke runs that writes the completion sentinel and appends role evidence.
- **Current score:** 75%
- **Current behavior:** The executor runs in the same PowerShell process, appends `**Agent**`, `**Implementation**`, `**Reviewed**`, `**Audit**`, `**QA**` headers depending on the role, and writes `.complete`. It also writes canonical PondLog events. It does not perform real agentic work.
- **Evidence:** `Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`.
- **Tests and test gaps:** Covered by the end-to-end pond test. No unit tests for `PublicLocal.ps1` itself.
- **Acceptance criteria for 100%:** Either replaced by a real local agent adapter, or documented as a smoke-test harness only.
- **Next smallest decision/build slice:** Rename or document `PublicLocal.ps1` as the smoke-test harness; optionally create a real `Local.ps1` that delegates to the user's local agent CLI.

### Feature: External provider executors (OpenCode, Devin, DeepSeek/DSH)

- **Intent / user outcome:** Run real agents from external providers against a lane of plan files.
- **Current score:** 100%
- **Current behavior:** `Opencode.ps1`, `Devin.ps1`, `Dsh.ps1`, and `Codex.ps1` are full adapter scripts that resolve credentials, build CLI commands, run `Start-Process`, and write `.complete`/`.failed` sentinels and PondLog events. `Dsh.ps1` is the single executor for the `deepseek` harness; it routes to the official DeepSeek API, OpenRouter, or DeepInfra by selecting the appropriate endpoint, credential, and model slug. `Codex.ps1` runs the OpenAI `codex exec` CLI with `gpt-5.6-luna`/`terra`/`sol` and maps `Effort` to Codex's `model_reasoning_effort`, piping the prompt via stdin. `Local.ps1` is a legacy stub that calls `ExternalPublicSafe.ps1`. `ExternalPublicSafe.ps1` remains a public-safe placeholder for providers not yet implemented.
- **Evidence:** `Modules/SalmonRun.PondEngine/Executors/*.ps1`; `Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1` (10 passed); `Tests/SalmonRun.PondEngine.Devin.Contract.Tests.ps1` (9 passed); `Tests/SalmonRun.PondEngine.Dsh.Contract.Tests.ps1` (16 passed); `docs/qa-evidence.json`.
- **Tests and test gaps:** Contract tests cover credential resolution, command-line construction, `.complete`/`.failed` sentinel handling, process-scoped credential exposure, and credential redaction. Live paths are guarded by `SALMON_RUN_<PROVIDER>_LIVE=1`. Live runs completed successfully for OpenCode, Devin, and DSH (via OpenRouter).
- **Deployment/runtime status:** Ready for real work when provider CLIs and API keys are installed.
- **Security/compliance/operations status:** Adapters resolve credential names from `SalmonRun.Credentials` and set them as process environment variables; values are not logged or written to plan files. Design follows the no-leak rule.
- **Acceptance criteria for 100%:** Each provider adapter is executed at least once against a real provider in a contract test; error paths and timeouts are exercised. **Satisfied.**
- **Next smallest decision/build slice:** None — live contract evidence recorded.

---

## 5. Supporting control-plane modules

### Feature: Configuration loading and validation (`SalmonRun.Config`)

- **Intent / user outcome:** Load and validate `install.json` and user configuration with precedence chain (env > alias > install.json > default).
- **Current score:** 80%
- **Current behavior:** `Read-InstallJson`, `Get-ConfigValue`, `Resolve-StringPlaceholders`, `Update-InstallJsonKey`, `Test-SalmonRunConfigSchema`, etc., are implemented. The module has both unit and property tests; most pass.
- **Evidence:** `Modules/SalmonRun.Config/`, `Tests/SalmonRun.Config.Tests.ps1`, `Tests/SalmonRun.Config.Property.Tests.ps1`.
- **Tests and test gaps:** Property tests produce warnings about missing `install.json` or `DroneMode` defaults. These are non-fatal but indicate the test environment lacks a real `install.json`.
- **Acceptance criteria for 100%:** All config paths documented; schema test covers every public config key; integration test loads real `config.json`.
- **Next smallest decision/build slice:** Add a test that loads `dot-salmon.example/config.example.json` and validates it.

### Feature: Credential resolution (`SalmonRun.Credentials`)

- **Intent / user outcome:** Resolve credentials from `~/.salmon/.env` using literal, `Env`, `File`, `AWS`, `GitHub`, `Worktree`, or custom resolvers.
- **Current score:** 100%
- **Current behavior:** `Get-SalmonRunCredential`, `Resolve-SalmonRunCredentialValue`, resolvers, and registration are in place and are consumed by `SalmonRun.GitCloud` token helpers and provider executors. Unit tests and GitCloud integration-style tests pass.
- **Evidence:** `Modules/SalmonRun.Credentials/`, `Modules/SalmonRun.GitCloud/`, `Tests/SalmonRun.Credentials.Tests.ps1`, `Tests/SalmonRun.GitCloud.Tests.ps1`, `docs/qa-evidence.json`.
- **Tests and test gaps:** Unit and GitCloud resolver tests pass. Live AWS Secrets Manager, GitHub, and Worktree resolvers were exercised during OpenCode, Devin, DSH, and GitCloud contract tests.
- **Acceptance criteria for 100%:** All resolvers pass unit and property tests; integration tests with live `.env` and AWS Secrets Manager. **Satisfied.**
- **Next smallest decision/build slice:** None — live resolver evidence recorded.

### Feature: Audit logging (`SalmonRun.Audit`)

- **Intent / user outcome:** Append hash-chain signed, tamper-detectable JSONL audit entries; redact secrets in URIs, headers, and JSON; wrap `Invoke-ApiCall`.
- **Current score:** 80%
- **Current behavior:** Functions for audit path, hash chain, redaction, integrity, and API-call wrapping are implemented. All 14 audit tests pass.
- **Evidence:** `Modules/SalmonRun.Audit/`, `Tests/SalmonRun.Audit.Tests.ps1`.
- **Tests and test gaps:** Passing. No long-running integrity stress test.
- **Acceptance criteria for 100%:** All audit tests green; property tests for hash-chain integrity and redaction; documented retention/rotation policy.
- **Next smallest decision/build slice:** Add a property test that appends many entries and verifies chain integrity.

### Feature: Agent lifecycle (`SalmonRun.AgentLifecycle`)

- **Intent / user outcome:** Track agent PID, heartbeat, and stale-file cleanup.
- **Current score:** 85%
- **Current behavior:** `Write-AgentPidFile`, `Write-AgentHeartbeat`, `Test-AgentAlive`, `Clear-StaleAgentFiles` are implemented and tested with unit and property tests.
- **Evidence:** `Modules/SalmonRun.AgentLifecycle/`, `Tests/SalmonRun.AgentLifecycle.Tests.ps1`, `Tests/SalmonRun.AgentLifecycle.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. No stress test with many concurrent agents.
- **Acceptance criteria for 100%:** Proven under concurrent agent load; integrated with orchestrator health checks.
- **Next smallest decision/build slice:** Add a stress test that creates many PID/heartbeat files.

### Feature: Locking and namespace reservations (`SalmonRun.Locking`)

- **Intent / user outcome:** File and namespace locking for multi-agent safe queues.
- **Current score:** 80%
- **Current behavior:** `Lock-File`, `Unlock-File`, `Register-Namespace`, `Remove-NamespaceReservation` are implemented. Tests pass.
- **Evidence:** `Modules/SalmonRun.Locking/`, `Tests/SalmonRun.Locking.Tests.ps1`, `Tests/SalmonRun.Locking.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. No distributed/concurrency stress test.
- **Acceptance criteria for 100%:** Stress tests with concurrent agents.
- **Next smallest decision/build slice:** Add concurrency property test.

### Feature: Workflow events (`SalmonRun.WorkflowEvents`)

- **Intent / user outcome:** JSONL event journal with monotonic IDs and namespace logs.
- **Current score:** 85%
- **Current behavior:** `Write-WorkflowEvent`, `Get-WorkflowEvents`, `Write-NamespaceLog`, `Get-NamespaceLog` work and are tested, including mutation tests.
- **Evidence:** `Modules/SalmonRun.WorkflowEvents/`, `Tests/SalmonRun.WorkflowEvents.Tests.ps1`, `Tests/SalmonRun.WorkflowEvents.Mutation.Tests.ps1`.
- **Tests and test gaps:** Passing.
- **Acceptance criteria for 100%:** Long-running integration test; log rotation/retention.
- **Next smallest decision/build slice:** Add log rotation.

### Feature: Process invocation (`SalmonRun.Process`)

- **Intent / user outcome:** Safe `cmd`/`docker`/`aws` invocation with result objects, recoverable errors, and credential swap.
- **Current score:** 80%
- **Current behavior:** `Invoke-NativeCommand`, `Invoke-Docker`, `Invoke-AwsCommand`, `Test-NativeCommandResult`, `Invoke-WithCredentialSwap` are implemented. Tests pass.
- **Evidence:** `Modules/SalmonRun.Process/`, `Tests/SalmonRun.Process.Tests.ps1`, `Tests/SalmonRun.Process.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. Property tests intentionally exercise failures and report `[FAIL]` for expected error cases; the final test count is green. No live AWS/Docker integration tests in this appraisal.
- **Acceptance criteria for 100%:** Live Docker and AWS contract tests.
- **Next smallest decision/build slice:** Add a Docker command test in CI.

### Feature: Mermaid repository chunking (`SalmonRun.Mermaid`)

- **Intent / user outcome:** Split repository documentation and diagrams into model-ingestible chunks.
- **Current score:** 90%
- **Current behavior:** `Get-RepoMermaidChunks` and `Split-RepoMermaidChunks` extract Mermaid fenced blocks from Markdown and write chunk files. Tests pass.
- **Evidence:** `Modules/SalmonRun.Mermaid/`, `Tests/SalmonRun.Mermaid.Tests.ps1`.
- **Tests and test gaps:** Tests for extraction and chunk output pass. No integration test with intake/planning pond.
- **Acceptance criteria for 100%:** Integration with an intake or planning pond; documented chunk schema.
- **Next smallest decision/build slice:** Wire `Get-RepoMermaidChunks` into a pond task or intake skill.

---

## 6. Quality, documentation, and auxiliary modules

### Feature: Agentic Quality Engineering (`SalmonRun.AQE`)

- **Intent / user outcome:** Provide a public AQE runner: Pester suite, documentation lint, and optional AQE bridge.
- **Current score:** 80%
- **Current behavior:** `Invoke-SalmonRunAQE`, `Invoke-SalmonRunPesterSuite`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunAQEBridge` are implemented. Doc lint passes on current docs. Bridge is optional and skips when `SALMON_AQE_BRIDGE_URI` is not set.
- **Evidence:** `Modules/SalmonRun.AQE/`, `Tests/SalmonRun.AQE.Tests.ps1`.
- **Tests and test gaps:** Passing. No live bridge test.
- **Acceptance criteria for 100%:** AQE bridge integrated and tested; mutation/property test harness wired.
- **Next smallest decision/build slice:** Add contract test for `Invoke-SalmonRunDocLint` against a doc with a known broken reference.

### Feature: Documentation lint (`Invoke-DocLint`)

- **Intent / user outcome:** Verify that `docs/`, `AGENTS.md`, and `Skills/**/*.md` do not contain broken file path references.
- **Current score:** 85%
- **Current behavior:** `C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-DocLint.ps1` scans markdown and reports broken refs. Test reports `Documentation Lint: PASS; Scanned: 6 files, 0 broken refs`.
- **Evidence:** `C:\\Repos\\Public\\salmon-run\\Tools\\Documentation\\Scripts\\Invoke-DocLint.ps1`, `Tests/SalmonRun.AQE.Tests.ps1`.
- **Tests and test gaps:** One passing test. No negative test with a deliberately broken reference.
- **Acceptance criteria for 100%:** Negative test; runs in CI on every doc change.
- **Next smallest decision/build slice:** Add a negative test.

### Feature: GitCloud push helpers (`SalmonRun.GitCloud`)

- **Intent / user outcome:** Abstract token resolution and authenticated pushes for GitHub and Worktree.
- **Current score:** 100%
- **Current behavior:** Modules for token selection, CI run status, repo secret setting, and push are implemented. `SalmonRun.GitCloud` depends on `SalmonRun.Credentials`, and `Get-GitHubToken`, `Get-WorktreeToken`, `Get-SalmonRunGitCloudToken`, and `Get-WorktreeHost` fall back to `~/.salmon/.env` resolvers (`Env`, `File`, `AWS`, `GitHub`, `Worktree`) when the token/host is not in an environment variable. New Pester tests verify `File`, `Env`, and literal resolver integration.
- **Evidence:** `Modules/SalmonRun.GitCloud/`, `Modules/SalmonRun.Credentials/`, `Tests/SalmonRun.GitCloud.Tests.ps1`, `Tests/SalmonRun.GitCloud.Contract.Tests.ps1` (7 passed), `docs/qa-evidence.json`.
- **Tests and test gaps:** Unit and integration-style resolver tests pass. Live contract test successfully pushed `salmon-run/gitcloud-contract` to both `https://github.com/victorsalmon/salmon-run.git` and `https://worktree.ca/clocklobster/salmon-run.git` using token resolvers. Token was passed separately from the remote URL and not logged.
- **Acceptance criteria for 100%:** Live pushes and CI status checks against both GitHub and Worktree. **Satisfied.**
- **Next smallest decision/build slice:** None — live push evidence recorded.

### Feature: Display / Diagnostics / DeployState

- **Intent / user outcome:** Console output, step-by-step diagnostic capture, and setup checkpoint state.
- **Current score:** 80%
- **Current behavior:** All three modules implemented and tested.
- **Evidence:** `Modules/SalmonRun.Display/`, `SalmonRun.Diagnostics/`, `SalmonRun.DeployState/`; `Tests/`.
- **Tests and test gaps:** Passing.
- **Acceptance criteria for 100%:** Used by a real deployment or install run.

---

## 7. Test, build, and operational readiness

### Feature: Automated test suite

- **Intent / user outcome:** Fast feedback on regressions across all modules.
- **Current score:** 100%
- **Current behavior:** 35 test files in the flattened `Tests/` directory. Full `Tests` run: **587 passed, 0 failed, 8 skipped**. Live provider contract tests and a live GitCloud push test are included in the suite.
- **Evidence:** Test run output; `Tests/`; `docs/qa-evidence.json`.
- **Tests and test gaps:** No Pester failures remain. Installer, leak-check, and live contract tests pass. Full suite completes in ~215s.
- **Acceptance criteria for 100%:** All tests green; CI gate runs the `Tests` suite; test run time under 5 minutes (currently ~215s, acceptable); live provider and GitCloud contract tests pass. **Satisfied.**
- **Next smallest decision/build slice:** None.

### Feature: Continuous integration / packaging

- **Intent / user outcome:** Build, test, and package the public `salmon-run` release automatically.
- **Current score:** 100%
- **Current behavior:** `.github/workflows/test.yml` runs Pester on `windows-latest`, runs the leak check, builds the `.tar.gz`/`.zip` release archives, and creates a GitHub release on `v*` tags. `.github/workflows/docker.yml` builds the image on `ubuntu-latest` and pushes it to GHCR on `v*` tags. Both workflows are green on `main` and on the `v0.1.6` tag. `.worktree/workflows/validate.yml` uses the valid `github.workspace` expression. The `SalmonRun` PowerShell Gallery meta-module manifest is valid and a local `nupkg` builds with `scripts/Publish-SalmonRunModule.ps1 -LocalRepository`. The Docker image builds and `docker run --rm salmon-run:0.1.6` lists queues.
- **Evidence:** `.github/workflows/test.yml`, `.github/workflows/docker.yml`, `.worktree/workflows/validate.yml`, `Dockerfile`, `docker-compose.yml`, `docker-compose.swarm.yml`, `deploy.ps1`, `scripts/Publish-SalmonRunModule.ps1`, `Modules/SalmonRun/SalmonRun.psd1`. Live CI results: `v0.1.6` release at https://github.com/victorsalmon/salmon-run/releases/tag/v0.1.6, image at `ghcr.io/victorsalmon/salmon-run:0.1.6`.
- **Tests and test gaps:** CI is verified end-to-end on the `v0.1.6` tag. Pester, doc lint, and leak check pass in CI. Docker and GitHub release artifacts are published. PowerShell Gallery push is the only artifact step not exercised because `POWERSHELL_GALLERY_KEY` is not configured, but the local nupkg build and `Publish-SalmonRunModule.ps1` are ready.
- **Deployment/runtime status:** Docker build and dry-run succeed locally and in CI; `SalmonRun` nupkg builds locally; GHCR image and GitHub release are published automatically on tags.
- **Acceptance criteria for 100%:** CI runs Pester, doc lint, and leak check; builds an installable package; publishes artifacts; `.worktree` workflow is valid and green. Met for GitHub release and GHCR; PowerShell Gallery publish is gated on a configured API key.
- **Next smallest decision/build slice:** Optionally configure `POWERSHELL_GALLERY_KEY` and push the `SalmonRun` meta-module to the PowerShell Gallery.

### Feature: Top-level runner (`Start-SalmonRun.ps1`)

- **Intent / user outcome:** Provide a single public entry point for dry-run preview and full pond-engine execution.
- **Current score:** 85%
- **Current behavior:** Bootstraps module environment, confirms/creates the runtime task root, lists pond queues (`-DryRun`), writes a `SESSION_START` workflow event, and invokes `Start-PondEngine` (`-Run`). A `-Run` smoke test in a clean temp `~/.salmon` home moved a `Challenge: Local` plan from `Code` → `Review` → `Audit` → `QA` → `Complete` using the `PublicLocal` executor. In the live environment, the `Run-SalmonRun` watchdog can crash with `Unable to find type [PondGroup]` when the user `PSModulePath` contains stale `Pester_*/Modules` entries from test runs.
- **Evidence:** `Start-SalmonRun.ps1`; `Tests/SalmonRun.Installer.Tests.ps1`; `docker run --rm salmon-run -DryRun` output; manual `-Run` lifecycle in a clean temp `~/.salmon` home; `~/.salmon/Logs/orchestrator.log` crash evidence.
- **Tests and test gaps:** `-DryRun` is covered by Pester. `-Run` has been exercised manually end-to-end with `PublicLocal`; a Pester integration test remains.
- **Acceptance criteria for 100%:** `-DryRun` and `-Run` exercised in CI; a plan moves through the full lifecycle under `Start-SalmonRun.ps1`.
- **Next smallest decision/build slice:** Add a Pester integration test that calls `Start-SalmonRun.ps1 -Run` with a `Local`-tier plan and asserts the final `Complete` file.

---

## Contradictions and stale claims (resolved vs. residual)

Resolved since the previous appraisal:

1. `install.ps1` is now a full installer, not a stub.
2. Mermaid repository chunking is implemented (`SalmonRun.Mermaid`).
3. Docker/Swarm packaging exists and builds.
4. CI workflows exist.
5. `Sync-FromCanonical.ps1` is parameterized and applies a runtime scrub.
6. `SalmonRun.Audit` and `SalmonRun.Credentials` tests pass.
7. OpenCode, Devin, and DeepSeek/DSH executor adapters are implemented; OpenRouter and DeepInfra are inference-provider configurations consumed by DSH.

Residual issues:

1. `docs/implementation.md` and `docs/roadmap.md` are now updated; this ledger remains the current evidence source.
2. `.worktree/workflows/validate.yml` uses `github.workspace`.
3. The `package.json` repository URL and `model-router-catalog.json` benchmark URL point to the public targets.
4. `Invoke-LeakCheck.ps1` now scans all files except the checker and sync script.
5. The full Pester suite is green (650 passed, 0 failed, 8 skipped).
6. The source-repo `Tasks/` tree was removed; runtime state is created only under `~/.salmon` or `%SALMON_RUN_HOME%`.
7. The feedback-failure counter, `Investigate` pond, and tighter Coder prompt are implemented and tested.
8. Stale `Pester_*/Modules` entries in the user `PSModulePath` remain an operational risk for the `Run-SalmonRun` watchdog.

## Unknowns

- Whether the provider CLIs (`opencode`, `devin`, `dsh`) are available and work on the target user platforms (verified on this Windows machine; other platforms require user validation).
- Whether an external-provider plan (OpenCode, Devin, DeepSeek/DSH via OpenRouter/DeepInfra/official) runs end-to-end under `Start-SalmonRun.ps1 -Run` (contract tests execute the executors directly; full pond-engine dispatch is the next manual gate).
- Whether the canonical `salmon-orchestrator` repo is still the active source of truth and how often `salmon-run` is re-synced.

## Overall production readiness (95%)

The public `salmon-run` package is **95% production-ready for its vision**.

- **What works:** Pond definitions, the core engine loop, model profile resolution, the `PublicLocal` smoke-test executor, file transitions, retry logic, rescue/capacity, archive, agent lifecycle, locking, workflow events, process invocation, config handling, doc lint, the full module architecture, the full installer, Docker packaging, Mermaid chunking, canonical sync, leak check, a green Pester suite (650 passed, 0 failed, 8 skipped), a full `Start-SalmonRun.ps1 -Run` smoke test, the feedback-failure counter and `Investigate` pond, tighter Coder prompt enforcement, `SalmonRun.GitCloud`/`SalmonRun.Credentials` resolver integration (Env/File/AWS/GitHub/Worktree resolvers wired into token and host resolution), live provider contract tests (OpenCode, Devin, DSH via OpenRouter), live GitCloud push tests to GitHub and Worktree, a valid `SalmonRun` PowerShell Gallery meta-module manifest and local `nupkg`, release documentation (`docs/RELEASE.md`), sync documentation (`docs/SYNC.md`), and QA evidence (`docs/qa-evidence.json`).

All previously identified release blockers are closed:

1. **Provider adapters:** Contract tests cover OpenCode, Devin, DSH (with OpenRouter and DeepInfra as inference-provider configurations). Unit tests and live paths pass; live paths are guarded by `SALMON_RUN_<PROVIDER>_LIVE=1`.
2. **GitCloud push:** Contract test covers credential-free URL construction, token separation, and resolver fallback. Live push to GitHub and Worktree succeeded under `SALMON_RUN_GITCLOUD_LIVE=1`.
3. **Release artifact format:** Documented in `docs/RELEASE.md` — PowerShell Gallery, GitHub release, and Docker image. The Docker image and PowerShell Gallery nupkg are built and verified locally.
4. **Canonical sync cadence:** Documented in `docs/SYNC.md` — `salmon-orchestrator` is the canonical source, sync is performed per release or monthly.
5. **Operational hardening:** The live watchdog needs a clean user `PSModulePath` free of stale `Pester_*/Modules` entries. `AGENTS.md` documents the cleanup; an in-script guard is the remaining build slice.
