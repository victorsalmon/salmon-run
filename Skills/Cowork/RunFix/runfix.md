# Skill: RunFix — Detached Polling Fix Engine (v2)

**Purpose**: Run any script or workflow and monitor it every 60 seconds — diagnosing, fixing, committing, pushing, and re-launching until rubrics are met. Runs for up to 12 hours (configurable) as a detached PowerShell process outside the TUI.

**Architecture**: The engine is `Orchestrator/Orchestration/RunFix.ps1` — a standalone PowerShell script. Key design:

1. **Background process** — the target is launched via `Start-Process -NoNewWindow -PassThru` and runs alongside the RunFix engine.
2. **1-minute polling** — every `$PollIntervalSeconds` (default 60), RunFix reads partial output and checks rubrics against it.
3. **Live detection** — if fatal failures appear mid-run, the process is killed, diagnosed, fixed, committed/pushed, and re-launched.
4. **Exit detection** — when the process completes on its own, final rubrics are checked against the full output.
5. **Commit & push on fix** — every fix (error table or LLM-diagnosed) is auto-committed and pushed before re-launching.
6. **12-hour wall clock** — continues indefinitely until rubrics pass or wall time is exhausted. No cycle limit.

Only the LLM-required step (error diagnosis + source file fix) calls into opencode via the `fix-diagnose` command template (~30 lines). Everything else (loop, polling, rubrics, commit/push, output capture, logging) is pure PowerShell.

**Script mode** — goals files follow `runfix-<basename>.md` convention (e.g. `deploy.ps1` → `runfix-deploy.md`).

**Command mode** — goals files follow `runfix-cmd-<command>.md` convention.

If no goals file exists, RunFix cannot operate (no target to run). The old meta-interpreter (Phase 0.5) has been removed — goals files are required.

**Prerequisites**: PowerShell 7+, opencode CLI, write access to `Tasks/`.

## Polling vs Waiting (was Waiting-mode sleep)

Fast-exit targets (like `Invoke-Orchestrate.ps1 -DetachWatchdog`) return exit 0 immediately but the actual work runs in the background. The polling loop handles this naturally: the process exits quickly, RunFix detects the exit, and re-launches. If no fatal failures are found, re-launch is immediate (no LLM call). The 1-minute poll interval prevents runaway cycle rates.

## Goals File Format

