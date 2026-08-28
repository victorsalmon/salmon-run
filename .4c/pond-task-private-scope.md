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
- Pending Cause gate.

## Check
- Pending Countermeasure gate.
