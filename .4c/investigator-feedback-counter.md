# 4C: Recurring feedback failures spawn an Investigator

## Concern

The Salmon Run engine is designed so that a failed Review/Audit/QA plan stays
parked in its failing pond and produces a focused feedback plan in the Code
queue. The user observed that if this cycle happens repeatedly, the engine is
effectively treating "run Code a few more times" as the success model, rather
than fixing the underlying instructions or session-plan design so the Coder
succeeds on the first run.

A regression reproduction test was added:

`Tests/SalmonRun.PondEngine.Investigator.Tests.ps1`

- `increments the counter when a failing Review plan produces feedback`
- `spawns a single Investigator plan when the counter reaches an even number`
- `does not spawn a second Investigator while one is already pending`
- `clears the pending flag when an Investigator plan transitions`

## Cause

Root cause analysis (5 Whys):

1. **Why do plans cycle through Code multiple times?**
   - Review/Audit/QA failures generate a feedback plan and leave the original
     blocked, but no process is triggered to fix the systemic reason the
     feedback was produced.

2. **Why is there no systemic fix loop?**
   - The engine only had per-pond agents (coder, reviewer, auditor, qa). There
     was no role whose job is to look across recent feedback and improve the
     engine / prompts / session-plan templates themselves.

3. **Why does the Coder not fix the root cause on the first feedback?**
   - The Coder prompt allowed the agent to append `**Implementation**: completed`
     without explicitly passing every rubric item and running the relevant
     tests, and without addressing the root cause in the Code prompt or session
     plan templates.

4. **Why do session plans require repeated rework?**
   - Session plans can be printed with vague scope or missing acceptance
     criteria, so the Coder has to discover the real requirements during
     Review/Audit/QA.

5. **Why is the failure pattern not visible to the engine?**
   - There was no persistent counter or ledger tracking how often a plan family
     has produced a backward feedback transition, and no threshold for
     escalating to a meta-level fix.

Anti-pattern search:

- `Invoke-PondTaskTransition.ps1` already created a `New-PondFeedbackPlan` on
  every quality failure but never escalated.
- The executor role `ValidateSet` in every executor excluded `investigator`.
- `Get-SalmonRunPonds.ps1` had no `Investigate` pond.
- `plan-header-schema.json` had no `InvestigatorDecision` / `Investigated`
  headers and no `investigate` PondLog action.

## Countermeasure

Implemented a persistent, idempotent feedback-failure counter and Investigator
spawn mechanism.

Files changed:

- `Modules/SalmonRun.PondEngine/Private/Investigator.ps1` (new)
  - `Get-PondFeedbackFailureCounter` / `Set-PondFeedbackFailureCounter`
    read/write a JSON counter under the runtime `Logs` directory, keyed by
    `TaskRoot` so test runs cannot cross-contaminate.
  - `Invoke-PondInvestigatorSpawn` increments the counter on every feedback
    failure from `Review`, `Audit`, `QA`, or `Code` and, when the counter hits
    an even number greater than zero, spawns a single `Investigate` plan while
    suppressing duplicates via a pending flag and on-disk check.
  - `New-PondInvestigatorPlan` creates a ready `Investigate` plan that points
    the Investigator at the `Code` prompt, project-plan templates, and recent
    feedback plans.
  - `Clear-PondInvestigatorPending` is invoked when an `Investigate` plan
    transitions, so the next even threshold can spawn again.

- `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`
  - Calls `Invoke-PondInvestigatorSpawn` after `New-PondFeedbackPlan`.
  - Calls `Clear-PondInvestigatorPending` at the end of an `Investigate`
    transition.

- `Modules/SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1`
  - Added an `Investigate` pond with role `investigator`.

- `Modules/SalmonRun.PondEngine/Config/plan-header-schema.json`
  - Added `InvestigatorDecision`, `Investigated`, `PlanType: investigation`,
    and `investigate` PondLog action.

- `Modules/SalmonRun.PondEngine/Executors/PondVerdict.ps1`
  - Added `investigator` verdict contract (`Investigated` / `InvestigatorDecision`).

- `Modules/SalmonRun.PondEngine/Executors/*.ps1`
  - Re-added `investigator` to `ValidateSet` and role-specific prompts for
    OpenCode, Codex, Devin, DSH, and the local mock executors.

- `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`
  - Tightened the Coder prompt to require every rubric item to pass and the
    relevant tests to exit 0 before appending `**Implementation**: completed`.
  - Added an `investigator` prompt that directs the agent to improve the
    engine, the Coder prompt, and the session-plan templates.

- `Modules/SalmonRun.PondEngine/Private/Get-PondFileNamespace.ps1`
  - Fixed a latent bug in `Get-PondFilePlanSequence`:
    `$Matches[1].Value` was invalid for a regex capture; changed to
    `$Matches[1]`.

- `Tests/SalmonRun.PondEngine.Investigator.Tests.ps1` (new)
  - Regression coverage for the counter and idempotent spawn behavior.

- `Tests/SalmonRun.PondEngine.Tests.ps1`
  - Updated the expected pond list to include `Investigate`.

- `.4c/orchestrator-functional-recovery.md`
  - Removed a literal Windows local path so the public package leak check passes.

## Check

- `Invoke-Pester -Path Tests` passed:

  ```text
  Tests Passed: 650, Failed: 0, Skipped: 8, Inconclusive: 0, NotRun: 0
  ```

- Documentation lint (`Tools/Documentation/Scripts/Invoke-DocLint.ps1`) passed.
- `scripts/Invoke-LeakCheck.ps1` reports no private references.
- New focused tests `SalmonRun.PondEngine.Investigator.Tests.ps1` pass.
- Existing `SalmonRun.PondEngine.Feedback.Tests.ps1` still passes.
