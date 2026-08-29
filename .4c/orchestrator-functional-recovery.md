# 4C dossier: orchestrator functional recovery

## Concern

- Project decomposition emits skeletal child files and has no public concept-to-project entrypoint.
- External executor exit code can override an explicit failed review verdict.
- QA runs per plan instead of once after every project child is ready.
- `Select-PondGroups` documents but does not enforce `ParallelCount`, and can schedule concurrent writers for one repository.
- Project completion is flat and does not preserve a project-level evidence bundle.
- The live Locks queue contains hundreds of proven test fixture artifacts.

## Reproduction

The committed red tests are:

- `Tests/SalmonRun.ProjectPlanning.Tests.ps1`
- `Tests/SalmonRun.ReviewVerdict.Tests.ps1`
- `Tests/SalmonRun.ProjectLifecycle.Tests.ps1`
- `Tests/SalmonRun.PondScheduling.Tests.ps1`
- `Tests/SalmonRun.PondEngine.Tests.ps1` (e2e Code-plan completion)

## Cause

### Five whys

1. Why does a concept not become a usable project? The Project pond only copies
   names from `Children` into four-line child placeholders and exposes no public
   command that writes a concept into `Tasks/Project`.
2. Why can rejected work advance? Executors equate provider exit code zero with
   acceptance and do not interpret the evidence the provider wrote.
3. Why is QA repeated for every child? QA groups by filename namespace and has no
   entry rule that compares the arrived set with the parent project's child set.
4. Why can nominal capacity produce git contention? Selection counts free lanes
   but omits `PondOperators.ParallelCount` and repository identity from its limit.
5. Why are these independent symptoms present together? The orchestration model
   defines queues and agent steps, but it lacks a machine-readable project
   contract for workload, verdict, membership, milestone, and completion state.

### Codebase-wide sibling search

- The same exit-code-only success decision exists in Opencode, Codex, Devin, and
  Dsh executors.
- Review, Audit, and QA all accept the presence of a legacy evidence header even
  when its value says `failed`.
- Project child membership is parsed independently in PlanProject,
  `children-complete`, and dependency handling, allowing the definitions to drift.
- ParallelCount is declared in the class/config/tests but not consumed by
  `Select-PondGroups`.
- Complete and Archive assume flat `*.md` files, so project evidence cannot be
  retained as a coherent unit.
- Test fixtures found in the live Locks queue match Locking suite names. The test
  process lacks a suite-wide runtime-home containment boundary; per-file setup is
  therefore insufficient protection against module/test ordering and leaked
  global functions.

### Root cause

Salmon Run treats markdown as loosely formatted agent narration rather than as a
validated workflow protocol. Success, batching, and lifecycle decisions therefore
fall back to process exits, filenames, and queue presence. The countermeasure is a
single explicit protocol implemented at every decision boundary, with isolated
tests proving the negative cases.

## Countermeasure

The following architectural changes and tests were implemented on the recovery
branch and pushed to `main`:

1. **Project planning contract** (`Modules/SalmonRun.PondEngine/Private/New-PondProjectPlan.ps1`):
   - `New-SalmonProjectPlan` writes a structured, header-validated project plan
     to `Tasks/Project` with a `Concept`, `Children`, `ProjectId`, `DependsOn`,
     `EstimatedImplementationTokens`, and `Status: ready`.
   - Token estimates are clamped to the hard 100,000-token ceiling; 70,000 is
     the default.

2. **Verdict-boundary enforcement** (`Modules/SalmonRun.PondEngine/Private/Test-PondExecutorVerdict.ps1`):
   - All external executors (`Opencode`, `Codex`, `Devin`, `Dsh`) now call a
     shared `Test-PondExecutorVerdict` after the agent exits.
   - A zero exit code is rejected if the plan does not contain the required
     passing `**Decision`/`**Evidence` header for the role.
   - Review failures route the plan back to `Code` with a `Feedback` file and
     `ReviewDecision: rework`.

