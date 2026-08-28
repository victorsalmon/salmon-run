# pond-task-private-scope - 4C Bug Fix
**Repo:** salmon-run - main   **Started:** 2026-08-28

## Concern
- Failure in one sentence: When `Start-PondLane.ps1` runs an agentic pond in a child PowerShell process, it cannot resolve private pond-task functions such as `Invoke-PondTaskPrepare`, so the lane fails instead of processing its plan.
- Live reproduction: `~/.salmon/Tasks/Working/lane-coder-*/lane-error.log` reports `POND_TASK_NOT_FOUND pond=Code task=Prepare function=Invoke-PondTaskPrepare` for three concurrent Code lanes.
- Repro test: `Tests/SalmonRun.PondEngine.Tests.ps1#exports a module-scoped child-lane pipeline entrypoint` (RED commit to be recorded).
- Repro run output (RED): Pester 6.1.0 reported `Expected 'Invoke-PondLanePipeline' to be found ... but it was not found` at test line 47. The same run had 43 passing and 7 failing tests; the other six failures included the existing Code-to-Complete and Project-to-Complete end-to-end tests, consistent with child lanes not executing their private tasks.
- Property test: `Tests/SalmonRun.PondEngine.Tests.ps1#resolves every configured task through the child-lane module boundary`, seed `20260828` (RED before source repair).
- Changed-behavior classification: state transition and process/module boundary. A claimed plan must either execute the complete pond pipeline or return through the configured failure transition; private module scope must not make valid task functions undiscoverable.

## Cause
- 5-Whys: Code lanes fail because `Start-PondLane.ps1` cannot find `Invoke-PondTaskPrepare`; it cannot find it because the task implementations live in the PondEngine module's `Private/` tree and are intentionally absent from `FunctionsToExport`; the child runner nevertheless tries to resolve and invoke those private commands from script scope; that happens because the parent and child runners duplicate the string-based task-dispatch loop; the design defect is that execution of a module-owned pipeline crosses the module boundary instead of being owned by one exported module entrypoint.
- Root cause: `Start-PondEngine` safely resolves task functions while executing inside `SalmonRun.PondEngine`, but `Tools/Start-PondLane.ps1` duplicates that dispatcher outside the module. PowerShell correctly hides the private task commands, so every child pipeline containing a private task fails at its first such step. The missing invariant is: all pond task-name resolution and invocation occurs inside the module that owns the task implementations.
- Violated invariant: claiming work into a child lane must preserve a total state transition—each configured task is resolvable and the lane reaches either its configured success or failure transition; module visibility must not strand claimed work.
- Sibling occurrences of the anti-pattern:
  - `Tools/Start-PondLane.ps1:161-165` — external `Get-Command` and invocation of private task names; in scope and must be replaced.
  - `Modules/SalmonRun.PondEngine/Public/Start-PondEngine.ps1:382-388` — duplicate dispatcher, but it runs inside module scope and currently resolves correctly; in scope for consolidation so the two paths cannot drift again.

## Countermeasure
- Fix commits: `fc6d298` (module-owned dispatcher and pre-claim validation), `829e9cf` (restore in-process Local routing and its end-to-end contract), `ee17c57` (remove the public-package machine-path leak exposed by the full suite).
- Siblings fixed: both duplicated dispatch loops now call `Invoke-PondLanePipeline`; default pond task references are validated before queue mutation. Local plans bypass worktree-only dispatch. The machine-specific repo fallback was removed in favor of `orchestrator.config.json` mappings.

## Check
- Repro test now: GREEN. `exports a module-scoped child-lane pipeline entrypoint` and `resolves every configured task through the child-lane module boundary` both pass.
- Red-gate proof: test commit `52b7150` precedes fix commit `fc6d298`; before the fix Pester reported the missing export at test line 47 and the live lanes reported `POND_TASK_NOT_FOUND`.
- Property suite: seed `20260828`, GREEN. The invariant is checked across every configured pond in deterministic randomized order.
- TEETH proof: `rejects an unknown task before a lane can claim work` supplies a deliberately invalid task reference and confirms pre-claim validation rejects it. Existing Local Code, dependency, and multi-child Project end-to-end tests kill removal/inversion of the Local-routing guard.
- Edge cases: unknown task rejected; empty pipeline accepted; Local groups execute without a git worktree; planner lane count contract updated.
- Focused PondEngine suite: 53 passed, 0 failed (the earlier 51-test run was green before the final two edge cases were added; the full-suite run below includes all 53).
- Full suite: 621 passed, 0 failed, 8 skipped in 4m34s. Documentation lint and public leak checks passed.
- Mutation: no PondEngine source-mutation runner is configured in this repository. The invariant/TEETH tests above exercise equivalent broken implementations, but no numeric changed-file mutation score is available. This remains a QA-system gap and is not represented as a passing mutation portfolio.
- Blast-radius scan: the only external private-task dispatcher was `Tools/Start-PondLane.ps1`; the in-module duplicate in `Start-PondEngine.ps1` was consolidated. No unresolved occurrences remain.
- Quality scans: repository documentation lint and public-package leak scan passed. AQE bridge was not used; the local Pester and leak gates provided the available proof.
