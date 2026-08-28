# pond-task-private-scope - 4C Bug Fix
**Repo:** salmon-run - main   **Started:** 2026-08-28

## Concern
- Failure in one sentence: When `Start-PondLane.ps1` runs an agentic pond in a child PowerShell process, it cannot resolve private pond-task functions such as `Invoke-PondTaskPrepare`, so the lane fails instead of processing its plan.
- Live reproduction: `~/.salmon/Tasks/Working/lane-coder-*/lane-error.log` reports `POND_TASK_NOT_FOUND pond=Code task=Prepare function=Invoke-PondTaskPrepare` for three concurrent Code lanes.
- Repro test: `Tests/SalmonRun.PondEngine.Tests.ps1#exports a module-scoped child-lane pipeline entrypoint` (RED commit to be recorded).
- Repro run output (RED): Pester 6.1.0 reported `Expected 'Invoke-PondLanePipeline' to be found ... but it was not found` at test line 47. The same run had 43 passing and 7 failing tests; the other six failures included the existing Code-to-Complete and Project-to-Complete end-to-end tests, consistent with child lanes not executing their private tasks.
- Changed-behavior classification: state transition and process/module boundary. A claimed plan must either execute the complete pond pipeline or return through the configured failure transition; private module scope must not make valid task functions undiscoverable.

## Cause
- Pending RED gate.

## Countermeasure
- Pending Cause gate.

## Check
- Pending Countermeasure gate.
