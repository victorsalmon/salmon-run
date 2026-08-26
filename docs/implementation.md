# salmon-run — Implementation Evidence Ledger

> Appraisal date: **2026-08-27**  
> Last verified: **2026-08-27**  
> Evidence scope: `C:\Repos\Public\salmon-run`. The private `salmon-orchestrator` repo is cited as the canonical source but was not directly inspected for this public-package appraisal.  
> Freshness: Wave 1–4 integrated on `main`; full test suite and leak check pass.

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

## 2026-08-27 Integration pass

- PondLog I/O standardization, packaging, OpenCode, and DSH waves merged to `main`.
- `Orchestrator/Tests`: **408 passed / 0 failed / 3 skipped**.
- `Skills/Docker/Tests`: **103 passed / 0 failed / 0 skipped**.
- `Invoke-LeakCheck.ps1`: **No private references found.**
- `install.ps1` completes in a fresh `pwsh -NoProfile` session and imports `SalmonRun.PondEngine`.
- `Start-SalmonRun.ps1 -DryRun` runs without error.
- Remaining deferred work: Devin, OpenRouter, DeepInfra executors; Mermaid repo chunking; Docker/Swarm packaging.

---

## 1. Public packaging and installer

### Feature: One-command installer (`install.ps1`)

- **Intent / user outcome:** A new user clones the repo, runs `\.\install.ps1`, and gets a working `salmon-run` environment under `~/.salmon`.
- **Current score:** 30%
- **Current behavior:** Creates `~/.salmon` task queue directories, copies `.env.example` to `~/.salmon/.env`, sets `SALMON_RUN_HOME` environment variable, and creates an install target directory. Does **not** copy modules to `~/.salmon/Modules` or wire `PSModulePath`.
- **Evidence:** `install.ps1` lines 67–75 explicitly state: "Module copy and path wiring will be added once the public mirror projection is complete." `Write-Host "Installer stub complete."`
- **Source files / ownership:** `install.ps1`
- **Tests and test gaps:** No installer tests found.
- **Deployment/runtime status:** Not deployable. A fresh clone + `install.ps1` leaves the user with empty `~/.salmon` directories and no importable modules.
- **Security/compliance/operations status:** No credentials are committed. Runtime state is outside the repo. No operation.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Depends on completing the canonical projection and deciding install location (`~/.salmon/Modules`, PowerShell Gallery, etc.).
- **Acceptance criteria for 100%:** Installer copies/validates all modules, updates `PSModulePath` or installs to a standard module location, seeds `config.json`, validates a `Start-PondEngine` dry run, and is covered by Pester tests.
- **Next smallest decision/build slice:** Decide whether the installer copies `Orchestrator/Modules` and `Skills/Docker/Modules` into `~/.salmon/Modules` or leaves them in the clone and updates `PSModulePath`.
- **Confidence and freshness:** High confidence; the file is a deliberate stub.

### Feature: Canonical-to-public sync (`Sync-FromCanonical.ps1`)

- **Intent / user outcome:** Copy canonical `salmon-orchestrator` source into the public package, then run a leak check.
- **Current score:** 50%
- **Current behavior:** Copies `Orchestrator/Modules/SalmonRun.*` and `Skills/*` from a hardcoded `C:\Repos\salmon-orchestrator`. Does not scrub private references. Public docs are hand-curated and not copied.
- **Evidence:** `scripts/Sync-FromCanonical.ps1` lines 14–43. `scripts/Invoke-LeakCheck.ps1` scans for private strings.
- **Source files / ownership:** `scripts/Sync-FromCanonical.ps1`, `scripts/Invoke-LeakCheck.ps1`
- **Tests and test gaps:** No tests for sync or leak-check. `Invoke-LeakCheck.ps1` skips `package.json`, `Sync-FromCanonical.ps1`, and `Invoke-LeakCheck.ps1` itself.
- **Deployment/runtime status:** Manual tool only. Cannot be run by a public user who lacks the canonical repo.
- **Security/compliance/operations status:** Leak check finds no private references in current files (DocLint PASS in AQE test). The sync tool itself has hardcoded `C:\Repos\salmon-orchestrator` and would leak if shipped.
- **Dependencies and blockers:** Requires canonical repo. Needs a real scrub/transformation pipeline before public release.
- **Acceptance criteria for 100%:** Sync is parameterized and environment-agnostic; applies a configurable scrub rule set; runs in CI; leak check covers all files including scripts.
- **Next smallest decision/build slice:** Remove hardcoded `C:\Repos\salmon-orchestrator` and add parameter/validation.
- **Confidence and freshness:** High confidence; README and script comments confirm this is a developer-only tool.

