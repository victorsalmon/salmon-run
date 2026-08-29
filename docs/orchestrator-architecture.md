# Orchestrator architecture

Salmon Run uses markdown plans as a validated workflow protocol. The primary
path is:

`Project -> Code -> Review -> Audit -> QA (project batch) -> Complete children -> ProjectReview -> Complete/<ProjectId>/`

## Planning

`New-SalmonProjectPlan -Concept ...` prints a structured plan into
`~/.salmon/Tasks/Project`. The Project pond emits substantive session plans.
Each session declares `EstimatedImplementationTokens` and the decomposer clamps
the value to the hard 100,000-token ceiling; 70,000 is the default target.

## Review, feedback, and Investigator

Provider exit code means only that the agent process ran. Review, Audit, QA, and
ProjectReview also require an explicit passing verdict. A failed Review creates
`Tasks/Feedback/<plan>-review.md`, records `ReviewDecision`, `ReviewSummary`,
`ReviewFeedbackFile`, and `ReviewedPlan` on the plan, then returns it to Code.
Review is read-only and may use three concurrent operators.

Each time a plan is routed back to `Code` from `Review`, `Audit`, `QA`, or the
Code feedback path, a persistent `~/.salmon/Logs/feedback-failure-counter.json`
counter is incremented. When the counter reaches an even value greater than zero,
one `Investigate` plan is idempotently spawned into `Tasks/Investigate`. The
`investigator` role runs a focused root-cause pass, tightens the Coder prompt and
project-plan templates, runs focused and full Pester suites, and clears the
`investigatorPending` flag when the plan transitions.

## Batched QA

Reviewed and audited children collect in `Tasks/QA`. The QA entry gate compares
that set with the parent's exact `DependsOn` list. No child is claimed until the
whole project batch is present. The batch is grouped by `ProjectId`, so property
tests and mutation testing run once against the integrated project rather than
once per session plan.

## Parallel safety

`ParallelCount` is a global pond limit across worktree streams. Code, Audit, and
QA are writer roles and schedule at most one active group per underlying target
repository. Review is read-only and scales independently. Git commit/push mutexes
remain a final serialization layer.

## Project completion

The parent waits in ProjectReview until all declared children are Complete. The
final reviewer considers the project as a whole. On pass, Salmon Run creates:

```text
Tasks/Complete/<ProjectId>/
  project.md
  manifest.json
  plans/*.md
  feedback/*
  qa/*
```

The manifest records planned/code/review counts and QA/project-review milestones.
The project does not enter this folder until the final review passes.

## Recovery and test containment

At each engine iteration, dead lane directories are recovered to the pond named
by their role; lanes with live PIDs are never touched. The canonical acceptance
runner pins `SALMON_RUN_HOME` to a temporary directory for the entire test run so
test fixtures cannot enter the live queue.

## Runtime hygiene for the watchdog

The unattended `Run-SalmonRun.ps1` watchdog spawns `Start-SalmonRun.ps1` as a
separate `pwsh` process. Because the child uses module auto-loading, a stale user
`PSModulePath` containing `Pester_*/Modules` entries can cause an incorrect
`SalmonRun.PondEngine` module to load and produce `Unable to find type [PondGroup]`.
Before starting the watchdog, clear the user `PSModulePath` of any stale temp
entries and ensure `SALMON_RUN_HOME` points to the intended runtime home.