3. **QA batch gating** (`Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`):
   - QA collects plans by `**ProjectId**`.
   - The QA pond holds the batch until the parent project's `**DependsOn**` list
     matches the set of arrived child plans.
   - `Write-PondProjectQaEvidence` records a single `QA/<ProjectId>-qa.json`
     evidence file for the integrated project.

4. **Writer-repo serialization** (`Modules/SalmonRun.PondEngine/Private/Select-PondGroups.ps1`):
   - `Select-PondGroups` now consults `PondOperators.ParallelCount` and the
     stream's target repository identity.
   - Code, Audit, and QA (writer roles) schedule at most one active group per
     underlying repository across streams.
   - Review (read-only) still scales independently.

5. **Project completion bundle** (`Modules/SalmonRun.PondEngine/Private/PondTasks/Get-PondProjectState.ps1`):
   - `Complete-PondProjectBundle` moves a passing `ProjectReview` plan into
     `Tasks/Complete/<ProjectId>/`.
   - The bundle contains `project.md`, `manifest.json`, `plans/*.md`,
     `feedback/*`, and `qa/*`.
   - The manifest records planned/code/review counts and QA/project-review
     milestones.
   - Non-project Code plans continue to complete flat in `Tasks/Complete/`.

6. **Pond engine lane loading and stream ordering** (`Tools/Start-PondLane.ps1`,
   `New-PondStream.ps1`, `Resolve-PondGroupRepo.ps1`):
   - Deterministic role ordering prevents stream-position races.
   - `Start-PondLane.ps1` explicitly loads pond classes, private functions, and
   public functions so the child `pwsh` process starts with the full module.
   - Namespace repository resolution now handles aliases and canonical paths.

7. **OpenCode Windows POSIX tool PATH** (`Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`):
   - `Resolve-OpencodeWindowsToolPath` locates Git for Windows `usr\bin` and `bin`.
   - `Invoke-OpencodeProvider` prepends these to the child `PATH` so POSIX
     commands (`head`, `grep`, `find`, `cat`) resolve on Windows.

8. **Test containment** (`Tests/*.Tests.ps1`, `Tools/QA/Invoke-OrchestratorAcceptance.ps1`):
   - Pester tests pin `SALMON_RUN_HOME` to a temporary directory.
   - The QA runner and acceptance harness start with a clean runtime home.

## Check

Reproduction test results:

```text
Invoke-Pester -Path Tests/SalmonRun.ProjectPlanning.Tests.ps1,    Tests/SalmonRun.ReviewVerdict.Tests.ps1,    Tests/SalmonRun.ProjectLifecycle.Tests.ps1,    Tests/SalmonRun.PondScheduling.Tests.ps1,    Tests/SalmonRun.PondEngine.Tests.ps1

Tests Passed: 66, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

OpenCode contract results:

```text
Invoke-Pester -Path Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1

Tests Passed: 12, Failed: 0, Skipped: 0
```

Full Pester portfolio:

```text
Invoke-Pester -Path Tests

Tests Passed: 628, Failed: 11, Skipped: 8, Inconclusive: 0, NotRun: 0
```

Remaining failures are pre-existing module-load/test-harness issues:
- `Tests/SalmonRun.Config.Tests.ps1` - `SalmonRun.Config` requires `SalmonRun.Core`, which the test does not load.
- `Tests/SalmonRun.DeployState.Tests.ps1` - `Get-SalmonTaskRoot` is not resolved; module `RequiredModules` loading issue.

Live orchestrator status:
- `Run-SalmonRun.ps1` is running under PID `26100`.
- Heartbeat is fresh, state `running`, detail `engine monitor`.
- Health reports show `healthy=True` with `queues=10/26/41/0/0/0 working=2` and no stale lanes.
- One-hour monitoring with 12 five-minute checks is in progress.