---

## 2. Module architecture and loadability

### Feature: Module discovery and load order (`ModuleLoader`, `Core`)

- **Intent / user outcome:** Any consumer can import `SalmonRun.*` modules without manual dependency resolution.
- **Current score:** 40%
- **Current behavior:** `SalmonRun.ModuleLoader` provides `Import-InterclawModule` and `Initialize-InterclawEnvironment` to add module roots to `PSModulePath` and import by name. `SalmonRun.Core` `RequiredModules` declares `SalmonRun.Paths`, `SalmonRun.Ports`, `SalmonRun.Diagnostics`, `SalmonRun.Locking`, which live under `Skills/Docker/Modules`. Direct `Import-Module` on most `Orchestrator/Modules/*.psd1` files fails unless `PSModulePath` is already seeded.
- **Evidence:**
  - Manual `Import-Module C:\...\SalmonRun.Audit\SalmonRun.Audit.psd1 -Force` failed: "The required module 'SalmonRun.Core' is not loaded."
  - Manual `Import-Module C:\...\SalmonRun.Core\SalmonRun.Core.psd1` failed: "The required module 'SalmonRun.Paths' is not loaded."
  - `Orchestrator/Modules/SalmonRun.Core/SalmonRun.Core.psm1` has runtime logic to `Find-SalmonRunModuleData`, but `RequiredModules` in the `.psd1` are resolved by PowerShell before the `.psm1` runs.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.ModuleLoader`, `Orchestrator/Modules/SalmonRun.Core`
- **Tests and test gaps:** `SalmonRun.ModuleLoader.Tests.ps1` tests the loader functions; `SalmonRun.Core.Tests.ps1` tests core functions. No test verifies that a clean PowerShell session can `Install-Module` / `Import-Module` all `Orchestrator` modules without pre-loading.
- **Deployment/runtime status:** Works inside the test suite because `Initialize-InterclawEnvironment` (called in `ModuleLoader.Tests.ps1`) or previous module imports leave `PSModulePath` set. Does not work out-of-box.
- **Security/compliance/operations status:** No credential exposure. Load path could be confused by `REPO_ROOT` or `SALMON_RUN_HOME` env vars.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Installer must run `Initialize-InterclawEnvironment` or install modules to a standard location. `RequiredModules` lists modules in `Skills/Docker/Modules`, which is non-standard.
- **Acceptance criteria for 100%:** A fresh PowerShell session on a machine with only the installed package can `Import-Module SalmonRun.PondEngine` and `Start-PondEngine` without error.
- **Next smallest decision/build slice:** Either remove `RequiredModules` entries that live outside `Orchestrator/Modules` and load them at runtime, or have `install.ps1` install everything into a single `Modules` directory and update `PSModulePath`.
- **Confidence and freshness:** High confidence. Reproduced manually.

---

## 3. Pond engine and queue automation

### Feature: Pond definitions and queue structure

- **Intent / user outcome:** Provide the canonical ponds (Intake, Code, Review, Audit, QA, Project, ProjectReview, Complete, Archive) with correct folders, roles, operators, transitions, and gates.
- **Current score:** 75%
- **Current behavior:** `Get-SalmonRunPonds` returns eight ponds with correct transition map, parallelism counts, and entry gates. Tests verify pond names, success transitions, and operator counts.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1`; `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1` "Get-SalmonRunPonds" describe.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine`
- **Tests and test gaps:** Passing tests for pond manifest and structure. Missing live tests that the `Archive` pond runs on old plans in a real schedule.
- **Deployment/runtime status:** Local test only.
- **Security/compliance/operations status:** No credentials. Ponds operate on file paths under `SALMON_RUN_HOME`.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Needs `SalmonRun.Paths` / `SalmonRun.Constants`.
- **Acceptance criteria for 100%:** All ponds exercised end-to-end in an installed environment, with telemetry and crash throttling.
- **Next smallest decision/build slice:** Add an integration test that runs all ponds in a single long iteration with real file transitions.
- **Confidence and freshness:** High; structure is stable and well tested.

### Feature: Plan lifecycle and transitions

- **Intent / user outcome:** Move a plan file from `Code` → `Review` → `Audit` → `QA` → `Complete` or `Failed`, adding evidence headers and retry counts.
- **Current score:** 65%
- **Current behavior:** `Invoke-PondTaskTransition` supports success/failure moves, retry counters, max retries, evidence headers (`Validation`, `Implementation`, `Reviewed`, `Audit`, `QA`), and status updates. The `PublicLocal.ps1` executor appends the evidence markers a real agent would supply.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`, `Orchestrator/Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`. The test "moves a Code plan to Complete using the Local harness" passes.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/`
- **Tests and test gaps:** `PondEngine` end-to-end test passes for a single plan. The `DependsOn` gating test fails. Project decomposition test passes.
- **Deployment/runtime status:** Local tests only; no live agent integration.
- **Security/compliance/operations status:** No credential handling. File moves are within `~/.salmon/Tasks`.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Depends on `Start-PondEngine` and `Get-PondCandidates`.
- **Acceptance criteria for 100%:** All transition paths (success, failure, retry, final fail, project child completion) pass property/mutation tests in CI.
- **Next smallest decision/build slice:** Fix the failing `DependsOn` gating test; add property tests for retry/final-fail counters.
- **Confidence and freshness:** Medium; one real bug in dependency gating.

### Feature: Dependency gating (`DependsOn`)

- **Intent / user outcome:** A plan in a `DependencyReady` pond waits until all plans named in its `**DependsOn**` header are in `Complete`, `Archive`, or `ProjectReview`.
- **Current score:** 40%
- **Current behavior:** `Get-PondCandidates` parses `**DependsOn**` and calls `Test-PlanDependencySatisfied`, which scans completion ponds for a filename or namespace match. The logic appears correct on inspection.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Get-PondCandidates.ps1` lines 47–67; `Orchestrator/Modules/SalmonRun.PondEngine/Private/Test-PlanDependencySatisfied.ps1`.  
  However, the test `holds a Code plan until its DependsOn plan reaches Complete` failed with: `Expected path '...\Tasks\Complete\2026-08-26-child.md' to exist, but it did not exist.` (`SalmonRun.PondEngine.Tests.ps1` line 270).
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Get-PondCandidates.ps1`, `Orchestrator/Modules/SalmonRun.PondEngine/Private/Test-PlanDependencySatisfied.ps1`
- **Tests and test gaps:** One test fails; the complementary test "keeps a Code plan in Code when its DependsOn plan is not yet Complete" passes.
- **Deployment/runtime status:** Not production-ready until the failing test is green.
- **Security/compliance/operations status:** No credential handling.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** `Context.TaskRoot` must be set; `Complete` pond must be scanned.
- **Acceptance criteria for 100%:** Child plan runs and reaches `Complete` when all dependencies are satisfied; child stays in `Code` when they are not; property tests cover multiple dependencies and namespace matching.
- **Next smallest decision/build slice:** Debug why the child is not selected/moved to `Complete` in the failing test; add `-Verbose` logging.
- **Confidence and freshness:** Medium; the failure is a concrete bug that needs root cause analysis.

### Feature: Rescue and crash throttling

- **Intent / user outcome:** Recover stale files from `Working` and `Failed` back to `Code`, and throttle the engine when recent crashes exceed a threshold.
- **Current score:** 75%
- **Current behavior:** `Invoke-PondRescue` handles both `Working` and `Failed` with configurable thresholds. `Get-PondCapacity` and `Get-PondCrashThrottleDelay` implement exponential backoff. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Invoke-PondRescue.ps1`, `Orchestrator/Modules/SalmonRun.PondEngine/Private/Get-PondCapacity.ps1`, `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1` "Pond rescue" and "Pond capacity".
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/`
- **Tests and test gaps:** Rescue and capacity tests pass. No long-running stress test.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Proven in a long-running integration test with simulated stuck agents and crash loops.
- **Next smallest decision/build slice:** Add an integration test that leaves files in `Working` and verifies rescue on next iteration.
- **Confidence and freshness:** High for the unit path.

### Feature: Plan archival

- **Intent / user outcome:** Compress completed plans older than a configured age into `Tasks/Archive`.
- **Current score:** 70%
- **Current behavior:** `Invoke-PondTaskArchive` supports 7z and `Compress-Archive`, removes archived files on success. The `Complete` pond is configured to run it.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskArchive.ps1`; "Pond archive task" test passes.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskArchive.ps1`
- **Tests and test gaps:** One test passes. No test for 7z path or failure rollback.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Requires `7z` or `Compress-Archive`.
- **Acceptance criteria for 100%:** Tests cover 7z and zip paths, failure rollback, and idempotency.
- **Next smallest decision/build slice:** Add failure/rollback test.
- **Confidence and freshness:** Medium; functional but lightly tested.

---

## 4. Model routing and agent execution

### Feature: Model router / execution profiles

- **Intent / user outcome:** Select a harness, provider, model, effort, and CLI command based on a plan's `Challenge` tier or token count.
- **Current score:** 70%
- **Current behavior:** `Resolve-PondExecutionProfile` reads ``Orchestrator/Modules/SalmonRun.PondEngine/Config/model-router-catalog.json` and `Orchestrator/Modules/SalmonRun.PondEngine/Config/harness-defaults.json`, validates provider/model/effort, and returns a `PondExecutionProfile`. `Get-PondExecutorCommand` builds the `Start-Process` arguments.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Executor/Resolve-PondExecutionProfile.ps1`, `Orchestrator/Modules/SalmonRun.PondEngine/Private/Executor/Get-PondExecutorCommand.ps1`, `Orchestrator/Tests/SalmonRun.PondEngine.Tests.ps1` "Pond executor registry".
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Private/Executor/`
- **Tests and test gaps:** Tests pass for profile resolution and command generation. No live execution tests for non-local providers.
- **Deployment/runtime status:** Local tests only.
- **Security/compliance/operations status:** Credentials are resolved by name and injected into child process environment; values are not logged.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Depends on `SalmonRun.Credentials` for external providers.
- **Acceptance criteria for 100%:** All catalog tiers resolve to a real, tested adapter; commands are validated against actual provider CLIs.
- **Next smallest decision/build slice:** Ship and test one real external adapter (e.g., OpenCode CLI).
- **Confidence and freshness:** High for the router; low for real providers.

