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

## Cause

Pending red-gate execution and codebase-wide analysis.

## Countermeasure

Pending.

## Check

Pending.

