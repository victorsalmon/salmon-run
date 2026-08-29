# 4C — Coder ignores review/QA feedback on rework

## Concern

When Review or QA rejects a plan, the file is moved back to `Tasks/Code/` but the
Coder agent is not explicitly instructed to read the failure evidence.  Review
and QA only append a single legacy evidence line such as `**Reviewed**: failed
by ... - <reason>`.  The Coder prompt then says simply:

> "Implement the plan in the target repository."

It does not tell the Coder to scan for prior `Reviewed`, `Audit`, or `QA`
failures, nor to treat them as the primary rework specification.  The result is
that a plan can circulate `Code -> Review -> Code -> Review` without the Coder
actually fixing the reported gaps.  The live queue data shows this happening:
`Review` drains to a small backlog while `Code` grows, and individual plan files
contain multiple `review` actions with the same failure reason repeated.

Repro test:

- `Tests/SalmonRun.PondEngine.Feedback.Tests.ps1`
- Red commit: `ead1a4c` (test fails before the fix)
- Green commit: `8cabf3e` (test and full suite pass after the fix)
- Files:
  - `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`
  - `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskTransition.ps1`

## Cause

1. **The Coder role prompt has no feedback-reading contract.**
   `Get-OpencodeRolePrompt` in `Opencode.ps1` gives the Coder a generic
   "implement the plan" instruction.  It never mentions `Feedback for Coder`,
   `FixActions`, or the failed evidence headers.

2. **Failure-producing roles are not asked to write structured feedback.**
   The Reviewer/QA/Auditor prompts request only a one-line `**Reviewed**: failed`
   (or `**QA**: failed`, `**Audit**: failed`) line.  There is no `## Feedback for
   Coder` section, no `FailedChecks`, and no `FixActions` list for the Coder to
   follow.

3. **`Invoke-PondTaskTransition` does not synthesize a feedback block from the
   legacy evidence line.**  When the failure reason is a single prose sentence,
   it is hard for the Coder to extract a checklist.  A transition-time rewrite
   would make every plan that returns to `Code` carry a consistent, semantic
   feedback block.

4. **Sibling bug: the Reviewer and Auditor prompts contain a literal ` `r` to
   escape the role name in backticks, but in a double-quoted here-string ` `r`
   is interpreted as a carriage return.  This corrupts the instructions sent to
   those agents.**

## Countermeasure

1. Update `Get-OpencodeRolePrompt` in `Opencode.ps1`:
   - For `reviewer`, `auditor`, and `qa`, require a `## Feedback for Coder`
     section with `Source`, `Verdict`, `FailedChecks`, and `FixActions` when
     failing.
   - For `coder`, instruct the agent to read `## Feedback for Coder` and any
     failed `**Reviewed**` / `**QA**` / `**Audit**` / `**Implementation**`
     header, and to treat the `FixActions` list as the primary task list.
   - Fix the ` `r` escape bug and align pass wording.

2. Update `Invoke-PondTaskTransition` to automatically append a `## Feedback for
   Coder` block from the failed legacy evidence line when one is missing, so
   existing and future failure styles both produce structured feedback.

3. Add regression tests for the new prompt and transition behavior.

## Check

- Red reproduction: `SalmonRun.PondEngine.Feedback.Tests.ps1` failed before the
  fix (6 failures against the old prompts).
- Green reproduction: the same test file passes after the prompt/transition
  changes (`passed=6 failed=0`).
- Full Pester portfolio: **646 passed, 0 failed, 8 skipped**.
- Documentation lint: **PASS** (12 files, 0 broken refs).
- Leak check: **No private references found**.
- Property/mutation: existing `PondEngine.Mutation` contract test passes; the
  new `SalmonRun.PondEngine.Feedback.Tests.ps1` uses data-driven cases to act as
  the teeth/property guard.