### Feature: Local executor (`PublicLocal.ps1`)

- **Intent / user outcome:** Provide an in-process PowerShell executor for testing and public smoke runs that writes the completion sentinel and appends role evidence.
- **Current score:** 50%
- **Current behavior:** The executor runs in the same PowerShell process, appends `**Agent**`, `**Implementation**`, `**Reviewed**`, `**Audit**`, `**QA**` headers depending on the role, and writes `.complete`. It does not perform real work.
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/PublicLocal.ps1`
- **Tests and test gaps:** Covered by the end-to-end pond test. No unit tests for `PublicLocal.ps1` itself.
- **Deployment/runtime status:** Useful for smoke tests, not for real agentic work.
- **Security/compliance/operations status:** No credential handling.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Either replaced by a real local agent adapter, or documented as a smoke-test harness only.
- **Next smallest decision/build slice:** Rename or document `PublicLocal.ps1` as the smoke-test harness; create a real `Local.ps1` that delegates to the user's local agent CLI.
- **Confidence and freshness:** High; the file explicitly says it is a public local executor.

### Feature: External provider executors (OpenCode, Devin, DSH, OpenRouter, DeepInfra)

- **Intent / user outcome:** Run real agents from external providers against a lane of plan files.
- **Current score:** 10%
- **Current behavior:** Every external provider file (`Opencode.ps1`, `Devin.ps1`, `Dsh.ps1`, `OpenRouter.ps1`, `DeepInfra.ps1`, `Local.ps1`, `LocalPlatform.ps1`, `Platform.ps1`, `local-platform.ps1`) is a public-safe stub/placeholder. They write an `executor.log` and `.failed` sentinel and exit. The `Local.ps1` stub delegates to `ExternalPublicSafe.ps1` and returns exit code 0 because it does not propagate the child's `exit 1` (it uses `&` and has no `exit $LASTEXITCODE`).
- **Evidence:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/*.ps1`; grep for "placeholder" / "stub".
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.PondEngine/Executors/`
- **Tests and test gaps:** "Pond public executor safety" test checks that no private strings leak. No functional tests.
- **Deployment/runtime status:** Non-functional for real work.
- **Security/compliance/operations status:** The stub `ExternalPublicSafe.ps1` resolves credential names from `SalmonRun.Credentials` but does not log values; it then fails.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Requires provider CLIs, API keys, and real adapters.
- **Acceptance criteria for 100%:** Each provider adapter is implemented, tested in CI (or with contract tests), and documented.
- **Next smallest decision/build slice:** Implement one adapter and validate the `Start-PondExecutor` → adapter → `.complete` / `.failed` flow.
- **Confidence and freshness:** High; the files are explicit stubs.

---

## 5. Supporting control-plane modules

### Feature: Configuration loading and validation (`SalmonRun.Config`)

- **Intent / user outcome:** Load and validate `install.json` and user configuration with precedence chain (env > alias > install.json > default).
- **Current score:** 70%
- **Current behavior:** `Read-InstallJson`, `Get-ConfigValue`, `Resolve-StringPlaceholders`, `Update-InstallJsonKey`, `Test-SalmonRunConfigSchema`, etc., are implemented. The module has both unit and property tests; most pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Config/`, `Orchestrator/Tests/SalmonRun.Config.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Config.Property.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.Config/`
- **Tests and test gaps:** Tests pass. Property tests produce warnings about "DroneMode" defaults, which suggests the test environment lacks a real `install.json`.
- **Deployment/runtime status:** Works in tests.
- **Security/compliance/operations status:** No credential exposure.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** All config paths documented; schema test covers every public config key; integration test loads real `config.json`.
- **Next smallest decision/build slice:** Add a test that loads `dot-salmon.example/config.example.json` and validates it.
- **Confidence and freshness:** Medium; functionality is solid but the warning noise in property tests is a smell.

