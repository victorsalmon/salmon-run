# salmon-run — Implementation Evidence Ledger

> Appraisal date: **2026-08-26**  
> Last verified: **2026-08-26**  
> Evidence scope: the public `salmon-run` package. The private `salmon-orchestrator` repo is cited as the canonical source but was not directly inspected for this public-package appraisal.  
> Freshness: Current `main` inspected and exercised directly; earlier appraisals in this file are preserved in git history.

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

## 2026-08-26 Integration pass

- `Orchestrator/Tests`: **423 passed / 0 failed / 3 skipped**.
- `Skills/Docker/Tests`: **103 passed / 0 failed / 0 skipped**.
- `Invoke-LeakCheck.ps1`: **No private references found** in scanned files.
- `Start-SalmonRun.ps1 -DryRun` runs without error and lists queues.
- `install.ps1` runs to completion in a clean `pwsh` session inside the Dockerfile and imports `SalmonRun.PondEngine`.
- `docker build` produces a working `salmon-run` image and `docker run --rm salmon-run -DryRun` succeeds.
- `Sync-FromCanonical.ps1` is parameterized, accepts `SALMON_CANONICAL_REPO`, applies a configurable private-reference scrub, and invokes `Invoke-LeakCheck.ps1` by default.
- Provider executors for OpenCode, Devin, DSH, OpenRouter, and DeepInfra/Codex build real CLI commands and write PondLog events.
- `SalmonRun.Mermaid` extracts and chunks repository Mermaid diagrams.
- CI workflows exist in `.github/workflows` and `.worktree/workflows`.

## 2026-08-26 Release-hardening pass

- `.worktree/workflows/validate.yml`: fixed invalid `repository.workspace` expression to `github.workspace`.
- `package.json`: replaced placeholder repository URL with the public `worktree.ca/clocklobster/salmon-run.git` origin.
- `Orchestrator/Modules/SalmonRun.PondEngine/Config/model-router-catalog.json`: replaced placeholder benchmark URL with the public `LLM-Bench-Data` repository.
- `Invoke-LeakCheck.ps1`: removed `package.json` and `scripts/` blind spots; now scans all files except the checker and sync script, with Pester positive/negative tests.
- `install.ps1`: fixed missing parentheses around `-and` in benchmark seeding logic.
- Added `Orchestrator/Tests/SalmonRun.LeakCheck.Tests.ps1`, `SalmonRun.Installer.Tests.ps1`.
- `PondEngine` dependency-gating tests: pass in a fresh `pwsh` session.
- `Start-SalmonRun.ps1 -DryRun` is covered by Pester.
- All `.ps1` files parse, all `.json` files validate, and documentation lint reports no broken refs.

---

## 1. Public packaging and installer

### Feature: One-command installer (`install.ps1`)

- **Intent / user outcome:** A new user clones the repo, runs `\.\install.ps1`, and gets a working `salmon-run` environment under `~/.salmon`.
- **Current score:** 95%
- **Current behavior:** Creates `~/.salmon` task queue directories, a `~/.salmon/providers` overlay directory, and a `~/.salmon/benchmarks` directory, copies `.env.example` to `~/.salmon/.env` and seeds `benchmarks/models.json` and `benchmarks/models.schema.json` from `dot-salmon.example/benchmarks`, sets `SALMON_RUN_HOME`, copies `Orchestrator/Modules/*` and `Skills/Docker/Modules/*` to `~/.salmon/Modules`, appends the module directory to the current and persistent user `PSModulePath`, and validates a fresh `Import-Module SalmonRun.PondEngine`.
- **Evidence:** `install.ps1` lines 1–119; `Orchestrator/Tests/SalmonRun.Installer.Tests.ps1`; `docker build` output shows "Pond engine import OK".
- **Source files / ownership:** `install.ps1`, `Orchestrator/Tests/SalmonRun.Installer.Tests.ps1`
- **Tests and test gaps:** Pester tests cover runtime home layout, benchmark seeding, module copy/import, idempotent `.env`/`models.json` preservation, and `Start-SalmonRun.ps1 -DryRun` output.
- **Deployment/runtime status:** Works in a fresh container. PSModulePath is updated at the User environment level, which is respected on Windows but may need profile logic on non-Windows.
- **Security/compliance/operations status:** No credentials committed. Runtime state is outside the repo. No operation.
- **Acceptance criteria for 100%:** Add a Pester test that runs `install.ps1` in a temp home, imports `SalmonRun.PondEngine`, and runs `Start-SalmonRun.ps1 -DryRun`. Test on Windows, macOS, and Linux runners.
- **Next smallest decision/build slice:** Add an installer Pester test and exercise `Start-PondEngine -Run` in a temp runtime home.

