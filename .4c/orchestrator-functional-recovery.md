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

Pending.

## Check

Pending.