### Feature: Credential resolution (`SalmonRun.Credentials`)

- **Intent / user outcome:** Resolve credentials from `~/.salmon/.env` using literal, `Env`, `File`, `AWS`, `GitHub`, `Worktree`, or custom resolvers.
- **Current score:** 35%
- **Current behavior:** The design is in place: `Get-SalmonRunCredential`, `Resolve-SalmonRunCredentialValue`, resolvers, and registration. However, the Pester test container for `SalmonRun.Credentials` fails to load with the same `break`/`continue` label error that affects `SalmonRun.Audit`, so the module is not regression-tested.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Credentials/`, `Orchestrator/Tests/SalmonRun.Credentials.Tests.ps1` (container failed). Manual `Import-Module` of the psd1 also triggers dependency failures or label errors.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.Credentials/`
- **Tests and test gaps:** 10 tests are listed as failed in the full run. The module cannot be loaded in a clean test session.
- **Deployment/runtime status:** Not production-ready.
- **Security/compliance/operations status:** Resolvers are designed not to log values. Cannot verify until tests pass.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Blocked by module load issue and the `break`/`continue` label error.
- **Acceptance criteria for 100%:** All resolvers pass unit and property tests; integration tests with live `.env` and AWS Secrets Manager.
- **Next smallest decision/build slice:** Fix the module load / break-continue error so `SalmonRun.Credentials` can be imported and its tests run.
- **Confidence and freshness:** Low until the load error is diagnosed.