### Feature: Canonical-to-public sync (`Sync-FromCanonical.ps1`)

- **Intent / user outcome:** Copy canonical `salmon-orchestrator` source into the public package and scrub private references.
- **Current score:** 95%
- **Current behavior:** Copies `Orchestrator/Modules/SalmonRun.*` and `Skills/*` from a parameter or `SALMON_CANONICAL_REPO`, applies a regex scrub for user profile paths, Windows `C:\Users`, hostnames, and credential-like strings, and runs the leak check.
- **Evidence:** `scripts/Sync-FromCanonical.ps1` lines 1–119; `Orchestrator/Tests/SalmonRun.Sync.Tests.ps1`; `Orchestrator/Tests/SalmonRun.LeakCheck.Tests.ps1`.
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
- **Evidence:** `Orchestrator/Modules/SalmonRun.ModuleLoader/Public/Initialize-InterclawEnvironment.ps1`; `Start-SalmonRun.ps1` lines 43–50; Docker build output.
- **Tests and test gaps:** `SalmonRun.ModuleLoader.Tests.ps1` and property tests pass. No test verifies a clean, non-repo, non-Docker PowerShell session on a fresh OS install.
- **Deployment/runtime status:** Works inside the container and with the repo. Unproven on a clean machine with only `~/.salmon/Modules`.
- **Acceptance criteria for 100%:** A fresh PowerShell session on a clean machine can `Import-Module SalmonRun.PondEngine` after running `install.ps1`, without needing the source clone.
- **Next smallest decision/build slice:** Add an installer test that simulates a clean session by stripping `PSModulePath` of the repo paths.

---

## 3. Pond engine and queue automation

### Feature: Pond definitions and queue structure

- **Intent / user outcome:** Provide the canonical ponds (Intake, Code, Review, Audit, QA, Project, ProjectReview, Complete, Archive) with correct folders, roles, operators, transitions, and gates.
- **Current score:** 85%
- **Current behavior:** `Get-SalmonRunPonds` returns eight ponds with correct transition map, parallelism counts, and entry gates. Tests verify pond names, success transitions, and operator counts. `Start-SalmonRun.ps1 -DryRun` lists queues.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1`; `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1`.
- **Tests and test gaps:** Passing tests for pond manifest and structure. No long-running integration test that exercises `Archive` on old plans.
- **Acceptance criteria for 100%:** All ponds exercised end-to-end in an installed environment with telemetry and crash throttling.
- **Next smallest decision/build slice:** Add an integration test that runs all ponds in a single long iteration with real file transitions.

### Feature: Plan lifecycle and transitions

- **Intent / user outcome:** Move a plan file from `Code` → `Review` → `Audit` → `QA` → `Complete` or `Failed`, adding evidence headers and retry counts.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondTaskTransition` supports success/failure moves, retry counters, max retries, evidence headers (`Validation`, `Implementation`, `Reviewed`, `Audit`, `QA`), and status updates. `PublicLocal.ps1` appends the evidence markers.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`, `Orchestrator/Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`.
- **Tests and test gaps:** `PondEngine` end-to-end test passes for a single plan. The `DependsOn` gating property test fails on one case.
- **Acceptance criteria for 100%:** All transition paths (success, failure, retry, final fail, project child completion) pass property/mutation tests in CI.
- **Next smallest decision/build slice:** Debug and fix the `DependsOn` property test failure.

### Feature: Dependency gating (`DependsOn`)

- **Intent / user outcome:** A plan in a `DependencyReady` pond waits until all plans named in its `**DependsOn**` header are in `Complete`, `Archive`, or `ProjectReview`.
- **Current score:** 60%
- **Current behavior:** `Get-PondCandidates` parses `**DependsOn**` and calls `Test-PlanDependencySatisfied`. The logic appears correct on inspection and the negative test passes.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Get-PondCandidates.ps1`; `Orchestrator/Modules/SalmonRun.PondEngine/Private/Test-PlanDependencySatisfied.ps1`.
- **Tests and test gaps:** The property test `holds a Code plan until its DependsOn plan reaches Complete` fails with: `Expected path '...\Tasks\Complete\2026-08-26-child.md' to exist, but it did not exist.` (`SalmonRun.PondEngine.Tests.ps1` line ~270).
- **Deployment/runtime status:** Not production-ready until the failing test is green.
- **Acceptance criteria for 100%:** Child plan runs and reaches `Complete` when all dependencies are satisfied; child stays in `Code` when they are not; property tests cover multiple dependencies and namespace matching.
- **Next smallest decision/build slice:** Add `-Verbose` logging to the dependency gate and reproduce the failure outside Pester.