```
## Configuration
| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `path/to/script.ps1` |
| `$POLL_INTERVAL_SECONDS` | `60` (optional, default 60) |
| `$MAX_WALL_MINUTES` | `720` (optional, default 720 = 12h) |
| `$LOG_PREFIX` | `runfix-myscript` |
| `$LOG_CHECK_GLOB` | *(optional)* `relative/glob/to/logs/*.log` — if set, RunFix reads matching log files each poll and flags any `ERROR`/`WARN` entries as fatal rubric failures (requires two consecutive polls with the same errors to avoid transient noise) |

## Rubrics
| # | Criterion | Passing condition |
|---|-----------|-------------------|
| 0 | Success signal | Log contains `TASK COMPLETE` |
| 1 | Exit code | `$LASTEXITCODE -eq 0` |

## Error Table
| # | Error symptom | Root cause | Fix | Verification |
|---|---|---|---|---|
| 1 | ... | ... | ... | ... |
```

The full engine lifecycle is documented at `Orchestrator/Orchestration/RunFix.ps1`.

## Known failure modes

### Self-modification dead letter
When `fix-diagnose` modifies the goals file or RunFix.ps1 itself, the running PowerShell process does NOT re-read those changes — it has the pre-compiled script in memory. Two mitigations:
- The goals file re-read block (top of each while-loop cycle) re-parses config, flags, rubrics, and error table from the goals file before each cycle
- If the fix changes RunFix.ps1 logic itself (not just config), the process must be restarted

### `fix-diagnose` misdiagnosis of module export mismatches
When a function from a loaded module is "not found" at runtime, the LLM may diagnose it as a missing `RequiredModules` dependency or a name-scoping issue. In multi-file PowerShell modules (`.psd1` + `.psm1`), the actual root cause is often simpler: the function exists in the source folder but is missing from either the `.psd1`'s `FunctionsToExport` or the `.psm1`'s `Export-ModuleMember` list. A function must appear in BOTH lists to be visible from outside the module. The LLM fix usually addresses the symptom (adding the dependency) but misses the root cause (the export list). If the same "not recognized" error persists after adding dependencies, check the export lists.

### `$FLAGS` with array syntax gets evaluated as code
Do NOT use `@('-Flag1', '-Flag2')` syntax in the goals file's `$FLAGS` value. The string is embedded directly into an `-EncodedCommand` PowerShell script, where `@(...)` is an array expression. Use bare flags: `-Flag1 -Flag2`.

### Section header naming must match parser regex
The rubric section header MUST start with `## Rubrics`. The error table section header MUST contain `Error Table`. The parser uses `## Rubrics[^#]*?\n` and `## [^#]*?Error Table[^#]*?\n` to find these sections. Custom suffixes like `## Rubrics — My Goals` are handled by the `[^#]*?` pattern.

## Safety — Process Killing

**Never kill `opencode` processes.** The user may have interactive opencode sessions. Only kill processes that your own RunFix cycle explicitly spawned (track via PIDs from `Start-Process -PassThru`). Never use time-range or name-based filters that could catch user sessions.

---

## Troubleshooting

### RunFix passes prematurely (exit code 0 accepted as success)
Exit code 0 from the target script is NOT sufficient for success — many tools exit 0 for both "complete" and "still waiting" (e.g., `Invoke-Orchestrate.ps1 -DetachWatchdog`). Always add a `Log contains <success-pattern>` rubric row. RunFix categorizes success-pattern failures as "waiting" (not "fatal") and skips the LLM call — it simply retries.

### RunFix loops calling `fix-diagnose` on the same error every cycle
Check the rubric failures: if they are all `Output missing success pattern`, the target hasn't reached its goal state yet — the polling loop skips the LLM and simply waits for the next poll interval. If the failures include `Exit code <N>` or `Output contains failure pattern`, the LLM is genuinely needed. Since there is no cycle limit, the loop continues until wall time is exhausted. Check the target script's preconditions or adjust `$MAX_WALL_MINUTES` if the target genuinely needs more time.

### RunFix aborts mid-session with "AWS_SSO: aws sts get-caller-identity failed"
The `Test-TerminalConditions` function previously checked AWS SSO unconditionally. For targets that use `-Executor local` (no external services needed), this was a false positive. Now gated behind `$executorNeedsAws` — local executor skips the check. Also hardcoded `--profile intersite` has been replaced with `$env:AWS_SSO_PROFILE` (default `interclaw`). Workaround: `$env:RUNFIX_SKIP_TERMINAL_CHECKS=1` bypasses all terminal checks.

### RunFix kills long-running scripts due to default per-process timeout
The default `$runfixTimeoutSec` is 300 seconds (5 minutes) and `$runfixMaxWallMinutes` is 720 minutes (12 hours). The per-process timeout kills a single invocation that exceeds 5 minutes. For scripts that run for hours (deployment, audit pipelines, batch processing), set these before launch:
```powershell
$env:RUNFIX_TIMEOUT_SECONDS = 172800  # 48 hours per cycle
$env:RUNFIX_MAX_WALL_MINUTES = 28800  # 20 days wall time
```
Without the per-process timeout override, RunFix kills a long-running target mid-cycle, sees the rubric failures, and re-launches. The polling loop handles this naturally — it will keep re-launching until the wall time is exhausted. The key knob is `$env:RUNFIX_TIMEOUT_SECONDS`: set it high enough so a single invocation completes without being killed.

### `opencode run --command` fails with "Missing API key" despite env var being set
When using a custom provider name (e.g. `opencode-go`), the AI SDK looks for `OPENCODE_GO_API_KEY` env var (note `_API_KEY` suffix). If the var is set but the error persists, check `~/.local/share/opencode/auth.json`. The credential entry requires `"type": "api"`:
```json
{
  "opencode-go": {
    "type": "api",
    "key": "sk-..."
  }
}
```
Without `"type": "api"`, `opencode providers list` reports 0 credentials and the key is silently ignored. RunFix's preflight check should verify `opencode providers list` shows the expected credential count.

### AWS SSO browser re-auth on every cycle — cached credentials solve this
Each RunFix cycle or child process previously relied on the AWS SSO session cache, triggering browser prompts when the token wasn't propagated. Fix: after SSO verification, call `aws configure export-credentials --profile $ssoProfile --format env` and set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` as process-level env vars. Children inherit these and never re-prompt SSO. Credentials last ~8 hours; re-cached each RunFix cycle.

### RunFix hangs forever on interactive targets (`Read-Host` blocks)
When the target calls `Read-Host` (e.g. `deploy.ps1` FleetToggles via `Get-SilentToggle`), the child process had stdout/stderr redirected but **not** stdin — so `[Console]::IsInputRedirected` was false, the script stayed interactive, and blocked on the prompt indefinitely. No timeout fires because the process is still "running". Many interactive scripts (including `deploy.ps1` lines 145-147) auto-enable a headless mode when stdin is redirected. **Fix (applied in RunFix.ps1)**: each target invocation now redirects stdin from an empty temp file (`[System.IO.Path]::GetTempFileName()`), making `IsInputRedirected` true so the target's own non-interactive detection engages (deploy → DroneMode with defaults; any stray `Read-Host` returns immediately). **Do NOT use `-RedirectStandardInput "NUL"`** — `Start-Process` rejects the device name as an invalid path and throws, killing RunFix before it logs completion.

### `deploy`'s AwsSso precheck masks an IAM gap as a stale token
`Initialize-AwsSsoSession` used to treat a Secrets Manager `AccessDenied` as a stale token: it deleted the valid SSO cache and attempted device-code auth (impossible headless), producing a confusing hang. A missing `secretsmanager` IAM policy is a **permission** error, not a stale token — re-login cannot fix it. **Fix (applied in `SalmonRun.Provision`)**: `AccessDenied`/`not authorized` now throws a clear IAM error immediately instead of forcing re-login. If you hit this, the `intersite` SSO role lacks `secretsmanager:*` — attach an IAM policy (manual task; agents are read-only to AWS SM). Symptom: `aws secretsmanager list-secrets --profile intersite --region ca-central-1` returns `AccessDeniedException`.

## Changelog
- 2026-07-08: **v2 — Polling loop**: Replaced cycle-based loop with 1-minute polling loop. Target runs as background process; RunFix checks rubrics every 60s on partial output. Fatal failures kill → diagnose → fix → commit+push → re-launch. Wall time default increased to 720 min (12h). Removed MaxCycles / context gate. Added `Start-TargetBackground`, `Invoke-FixCommitAndPush`. Updated doc and template. (Also: documented RunFix headless `Read-Host` hang and `deploy` AwsSso precheck masking IAM gaps.)
- 2026-07-07: Added troubleshooting entries for auth.json `"type": "api"`, timeout config, credential caching, and merged AWS SSO profile fix with executor-aware gating
- 2026-07-06: Documented AWS SSO false positive in Troubleshooting (terminal checks for `-Executor local`)
- 2026-07-01: Added Known Failure Modes entry for `fix-diagnose` misdiagnosis of .psd1/.psm1 export mismatches
- 2026-06-28: Added goals-file re-read at each cycle, waiting-only failure classification, rubric section regex flexibility, and `$FLAGS` array-syntax warning.
- 2026-06-25: Replaced 403-line TUI skill with detached `RunFix.ps1` + `fix-diagnose` command template.