### Feature: Audit logging (`SalmonRun.Audit`)

- **Intent / user outcome:** Append hash-chain signed, tamper-detectable JSONL audit entries; redact secrets in URIs, headers, and JSON; wrap `Invoke-ApiCall`.
- **Current score:** 35%
- **Current behavior:** Functions for audit path, hash chain, redaction, integrity, and API-call wrapping are implemented. The entire `Describe` block fails at `BeforeAll` with: `InvalidOperationException: A 'break' or 'continue' statement with a label that does not match any enclosing loop escaped from your code.` This prevents all 14 audit tests from running.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Audit/`, `Orchestrator/Tests/SalmonRun.Audit.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.Audit/`
- **Tests and test gaps:** 14 tests are listed as failed. The module cannot be imported in the test session.
- **Deployment/runtime status:** Not production-ready.
- **Security/compliance/operations status:** The redaction patterns and hash-chain design are present but unverified.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Blocked by module load / break-continue error.
- **Acceptance criteria for 100%:** All audit tests green; property tests for hash-chain integrity and redaction; documented retention/rotation policy.
- **Next smallest decision/build slice:** Reproduce the `Import-Module SalmonRun.Audit` error outside Pester and localize the offending `break`/`continue`.
- **Confidence and freshness:** Low until the load error is fixed.

### Feature: Agent lifecycle (`SalmonRun.AgentLifecycle`)

- **Intent / user outcome:** Track agent PID, heartbeat, and stale-file cleanup.
- **Current score:** 80%
- **Current behavior:** `Write-AgentPidFile`, `Write-AgentHeartbeat`, `Test-AgentAlive`, `Clear-StaleAgentFiles` are implemented and tested with unit and property tests. The module loads and passes.
- **Evidence:** `Orchestrator/Modules/SalmonRun.AgentLifecycle/`, `Orchestrator/Tests/SalmonRun.AgentLifecycle.Tests.ps1`, `Orchestrator/Tests/SalmonRun.AgentLifecycle.Property.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.AgentLifecycle/`
- **Tests and test gaps:** Passing. No stress test with many concurrent agents.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Proven under concurrent agent load; integrated with orchestrator health checks.
- **Next smallest decision/build slice:** Add a stress test that creates many PID/heartbeat files.
- **Confidence and freshness:** High.

### Feature: Locking and namespace reservations (`SalmonRun.Locking`)

- **Intent / user outcome:** File and namespace locking for multi-agent safe queues.
- **Current score:** 75%
- **Current behavior:** `Lock-File`, `Unlock-File`, `Register-Namespace`, `Remove-NamespaceReservation` are implemented. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Locking/`, `Orchestrator/Tests/SalmonRun.Locking.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Locking.Property.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.Locking/`
- **Tests and test gaps:** Passing. No distributed/concurrency stress test.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Stress tests with concurrent agents.
- **Next smallest decision/build slice:** Add concurrency property test.
- **Confidence and freshness:** High.