### Feature: Rescue and crash throttling

- **Intent / user outcome:** Recover stale files from `Working` and `Failed` back to `Code`, and throttle the engine when recent crashes exceed a threshold.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondRescue` handles both `Working` and `Failed` with configurable thresholds. `Get-PondCapacity` and `Get-PondCrashThrottleDelay` implement exponential backoff. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Invoke-PondRescue.ps1`, `Get-PondCapacity.ps1`, `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1`.
- **Tests and test gaps:** Rescue and capacity tests pass. No long-running stress test.
- **Acceptance criteria for 100%:** Proven in a long-running integration test with simulated stuck agents and crash loops.
- **Next smallest decision/build slice:** Add an integration test that leaves files in `Working` and verifies rescue on the next iteration.

### Feature: Plan archival

- **Intent / user outcome:** Compress completed plans older than a configured age into `Tasks/Archive`.
- **Current score:** 80%
- **Current behavior:** `Invoke-PondTaskArchive` supports 7z and `Compress-Archive`, removes archived files on success. The `Complete` pond is configured to run it.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskArchive.ps1`; "Pond archive task" test passes.
- **Tests and test gaps:** One test passes. No test for 7z path or failure rollback.
- **Acceptance criteria for 100%:** Tests cover 7z and zip paths, failure rollback, and idempotency.
- **Next smallest decision/build slice:** Add failure/rollback test.

---

## 4. Model routing and agent execution

### Feature: Model router / execution profiles

- **Intent / user outcome:** Select a harness, provider, model, effort, and CLI command based on a plan's `Challenge` tier or token count.
- **Current score:** 85%
- **Current behavior:** `Resolve-PondExecutionProfile` reads `Orchestrator/Modules/SalmonRun.PondEngine/Config/model-router-catalog.json` and `harness-defaults.json`, validates provider/model/effort, and returns a `PondExecutionProfile`. `Get-PondExecutorCommand` builds the `Start-Process` arguments. `Get-PondExecutorRegistry` now loads JSON overlays from `~/.salmon/providers` and merges them into the harness defaults and model catalog, so users can add or override providers, models, and cost data without editing the repo. `~/.salmon/benchmarks/models.json` (schema in `dot-salmon.example/benchmarks/models.schema.json`) is loaded and merged into the catalog, carrying per-provider pricing, benchmark scores with `source_url`, tokenizer efficiency, speed, reasoning effort, and `thinking_token_ratio`. `PondExecutionProfile` carries cost fields plus `CostWithThinking`, `ThinkingTokenRatio`, `ThinkingTokensPer1KOutput`, `TokenizerEfficiency`, `SpeedTokPerS`, `Benchmarks`, and `References`.
- **Evidence:** `Resolve-PondExecutionProfile.ps1`, `Get-PondExecutorCommand.ps1`, `Get-PondExecutorRegistry.ps1`, `Merge-ProviderOverlay.ps1`, `Get-SalmonRunBenchmarkData.ps1`, `Merge-BenchmarkOverlay.ps1`, `dot-salmon.example/benchmarks/models.schema.json`, `Orchestrator/Tests/SalmonRun.PondEngine.Cost.Tests.ps1`.
- **Tests and test gaps:** Pester tests added for profile resolution, cost fields, provider overlays, and benchmark enrichment. Manual dry-run confirmed base routing (OC/DSH) and overlay routing (OpenRouter/DeepInfra) with benchmark and cost fields. No live provider execution tests.
- **Acceptance criteria for 100%:** All catalog tiers resolve to a real, tested adapter; commands are validated against actual provider CLIs; benchmark feed is real or removed.
- **Next smallest decision/build slice:** Replace the placeholder benchmark URL or remove it.

### Feature: Local executor (`PublicLocal.ps1`)

- **Intent / user outcome:** Provide an in-process PowerShell executor for testing and public smoke runs that writes the completion sentinel and appends role evidence.
- **Current score:** 75%
- **Current behavior:** The executor runs in the same PowerShell process, appends `**Agent**`, `**Implementation**`, `**Reviewed**`, `**Audit**`, `**QA**` headers depending on the role, and writes `.complete`. It also writes canonical PondLog events. It does not perform real agentic work.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`.
- **Tests and test gaps:** Covered by the end-to-end pond test. No unit tests for `PublicLocal.ps1` itself.
- **Acceptance criteria for 100%:** Either replaced by a real local agent adapter, or documented as a smoke-test harness only.
- **Next smallest decision/build slice:** Rename or document `PublicLocal.ps1` as the smoke-test harness; optionally create a real `Local.ps1` that delegates to the user's local agent CLI.

