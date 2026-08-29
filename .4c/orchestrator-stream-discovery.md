# 4C — Orchestrator not dispatching lanes (stream discovery / ProjectId fallback)

## Concern

Salmon Run was alive (`healthy=True`, heartbeat fresh) but not productive.  A
controlled verbose run of `Start-SalmonRun` showed every dispatchable group
being rejected with `POND_NO_STREAM`, and the queue counts stayed flat across
checks:

- `Intake`: `smoke-test` selected → `POND_NO_STREAM`
- `QA`: `2026.08.26-uh-signing-1-pkcs7-tamper-evidence` selected → `POND_NO_STREAM`
- `ProjectReview`: `upscale-havens` selected → `POND_NO_STREAM`
- `Complete` archive ran but found no plans older than 7 days

Pester red-gate reproduction:

- `Tests/SalmonRun.PondEngine.StreamDiscovery.Tests.ps1`
- Red commit: `dd2a773`
- Green commit: `bbf73bf`

## Cause

Two independent invariants were violated:

1. **Stream discovery only covered four of the agentic ponds.**
   `Get-PondWorktreeStreams` scanned `Code`, `Review`, `Audit`, and `QA`, but
   not `Intake` or `ProjectReview`.  Agentic plans in those queues could create a
   `PondGroup`, but `Get-StreamForGroup` never found a matching worktree, so the
   engine emitted `POND_NO_STREAM` and moved on.

2. **`ProjectId` grouping fell back to the whole filename.**
   `Group-PondFiles` for `GroupBy -eq 'ProjectId'` used the `**ProjectId**`
   header when present, but for standalone plans with no `**ProjectId**` it fell
   back to `$_.BaseName` (e.g.
   `2026.08.26-uh-signing-1-pkcs7-tamper-evidence`).  That name does not match
   the `uh-signing` worktree stream discovered from `QA`/`Code`, so QA plans also
   hit `POND_NO_STREAM`.

The diagnostic script only showed a correctly-scoped `PondContext` could
*select* work; it did not reveal that the selected groups had wrong namespaces or
that the stream-scanner ignored two queues.  The real `Start-PondEngine` verbose
output exposed both issues.

## Countermeasure

- `Modules/SalmonRun.PondEngine/Private/Get-PondWorktreeStreams.ps1`
  - Added `Intake` and `ProjectReview` to the queue scan list so all agentic
    ponds can seed a worktree stream.

- `Modules/SalmonRun.PondEngine/Private/Group-PondFiles.ps1`
  - When `GroupBy -eq 'ProjectId'` and no `**ProjectId**` header is present, fall
    back to `Get-PondFileNamespace -FileName $_.Name` instead of `$_.BaseName`.
    This keeps standalone QA/planner plans grouped by the same connascence
    namespace that stream discovery uses.

## Check

- Red reproduction: `Tests/SalmonRun.PondEngine.StreamDiscovery.Tests.ps1` failed
  with the original code.
- Green reproduction: the same test file passes after the fix.
- Live restart: `Run-SalmonRun.ps1` spawned three lanes immediately after the
  change (`lane-planner-smoke-test-*`, `lane-qa-uh-signing-*`,
  `lane-project-reviewer-upscale-havens-*`) and claimed `Intake`, `QA`, and
  `ProjectReview` plans.
- Monitoring: 12 five-minute health checks completed; no stalls, healthy=True at every check.