### Feature: Workflow events (`SalmonRun.WorkflowEvents`)

- **Intent / user outcome:** JSONL event journal with monotonic IDs and namespace logs.
- **Current score:** 80%
- **Current behavior:** `Write-WorkflowEvent`, `Get-WorkflowEvents`, `Write-NamespaceLog`, `Get-NamespaceLog` work and are tested.
- **Evidence:** `Orchestrator/Modules/SalmonRun.WorkflowEvents/`, `Orchestrator/Tests/SalmonRun.WorkflowEvents.Tests.ps1`, `Orchestrator/Tests/SalmonRun.WorkflowEvents.Mutation.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.WorkflowEvents/`
- **Tests and test gaps:** Passing.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Long-running integration test; log rotation/retention.
- **Next smallest decision/build slice:** Add log rotation.
- **Confidence and freshness:** High.

### Feature: Process invocation (`SalmonRun.Process`)

- **Intent / user outcome:** Safe `cmd`/`docker`/`aws` invocation with result objects, recoverable errors, and credential swap.
- **Current score:** 75%
- **Current behavior:** `Invoke-NativeCommand`, `Invoke-Docker`, `Invoke-AwsCommand`, `Test-NativeCommandResult`, `Invoke-WithCredentialSwap` are implemented. Tests pass.
- **Evidence:** `Orchestrator/Modules/SalmonRun.Process/`, `Orchestrator/Tests/SalmonRun.Process.Tests.ps1`, `Orchestrator/Tests/SalmonRun.Process.Property.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.Process/`
- **Tests and test gaps:** Passing. No live AWS/Docker integration tests in this appraisal.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** `Invoke-AwsCommand` writes temp credentials to `~/.aws/credentials`; values are not logged.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Live Docker and AWS contract tests.
- **Next smallest decision/build slice:** Add a Docker command test in CI.
- **Confidence and freshness:** High.

---

## 6. Quality, documentation, and auxiliary modules

### Feature: Agentic Quality Engineering (`SalmonRun.AQE`)

- **Intent / user outcome:** Provide a public AQE runner: Pester suite, documentation lint, and optional AQE bridge.
- **Current score:** 70%
- **Current behavior:** `Invoke-SalmonRunAQE`, `Invoke-SalmonRunPesterSuite`, `Invoke-SalmonRunDocLint`, `Invoke-SalmonRunAQEBridge` are implemented. Doc lint passes on current docs. Bridge is optional and skips when `SALMON_AQE_BRIDGE_URI` is not set.
- **Evidence:** `Orchestrator/Modules/SalmonRun.AQE/`, `Orchestrator/Tests/SalmonRun.AQE.Tests.ps1`.
- **Source files / ownership:** `Orchestrator/Modules/SalmonRun.AQE/`
- **Tests and test gaps:** Passing. No live bridge test.
- **Deployment/runtime status:** Can run Pester and doc lint locally.
- **Security/compliance/operations status:** No credentials unless bridge is configured.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** AQE bridge integrated and tested; mutation/property test harness wired.
- **Next smallest decision/build slice:** Add contract test for `Invoke-SalmonRunDocLint` against a doc with known broken reference.
- **Confidence and freshness:** High.