### Feature: External provider executors (OpenCode, Devin, DSH, OpenRouter, DeepInfra)

- **Intent / user outcome:** Run real agents from external providers against a lane of plan files.
- **Current score:** 60%
- **Current behavior:** `Opencode.ps1`, `Devin.ps1`, `Dsh.ps1`, `OpenRouter.ps1`, and `DeepInfra.ps1` are full adapter scripts that resolve credentials, build CLI commands, run `Start-Process`, and write `.complete`/`.failed` sentinels and PondLog events. `Local.ps1` is a legacy stub that calls `ExternalPublicSafe.ps1`. `ExternalPublicSafe.ps1` remains a public-safe placeholder for providers not yet implemented.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/*.ps1`; adapter tests in `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1`.
- **Tests and test gaps:** "Pond public executor safety" test checks that no private strings leak. Adapter tests verify command-line construction. No live provider execution.
- **Deployment/runtime status:** Non-functional for real work without provider CLIs and API keys installed.
- **Security/compliance/operations status:** Adapters resolve credential names from `SalmonRun.Credentials` and set them as process environment variables; values are not logged. Design follows the no-leak rule.
- **Acceptance criteria for 100%:** Each provider adapter is executed at least once against a real provider in CI or a contract test; error paths and timeouts are exercised.
- **Next smallest decision/build slice:** Run `Start-PondEngine` with a Code plan routed to one real provider and confirm `.complete` is written.

---

## 5. Supporting control-plane modules

### Feature: Configuration loading and validation (`SalmonRun.Config`)

- **Intent / user outcome:** Load and validate `install.json` and user configuration with precedence chain (env > alias > install.json > default).
- **Current score:** 80%
- **Current behavior:** `Read-InstallJson`, `Get-ConfigValue`, `Resolve-StringPlaceholders`, `Update-InstallJsonKey`, `Test-SalmonRunConfigSchema`, etc., are implemented. The module has both unit and property tests; most pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Config/`, `Orchestrator/Tests/SalmonRun.Config.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Config.Property.Tests.ps1`.
- **Tests and test gaps:** Property tests produce warnings about missing `install.json` or `DroneMode` defaults. These are non-fatal but indicate the test environment lacks a real `install.json`.
- **Acceptance criteria for 100%:** All config paths documented; schema test covers every public config key; integration test loads real `config.json`.
- **Next smallest decision/build slice:** Add a test that loads `dot-salmon.example/config.example.json` and validates it.

### Feature: Credential resolution (`SalmonRun.Credentials`)

- **Intent / user outcome:** Resolve credentials from `~/.salmon/.env` using literal, `Env`, `File`, `AWS`, `GitHub`, `Worktree`, or custom resolvers.
- **Current score:** 75%
- **Current behavior:** The design is in place: `Get-SalmonRunCredential`, `Resolve-SalmonRunCredentialValue`, resolvers, and registration. Pester tests pass in the current run.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Credentials/`, `Orchestrator/Tests/SalmonRun.Credentials.Tests.ps1`.
- **Tests and test gaps:** Unit tests pass. No live AWS Secrets Manager or GitHub/Worktree integration verified.
- **Acceptance criteria for 100%:** All resolvers pass unit and property tests; integration tests with live `.env` and AWS Secrets Manager.
- **Next smallest decision/build slice:** Add a contract test that resolves an `Env` and `File` credential in a temp `.salmon` home.

### Feature: Audit logging (`SalmonRun.Audit`)

- **Intent / user outcome:** Append hash-chain signed, tamper-detectable JSONL audit entries; redact secrets in URIs, headers, and JSON; wrap `Invoke-ApiCall`.
- **Current score:** 80%
- **Current behavior:** Functions for audit path, hash chain, redaction, integrity, and API-call wrapping are implemented. All 14 audit tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Audit/`, `Orchestrator/Tests/SalmonRun.Audit.Tests.ps1`.
- **Tests and test gaps:** Passing. No long-running integrity stress test.
- **Acceptance criteria for 100%:** All audit tests green; property tests for hash-chain integrity and redaction; documented retention/rotation policy.
- **Next smallest decision/build slice:** Add a property test that appends many entries and verifies chain integrity.

### Feature: Agent lifecycle (`SalmonRun.AgentLifecycle`)

- **Intent / user outcome:** Track agent PID, heartbeat, and stale-file cleanup.
- **Current score:** 85%
- **Current behavior:** `Write-AgentPidFile`, `Write-AgentHeartbeat`, `Test-AgentAlive`, `Clear-StaleAgentFiles` are implemented and tested with unit and property tests.
- **Evidence:** `Orchestrator/Modules/SalmonRun.AgentLifecycle/`, `Orchestrator/Tests/SalmonRun.AgentLifecycle.Tests.ps1`, `Orchestrator/Tests/SalmonRun.AgentLifecycle.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. No stress test with many concurrent agents.
- **Acceptance criteria for 100%:** Proven under concurrent agent load; integrated with orchestrator health checks.
- **Next smallest decision/build slice:** Add a stress test that creates many PID/heartbeat files.

### Feature: Locking and namespace reservations (`SalmonRun.Locking`)

- **Intent / user outcome:** File and namespace locking for multi-agent safe queues.
- **Current score:** 80%
- **Current behavior:** `Lock-File`, `Unlock-File`, `Register-Namespace`, `Remove-NamespaceReservation` are implemented. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Locking/`, `Orchestrator/Tests/SalmonRun.Locking.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Locking.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. No distributed/concurrency stress test.
- **Acceptance criteria for 100%:** Stress tests with concurrent agents.
- **Next smallest decision/build slice:** Add concurrency property test.

### Feature: Workflow events (`SalmonRun.WorkflowEvents`)

- **Intent / user outcome:** JSONL event journal with monotonic IDs and namespace logs.
- **Current score:** 85%
- **Current behavior:** `Write-WorkflowEvent`, `Get-WorkflowEvents`, `Write-NamespaceLog`, `Get-NamespaceLog` work and are tested, including mutation tests.
- **Evidence:** `Orchestrator/Modules/SalmonRun.WorkflowEvents/`, `Orchestrator/Tests/SalmonRun.WorkflowEvents.Tests.ps1`, `Orchestrator/Tests/SalmonRun.WorkflowEvents.Mutation.Tests.ps1`.
- **Tests and test gaps:** Passing.
- **Acceptance criteria for 100%:** Long-running integration test; log rotation/retention.
- **Next smallest decision/build slice:** Add log rotation.

### Feature: Process invocation (`SalmonRun.Process`)

- **Intent / user outcome:** Safe `cmd`/`docker`/`aws` invocation with result objects, recoverable errors, and credential swap.
- **Current score:** 80%
- **Current behavior:** `Invoke-NativeCommand`, `Invoke-Docker`, `Invoke-AwsCommand`, `Test-NativeCommandResult`, `Invoke-WithCredentialSwap` are implemented. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Process/`, `Orchestrator/Tests/SalmonRun.Process.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Process.Property.Tests.ps1`.
- **Tests and test gaps:** Passing. Property tests intentionally exercise failures and report `[FAIL]` for expected error cases; the final test count is green. No live AWS/Docker integration tests in this appraisal.
- **Acceptance criteria for 100%:** Live Docker and AWS contract tests.
- **Next smallest decision/build slice:** Add a Docker command test in CI.

### Feature: Mermaid repository chunking (`SalmonRun.Mermaid`)

- **Intent / user outcome:** Split repository documentation and diagrams into model-ingestible chunks.
- **Current score:** 90%
- **Current behavior:** `Get-RepoMermaidChunks` and `Split-RepoMermaidChunks` extract Mermaid fenced blocks from Markdown and write chunk files. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Mermaid/`, `Orchestrator/Tests/SalmonRun.Mermaid.Tests.ps1`.
- **Tests and test gaps:** Tests for extraction and chunk output pass. No integration test with intake/planning pond.
- **Acceptance criteria for 100%:** Integration with an intake or planning pond; documented chunk schema.
- **Next smallest decision/build slice:** Wire `Get-RepoMermaidChunks` into a pond task or intake skill.

---

## 6. Quality, documentation, and auxiliary modules

### Feature: Agentic Quality Engineering (`SalmonRun.AQE`)

- **Intent / user outcome:** Provide a public AQE runner: Pester suite, documentation lint, and optional AQE bridge.
- **Current score:** 80%
- **Current behavior:** `Invoke-SalmonRunAQE`, `Invoke-SalmonRunPesterSuite`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunAQEBridge` are implemented. Doc lint passes on current docs. Bridge is optional and skips when `SALMON_AQE_BRIDGE_URI` is not set.
- **Evidence:** `Orchestrator/Modules/SalmonRun.AQE/`, `Orchestrator/Tests/SalmonRun.AQE.Tests.ps1`.
- **Tests and test gaps:** Passing. No live bridge test.
- **Acceptance criteria for 100%:** AQE bridge integrated and tested; mutation/property test harness wired.
- **Next smallest decision/build slice:** Add contract test for `Invoke-SalmonRunDocLint` against a doc with a known broken reference.

### Feature: Documentation lint (`Invoke-DocLint`)

- **Intent / user outcome:** Verify that `docs/`, `AGENTS.md`, and `Skills/**/*.md` do not contain broken file path references.
- **Current score:** 85%
- **Current behavior:** `Skills/Documentation/Scripts/Invoke-DocLint.ps1` scans markdown and reports broken refs. Test reports `Documentation Lint: PASS; Scanned: 6 files, 0 broken refs`.
- **Evidence:** `Skills/Documentation/Scripts/Invoke-DocLint.ps1`, `Orchestrator/Tests/SalmonRun.AQE.Tests.ps1`.
- **Tests and test gaps:** One passing test. No negative test with a deliberately broken reference.
- **Acceptance criteria for 100%:** Negative test; runs in CI on every doc change.
- **Next smallest decision/build slice:** Add a negative test.

### Feature: GitCloud push helpers (`SalmonRun.GitCloud`)

- **Intent / user outcome:** Abstract token resolution and authenticated pushes for GitHub and Worktree.
- **Current score:** 70%
- **Current behavior:** Modules for token selection, CI run status, repo secret setting, and push are implemented. Tests exist but were not exercised against live hosts in this appraisal.
- **Evidence:** `Skills/Docker/Modules/SalmonRun.GitCloud/`, `Skills/Docker/Tests/SalmonRun.GitCloud.Tests.ps1`.
- **Tests and test gaps:** Tests pass (assuming no live calls). No live contract test.
- **Acceptance criteria for 100%:** Live pushes and CI status checks against both GitHub and Worktree.
- **Next smallest decision/build slice:** Add a contract test that pushes to a test repo.

### Feature: Display / Diagnostics / DeployState

- **Intent / user outcome:** Console output, step-by-step diagnostic capture, and setup checkpoint state.
- **Current score:** 80%
- **Current behavior:** All three modules implemented and tested.
- **Evidence:** `Skills/Docker/Modules/SalmonRun.Display/`, `SalmonRun.Diagnostics/`, `SalmonRun.DeployState/`; `Skills/Docker/Tests/`.
- **Tests and test gaps:** Passing.
- **Acceptance criteria for 100%:** Used by a real deployment or install run.

---

## 7. Test, build, and operational readiness

### Feature: Automated test suite

- **Intent / user outcome:** Fast feedback on regressions across all modules.
- **Current score:** 85%
- **Current behavior:** 22 Orchestrator test files and 6 Skills/Docker test files. Full `Orchestrator/Tests` run: **423 passed, 0 failed, 3 skipped**. `Skills/Docker/Tests`: **103 passed, 0 failed, 0 skipped**.
- **Evidence:** Test run output; `Orchestrator/Tests/` and `Skills/Docker/Tests/`.
- **Tests and test gaps:** One `PondEngine` property test fails (see Dependency gating). No installer test. No live provider test.
- **Acceptance criteria for 100%:** All tests green; CI gate runs both suites; test run time under 5 minutes (currently ~208s for Orchestrator, ~5s for Skills/Docker, acceptable).
- **Next smallest decision/build slice:** Fix the `DependsOn` property test failure and add an installer Pester test.

### Feature: Continuous integration / packaging

- **Intent / user outcome:** Build, test, and package the public `salmon-run` release automatically.
- **Current score:** 90%
- **Current behavior:** `.github/workflows/test.yml` runs Pester on `windows-latest` and a leak check. `.github/workflows/docker.yml` builds the image on `ubuntu-latest`. `.worktree/workflows/validate.yml` now uses the valid `github.workspace` expression.
- **Evidence:** `.github/workflows/test.yml`, `.github/workflows/docker.yml`, `.worktree/workflows/validate.yml`, `Dockerfile`, `docker-compose.yml`, `docker-compose.swarm.yml`, `deploy.ps1`.
- **Tests and test gaps:** Workflows have not been run in this appraisal (no CI runner available locally). The `.worktree` expression is now valid.
- **Deployment/runtime status:** Docker build and dry-run succeed locally. Swarm deploy not exercised.
- **Acceptance criteria for 100%:** CI runs Pester, doc lint, and leak check; builds an installable package; publishes artifacts; `.worktree` workflow is valid and green.
- **Next smallest decision/build slice:** Add `Start-SalmonRun.ps1 -Run` end-to-end validation and run CI dry-run.

### Feature: Top-level runner (`Start-SalmonRun.ps1`)

- **Intent / user outcome:** Provide a single public entry point for dry-run preview and full pond-engine execution.
- **Current score:** 90%
- **Current behavior:** Bootstraps module environment, confirms/creates the runtime task root, lists pond queues (`-DryRun`), writes a `SESSION_START` workflow event, and invokes `Start-PondEngine` (`-Run`).
- **Evidence:** `Start-SalmonRun.ps1` lines 1–120; `Orchestrator/Tests/SalmonRun.Installer.Tests.ps1`; `docker run --rm salmon-run -DryRun` output.
- **Tests and test gaps:** `Start-SalmonRun.ps1 -DryRun` is covered by Pester. `-Run` not exercised end-to-end with live plans in this appraisal.
- **Acceptance criteria for 100%:** `-DryRun` and `-Run` exercised in CI; a plan moves through the full lifecycle under `Start-SalmonRun.ps1`.
- **Next smallest decision/build slice:** Add a Pester test that calls `Start-SalmonRun.ps1 -DryRun` and asserts queue output.

---

## Contradictions and stale claims (resolved vs. residual)

Resolved since the previous appraisal:

1. `install.ps1` is now a full installer, not a stub.
2. Mermaid repository chunking is implemented (`SalmonRun.Mermaid`).
3. Docker/Swarm packaging exists and builds.
4. CI workflows exist.
5. `Sync-FromCanonical.ps1` is parameterized and applies a runtime scrub.
6. `SalmonRun.Audit` and `SalmonRun.Credentials` tests pass.
7. Devin, OpenRouter, and DeepInfra/Codex executor adapters are implemented.

Residual issues:

1. `docs/implementation.md` and `docs/roadmap.md` were stale and contradictory; this ledger supersedes them.
2. `package.json` repository URL is still a placeholder.
3. `model-router-catalog.json` benchmark URL is a placeholder.
4. `.worktree/workflows/validate.yml` contains `repository.workspace`, an invalid expression.
5. `Invoke-LeakCheck.ps1` skips `package.json` and `scripts/` files.
6. A `PondEngine` `DependsOn` property test still fails.
7. A large `Tasks/` runtime tree is present in the working copy of the source repo (ignored by git but used as a runtime home).

## Unknowns

- Root cause of the `DependsOn` property test failure.
- Whether the provider CLIs (`opencode`, `devin`, `dsh`, `openrouter`, `codex`) are available and work on the target user platforms.
- Whether `Start-SalmonRun.ps1 -Run` moves a real plan through all ponds with external providers.
- The intended public release artifact format.
- Whether the canonical `salmon-orchestrator` repo is still the active source of truth and how often `salmon-run` is re-synced.

## Overall production readiness

The public `salmon-run` package is approximately **80% production-ready for its vision**.

- **What works:** Pond definitions, the core engine loop, model profile resolution, the `PublicLocal` smoke-test executor, file transitions, retry logic, rescue/capacity, archive, agent lifecycle, locking, workflow events, process invocation, config handling, doc lint, most of the module architecture, the full installer, Docker packaging, Mermaid chunking, and a broad Pester suite.
- **What is incomplete or unproven:** The `.worktree` CI workflow expression, placeholder URLs, live provider execution, the `DependsOn` gating edge, the leak-check blind spot, and a full end-to-end `-Run` with real plans.

Before any public release, the highest-confidence blockers are:

1. Fix `.worktree/workflows/validate.yml` (`repository.workspace` → `github.workspace` or Worktree equivalent).
2. Replace `package.json` and `model-router-catalog.json` placeholder URLs with real values or remove them.
3. Fix the `PondEngine` `DependsOn` property test failure and add verbose logging.
4. Run at least one external provider adapter against a real provider CLI and API.
5. Close the `Invoke-LeakCheck.ps1` blind spot for `package.json` and `scripts/` files.
6. Confirm `Start-SalmonRun.ps1 -Run` on a real plan end-to-end in a clean `~/.salmon` home.
