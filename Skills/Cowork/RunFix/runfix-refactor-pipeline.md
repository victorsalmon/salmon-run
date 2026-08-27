# RunFix Refactor Pipeline

**Purpose**: Run `Skills/Refactor/Invoke-RefactorPipeline.ps1` iteratively — fixing prerequisite gaps, crashed phases, and infrastructure issues until the full 4-phase pipeline completes. The pipeline runs: RunFix audit-complete → RunFix localorchestrator → RunFix deploy → Catchall rescue loop.

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

---

## Configuration

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Skills/Refactor/Invoke-RefactorPipeline.ps1` |
| `$LOG_PREFIX` | `runfix-refactor-pipeline` |
| `$CHECKPOINT_RESUME` | `false` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `1440` |
| `$TIMEOUT_SECONDS` | `28800` |

### Flags to pass

```powershell
& 'Skills/Refactor/Invoke-RefactorPipeline.ps1' -MaxRuntimeMinutes 480 -MaxCatchallIterations 5
```

---

## Preflight

Before the first run, verify:

1. **opencode CLI available** — `Get-Command opencode` resolves.
2. **Pipeline script exists** — `Test-Path "Skills/Refactor/Invoke-RefactorPipeline.ps1"`.
3. **No stale pipeline PID** — `Test-Path "Tasks/Logs/.refactor-pipeline.pid"`. If the PID is alive, refuse to start a second instance. If stale, remove the file.
4. **Command templates registered** — `audit-complete`, `runfix`, `refactor-pipeline` all exist in `opencode.json.command`.
5. **RunFix goals files exist** — `runfix-audit-complete.md`, `runfix-localorchestrator.md`, `runfix-deploy.md` all exist under `Skills/Workflows/RunFix/`.
6. **Workspace state** — `git status --porcelain` clean. Warn if dirty but do not block.
7. **Docker available** — `docker info` succeeds (needed for Phase 3 deploy).
8. **AWS SSO session** — `aws sts get-caller-identity --profile <$env:AWS_SSO_PROFILE or "interclaw">` succeeds. If expired, refresh proactively.

---

## Rubrics

| Criterion | Passing condition |
|-----------|-------------------|
| Exit code | `$LASTEXITCODE -eq 0` |
| Final summary | Log contains `=== REFACTOR PIPELINE COMPLETE ===` |
| Phase 1 complete | Log contains `PHASE 1 STATUS: exit-0` |
| Phase 2 complete | Log contains `PHASE 2 STATUS: exit-0` |
| Phase 3 complete | Log contains `PHASE 3 STATUS: exit-0` |
| Catchall passed | Log contains `CATCHALL: All checks passed — pipeline complete` |
| No fatal error | Log does not contain `FATAL PIPELINE ERROR` or `FATAL PIPELINE CRASHED` |
| No iteration exceeded | Log does not contain `CATCHALL_ITERATIONS_EXCEEDED` |

### Verification

```powershell
function Invoke-RefactorPipelineRubrics {
    param([string]$OutputText, [string]$LogPath)
    $failures = @()

    # Check exit code
    if ($global:LASTEXITCODE -ne 0) {
        $failures += "Exit code $($global:LASTEXITCODE)"
    }

    # Check completion signal
    if ($OutputText -notmatch 'REFACTOR PIPELINE COMPLETE') {
        $failures += "Missing 'REFACTOR PIPELINE COMPLETE' in output"
    }

    # Check phase exit codes
    $logs = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
    if ($logs) {
        if ($logs -notmatch 'PHASE 1 STATUS: exit-0') { $failures += "Phase 1 did not exit 0" }
        if ($logs -notmatch 'PHASE 2 STATUS: exit-0') { $failures += "Phase 2 did not exit 0" }
        if ($logs -notmatch 'PHASE 3 STATUS: exit-0') { $failures += "Phase 3 did not exit 0" }
        if ($logs -notmatch 'CATCHALL: All checks passed') { $failures += "Catchall did not pass all checks" }
    } else {
        $failures += "Could not read pipeline log"
    }

    # Check for fatal crash
    if ($OutputText -match 'FATAL PIPELINE ERROR') {
        $failures += "Pipeline crashed with fatal error"
    }

    # Check for iteration exceeded
    if ($OutputText -match 'CATCHALL_ITERATIONS_EXCEEDED') {
        $failures += "Catchall max iterations exceeded — runfix may need to fix root cause"
    }

    return @{
        Passed   = $failures.Count -eq 0
        Failures = $failures
    }
}
```

---

## Error Table

| # | Error symptom | Root cause | Fix | Verification |
|---|---|---|---|---|
| 1 | Pipeline exits 1 during startup — `opencode CLI not found in PATH` | opencode not installed or PATH misconfigured | Install opencode or add PATH entry. Check: `npm install -g @opencode/cli` or verify PATH includes `%AppData%\npm` | `Get-Command opencode` |
| 2 | Pipeline exits 1 — `command template missing` | `audit-complete`, `runfix`, or `refactor-pipeline` not registered in `opencode.json` | Verify the command entries exist. If missing, re-add from the latest commit. | `Get-Content opencode.json -Raw \| ConvertFrom-Json \| Select-Object -ExpandProperty command` |
| 3 | `PHASE 1 STATUS: exit-N` with N != 0 | RunFix audit-complete failed — the complete audit's inner RunFix exited non-zero | Read `refactor-pipeline-*-phase1.out` for the audit RunFix exit message. Check `runfix-audit-complete` log for the specific failure. Common causes: stale draft dirs, missing command template, sub-agent timeout. Apply matching fix from `runfix-audit-complete.md` error table. | `Get-Content Tasks/Logs/refactor-pipeline-*-phase1.out -Tail 10` |
| 4 | `PHASE 2 STATUS: exit-N` with N != 0 | RunFix localorchestrator failed — the orchestrator's inner RunFix exited non-zero | Read `refactor-pipeline-*-phase2.out` for the orchestrator RunFix exit message. Check `runfix-localorchestrator` log for the specific rubric failure. Common causes: orchestrator crash-loop, stale PID file, file retry budget exhausted. Apply matching fix from `runfix-localorchestrator.md` error table. | `Get-Content Tasks/Logs/refactor-pipeline-*-phase2.out -Tail 10` |
| 5 | `PHASE 3 STATUS: exit-N` with N != 0 | RunFix deploy failed — the deploy's inner RunFix exited non-zero | Read `refactor-pipeline-*-phase3.out` for the deploy RunFix exit message. Check `runfix-deploy` log for the specific rubric failure. | `Get-Content Tasks/Logs/refactor-pipeline-*-phase3.out -Tail 10` |
| 6 | `CATCHALL_ITERATIONS_EXCEEDED` | Pipeline looped 5 times without all phases passing — catchall kept rescuing files but root cause not fixed | Read the pipeline log for which phase repeatedly failed. Apply `fix-diagnose` to the root cause. Common cases: infinite rescue loop (files keep reappearing in Tasks/Failed/), namespace collision not fixed (audit keeps generating wrong names), or orchestrator crash-loop not resolved. | `Select-String "CATCHALL" Tasks/Logs/refactor-pipeline-*.log` |
| 7 | Pipeline log shows `PHASE N TIMEOUT after X min` | Phase exceeded MaxRuntimeMinutes (default 480 min) | Increase `-MaxRuntimeMinutes` or check if the phase is legitimately taking longer than expected. For Phase 2 (orchestrator), check queue size: if 100+ files, more time is expected. | `Get-ChildItem "Tasks/Code/*.md" -ErrorAction SilentlyContinue \| Measure-Object` |
| 8 | `FATAL PIPELINE CRASHED` | An exception in the outer try/catch — unhandled error during pipeline execution | Read the log for the error message after `FATAL PIPELINE ERROR`. Common causes: disk full, permissions error writing log, JSON parse error. | `Get-Content "Tasks/Logs/refactor-pipeline-*.log" -Tail 20` |
| 9 | No pipeline log file created | Pipeline failed before logging initialized (pre-log initialization crash) | Run the pipeline script manually to see the error: `& "Skills/Refactor/Invoke-RefactorPipeline.ps1" -DryRun`. Likely causes: script not found, PowerShell version too old, execution policy blocked. | `$PSVersionTable.PSVersion` should be 7+ |

---

## Terminal Errors (Impassable Objects)

These errors are **not retried** — they indicate an unrecoverable condition.

| # | Symptom | Why it is terminal | What to report |
|---|---|---|---|
| 1 | 3 consecutive identical `CATCHALL_ITERATIONS_EXCEEDED` errors | The catchall loop keeps hitting max iterations with the same set of failures, meaning fixes are not effective. | `TERMINAL: Catchall loop failed 3 times with identical failures. Manual investigation required.` |
| 2 | `.refactor-pipeline-state.json` based resume not applicable | Pipelines now use RunFix for crash resume — if the pipeline script crashes, RunFix re-launches. If RunFix itself is broken (missing `fix-diagnose` command template or can't start), this is terminal. | `TERMINAL: RunFix engine unavailable. Check fix-diagnose command template and RunFix.ps1.` |
| 3 | All 3 retries fail with `opencode run --command runfix` returning non-zero exit | The opencode CLI `--command` flag is broken or version-mismatched. | Check the opencode version and PATH resolution. |

---

## TUI Crash Safety

The runfix engine runs inside the interactive opencode TUI. The pipeline is self-daemonizing via `-Detach` flag:

```powershell
& 'Skills/Refactor/Invoke-RefactorPipeline.ps1' -Detach
```

This re-launches in a hidden PowerShell window, survives TUI crashes, and writes logs to `Tasks/Logs/`.

---

## Interaction with User

If the root cause is not in the error table, batch questions and ask. Common questions: whether to increase `-MaxRuntimeMinutes`, whether to clear stale queues/Failed dirs, whether to increase `-MaxCatchallIterations`.

---

## Changelog

- 2026-07-08: Rewrote for v2 architecture — removed watchdog, replaced with 4-phase catchall loop using `runfix audit-complete`, `runfix localorchestrator`, `runfix deploy.ps1` as subprocesses.