### Feature: Documentation lint (`Invoke-DocLint`)

- **Intent / user outcome:** Verify that `docs/`, `AGENTS.md`, and `Skills/**/*.md` do not contain broken file path references.
- **Current score:** 85%
- **Current behavior:** `Skills/Documentation/Scripts/Invoke-DocLint.ps1` scans markdown and reports broken refs. Test reports `Documentation Lint: PASS; Scanned: 4 files, 0 broken refs`.
- **Evidence:** `Skills/Documentation/Scripts/Invoke-DocLint.ps1`, `Orchestrator/Tests/SalmonRun.AQE.Tests.ps1`.
- **Source files / ownership:** `Skills/Documentation/Scripts/Invoke-DocLint.ps1`
- **Tests and test gaps:** One passing test. No negative test with a deliberately broken reference.
- **Deployment/runtime status:** Runs as part of AQE.
- **Security/compliance/operations status:** No credentials.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Negative test; runs in CI on every doc change.
- **Next smallest decision/build slice:** Add a negative test.
- **Confidence and freshness:** High.

### Feature: GitCloud push helpers (`SalmonRun.GitCloud`)

- **Intent / user outcome:** Abstract token resolution and authenticated pushes for GitHub and Worktree.
- **Current score:** 65%
- **Current behavior:** Modules for token selection, CI run status, repo secret setting, and push are implemented. Tests exist but were not exercised against live hosts in this appraisal.
- **Evidence:** `Skills/Docker/Modules/SalmonRun.GitCloud/`, `Skills/Docker/Tests/SalmonRun.GitCloud.Tests.ps1`.
- **Source files / ownership:** `Skills/Docker/Modules/SalmonRun.GitCloud/`
- **Tests and test gaps:** Tests pass (assuming no live calls). No live contract test.
- **Deployment/runtime status:** Local tests.
- **Security/compliance/operations status:** Token resolution design avoids logging values; needs live verification.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** N/A
- **Acceptance criteria for 100%:** Live pushes and CI status checks against both GitHub and Worktree.
- **Next smallest decision/build slice:** Add a contract test that pushes to a test repo.
- **Confidence and freshness:** Medium.

### Feature: Mermaid repository chunking

- **Intent / user outcome:** Split repository documentation and diagrams into model-ingestible chunks.
- **Current score:** 0%
- **Current behavior:** Mentioned only in `README.md`. No code, tests, or design documents found.
- **Evidence:** Grep for `Mermaid|mermaid|chunk` returns only `README.md` line 4.
- **Source files / ownership:** N/A
- **Tests and test gaps:** None.
- **Deployment/runtime status:** Not implemented.
- **Security/compliance/operations status:** N/A
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Product decision on chunking strategy and output format.
- **Acceptance criteria for 100%:** Implementation, tests, and integration with an intake or planning pond.
- **Next smallest decision/build slice:** Write a plan document describing what should be chunked and how.
- **Confidence and freshness:** High; it is absent.

---

## 7. Test, build, and operational readiness

### Feature: Automated test suite

- **Intent / user outcome:** Fast feedback on regressions across all modules.
- **Current score:** 60%
- **Current behavior:** 19 Orchestrator test files and 6 Skills/Docker test files. Full `Orchestrator/Tests` run: **365 passed, 25 failed, 3 skipped, 1 BeforeAll failed, 1 container failed**. The `Skills/Docker/Tests` were not run in this appraisal because the `Invoke-Pester` call targeted `Orchestrator/Tests`.
- **Evidence:** Test run output; `Orchestrator/Tests/` and `Skills/Docker/Tests/`.
- **Source files / ownership:** `Orchestrator/Tests/`, `Skills/Docker/Tests/`
- **Tests and test gaps:** Two whole module test containers (`Audit`, `Credentials`) fail to load. One `PondEngine` dependency test fails. Process property tests emit many `[FAIL] Native command failed` messages; the final test passed but the output is noisy and may hide real issues.
- **Deployment/runtime status:** Tests run locally. Not integrated with CI in the public package (no `.github/workflows`, no `.worktree/workflows`).
- **Security/compliance/operations status:** No credentials in tests.
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Module load ordering and the break/continue label error must be fixed before the suite is trustworthy.
- **Acceptance criteria for 100%:** All tests green; CI gate runs `Orchestrator/Tests` and `Skills/Docker/Tests`; test run time under 5 minutes (currently ~160s for Orchestrator alone, acceptable but will grow).
- **Next smallest decision/build slice:** Fix `SalmonRun.Audit` and `SalmonRun.Credentials` load errors; then fix the `PondEngine` `DependsOn` test.
- **Confidence and freshness:** Medium; failure count is concrete.

### Feature: Continuous integration / packaging

- **Intent / user outcome:** Build, test, and package the public `salmon-run` release automatically.
- **Current score:** 10%
- **Current behavior:** No CI workflow files, no `Dockerfile`, no `docker-compose.yml`, no `psd1` packaging script, no PowerShell Gallery manifest. `package.json` exists but only defines npm scripts that call PowerShell.
- **Evidence:** Repo root listing; no `.github`, `.worktree`, or `Infrastructure/Docker` build files.
- **Source files / ownership:** N/A
- **Tests and test gaps:** N/A
- **Deployment/runtime status:** Not deployable as a package.
- **Security/compliance/operations status:** N/A
- **Shared-module reuse or divergence:** N/A
- **Dependencies and blockers:** Requires build/publish decision.
- **Acceptance criteria for 100%:** CI runs Pester, doc lint, and leak check; builds an installable package; publishes artifacts.
- **Next smallest decision/build slice:** Add a GitHub/Worktree Actions workflow or a local `build.ps1`.
- **Confidence and freshness:** High; absent.

---

## Contradictions and stale claims

1. **README claims a single-command installer.** `install.ps1` is a stub and does not install modules. This is a stale/contradictory claim.
2. **README mentions Mermaid repository chunking.** No implementation exists.
3. **`Sync-FromCanonical.ps1` is documented as the projection tool but contains a hardcoded private path.** It cannot be used by a public consumer and would itself leak the canonical repo path if included in a release.
4. **The `Local.ps1` executor is a public-safe stub but does not propagate failure.** It calls `ExternalPublicSafe.ps1` with `&` and no `exit $LASTEXITCODE`, so it returns 0 even though the child writes `.failed`. This masks real provider failures.
5. **`salmon-run` claims to be the public package, but the canonical orchestrator entry point (`deploy.ps1`) is absent.** The package has modules but no top-level service/runner.

## Unknowns

- Root cause of the `break`/`continue` label error in `SalmonRun.Audit` and `SalmonRun.Credentials` (a `4c-bugfix` pass is needed).
- Why the `PondEngine` `DependsOn` test fails when the matching logic appears correct.
- Whether the `Skills/Docker/Tests` suite also has failures.
- The intended public release artifact format (zip, PowerShell module, Docker image, pip/uv package).
- Which external agent providers are meant to ship in v1.

## Overall production readiness

The public `salmon-run` package is approximately **40–45% production-ready for its vision**.

- **What works:** Pond definitions, the core engine loop, model profile resolution, the `PublicLocal` smoke-test executor, file transitions, retry logic, rescue/capacity, archive, agent lifecycle, locking, workflow events, process invocation, config handling, doc lint, and most of the module architecture.
- **What is broken/incomplete:** The installer, real provider executors, module load order, the `Audit` and `Credentials` modules (cannot load in tests), the `DependsOn` gating test, Mermaid chunking, CI/packaging, and the top-level orchestrator runner.

Before any public release, the highest-confidence blockers are:

1. Make `install.ps1` actually install and validate the package.
2. Fix module `RequiredModules` / `PSModulePath` resolution so modules load in a clean session.
3. Fix the `break`/`continue` label error blocking `SalmonRun.Audit` and `SalmonRun.Credentials`.
4. Fix the `PondEngine` `DependsOn` gating failure.
5. Replace or document the external provider stubs.
6. Add CI, packaging, and a top-level runner.
