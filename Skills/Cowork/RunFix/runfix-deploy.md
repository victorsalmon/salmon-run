# Skill: RunFix Goals — deploy

**Purpose**: Goals file for `RunFix Skills/Docker/deploy.ps1` — defines success criteria, error signatures, and verification for the 14-phase deploy pipeline.

**Convention**: `Skills/Cowork/RunFix/runfix-deploy.md`

---

## Configuration (Script Mode)

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Skills/Docker/deploy.ps1` |
| `$LOG_PREFIX` | `runfix-deploy` |
| `$CHECKPOINT_RESUME` | `true` — via `.deploy-checkpoint.json` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `720` |
| `$TIMEOUT_SECONDS` | `7200` |
| `$FLAGS` | `-DroneMode -SkipAWSLogin` |

### Flags to pass

```powershell
# Full deploy (headless)
$env:AWS_SSO_PROFILE = "interclaw"
& 'Skills/Docker/deploy.ps1' -DroneMode -SkipAWSLogin

# Quick health check (skip deploy, verify fleet only)
# NOTE: -OnlyVerify exits before "ORCHESTRATOR COMPLETE" — RunFix rubric won't pass.
# Use for manual health check only, not inside RunFix loop.
& 'Skills/Docker/deploy.ps1' -OnlyVerify

# Resume from checkpoint
if (Test-Path "$PSScriptRoot/.deploy-checkpoint.json") {
    Write-Host "Checkpoint found — re-run without -Phase to see resume prompt"
}
```

---

## Preflight (Phase 0.5)

1. **Docker Desktop** must be running (`docker ps` succeeds)
2. **PowerShell 7+** required (`pwsh -v`)
3. **AWS SSO session** — `$env:AWS_SSO_PROFILE` must be set to the SSO profile name (e.g. `interclaw`). Run `aws sso login --profile interclaw` twice if the session is expired.
4. **Repo root** — script expects CWD at `intersite-orchestrator/` root
5. **Module dependencies** — `Skills/Docker/Modules/Interclaw.*` must be present

---

## Rubrics

| Criterion | Passing condition |
|-----------|-------------------|
| Exit code | `$LASTEXITCODE -eq 0` |
| Success signal | Log contains `ORCHESTRATOR COMPLETE` |
| All phases | Log contains `[PHASE]` — at least 14 distinct phase invocations |
| No fatal errors | Log does not contain `[FATAL]` |
| No unhandled exception | Log does not contain `Exception|ErrorActionPreference` at error level |

---

## Phase 2 — Error Table

| # | Error symptom | Root cause | Fix | Files changed |
|---|---|---|---|---|
| 1 | `AWS SSO login failed` | Expired session, browser not available | Run `aws sso login --profile intersite` twice | — |
| 2 | `Phase N prereq failed` | Phase dependency not met | Re-run with `-Phase <prereq>` to complete first | — |
| 3 | `Failed to create swarm secret` | Secret already exists or swarm not initialized | `docker secret ls` to verify; `docker swarm init` if needed | — |
| 4 | `Port X is already in use` | Port conflict with existing container | `docker container ls` to find, stop conflicting container | — |
| 5 | `Module load failed` | Module not in PSModulePath | Run from repo root; verify `Skills/Docker/Modules/` exists | — |
| 6 | `Docker daemon not running` | Docker Desktop not started | Start Docker Desktop, wait 30s, re-run | — |
| 7 | Checkpoint restore prompt appears | Previous deploy crashed mid-phase | Answer `Y` to resume or `N` to start over | `Skills/Docker/deploy.ps1` |
| 8 | `'Invoke-AgentOrchProvisioning' is not recognized` | Function defined in `.psm1` but missing from `.psd1`'s `FunctionsToExport` — the .psd1 acts as the effective export gate | Add function name to both `.psd1`'s `FunctionsToExport` and `.psm1`'s `Export-ModuleMember` | `Skills/Docker/Modules/SalmonRun.Provision/SalmonRun.Provision.psd1` |
| 9 | `'Invoke-WhatIfGuard' is not recognized` | Function listed in `.psd1`'s `FunctionsToExport` but missing from `.psm1`'s `Export-ModuleMember` | Add function name to `.psm1`'s `Export-ModuleMember` list | `Skills/Docker/Modules/SalmonRun.Deploy/SalmonRun.Deploy.psm1` |
| 10 | `Container exits 255 (FRAD_mcp_web, FRAD_is-fleet)` | Transient container start failure — image or secret bundle resolved correctly but task failed on first attempt | `docker service update --force <service>` to restart | — |
| 11 | `invalid mount config for bind source path does not exist` (FRAD_oc-base) | Bind mount source directory `Workspace/ORCH Outbox` not created on host | `New-Item -ItemType Directory -Path "Workspace/ORCH Outbox" -Force` | — |
| 12 | `Function from loaded module not found` | .psd1 `FunctionsToExport` or .psm1 `Export-ModuleMember` lists out of sync — a function exists in the module source but isn't exported by one or both lists | Check both lists in the module; a function must appear in both .psd1 `FunctionsToExport` AND .psm1 `Export-ModuleMember` to be visible from outside the module | `Skills/Docker/Modules/<Module>/<Module>.psd1`, `Skills/Docker/Modules/<Module>/<Module>.psm1` |
| 13 | `The terminator '#>' is missing from the multiline comment` (during module import) | Multiline comment block `<# ... #>` in public script missing closing `#>` — the function definition started inside an unclosed comment, causing the parser to consume the entire file as a comment and produce a broken module | Add `#>` to close the comment block before the function definition | `Skills/Docker/Modules/SalmonRun.Secrets/Public/Get-SecretFromAws.ps1` |
| 14 | `ConvertFrom-Json: Additional text encountered after finished reading JSON content: }. Path '', line 69, position 0.` (during module import) | `port-registry.json` has an extra closing brace `}` at line 68, placed after the `_notes` object closes at line 67 and before the root object closes at line 69 | Remove the extraneous `}` on line 68 | `Infrastructure/port-registry.json` |
| 15 | `AWS SSO profile not found and cannot be auto-detected` | `$env:AWS_SSO_PROFILE` is not set — deploy.ps1 checks this variable at line 417-418 to determine which SSO profile to use. Without it, the script cannot proceed past the identity checks | Set `$env:AWS_SSO_PROFILE = "interclaw"` before calling deploy. RunFix should set this env var in its preflight before each cycle | `Skills/Docker/deploy.ps1` (env var) |
| 16 | `FRAD_oc-base: [ENTRYPOINT] FATAL: cannot create temp JS file` | Stale `entrypoint.sh` on persistent volume uses `&>/dev/null` (bashism). Under `/bin/sh` (dash), `command -v mktemp &>/dev/null` leaks `mktemp` path to stdout, returns wrong exit code -> script falls to fallback path that never creates the temp file -> `[ ! -f "$_JS_EXPORT_SCRIPT" ]` FATAL | Copy current POSIX-compatible `Infrastructure/entrypoint.sh` to `FRAD_agent_persist_oc-base` volume and `docker service update --force FRAD_oc-base` | `Infrastructure/entrypoint.sh` (needs POSIX-safe `: >` syntax for temp file creation) |
| 17 | `FRAD_mcp_opencode: /usr/local/bin/code-server.sh: N: Bad substitution` (exit 2) | Dockerfile uses `ENTRYPOINT ["/bin/sh", ...]` but `entrypoint.sh` uses `${!VAR}` bash indirect expansion (lines 90,93,110,113,146,149). Compose gen already sets `/bin/bash` at `Add-SidecarServicesToCompose.ps1:183` but deployed service was built from older compose | `docker service update --entrypoint "/bin/bash /usr/local/bin/code-server.sh" FRAD_mcp_opencode` or redeploy stack to pick up compose override | `Infrastructure/opencode/Dockerfile` (change line 42 to `/bin/bash`) |
| 18 | `FRAD_oc-base: node script treats bundle as script: Unexpected token 'c' "const fs ="... is not valid JSON` | `entrypoint.sh` line 86 uses `process.argv[1]` but that's the JS script path, not the bundle path. Node.js passes script path as argv[1] and first CLI argument as argv[2]; `process.argv[2]` is the correct bundle path | Change `process.argv[1]` to `process.argv[2]` in the heredoc JS code | `Infrastructure/entrypoint.sh` line 86 |
| 19 | `FRAD_oc-base: /home/node/.ORCHESTRATOR/entrypoint.sh: N: Bad substitution` (after fixing argv) | `validate_env` function at line 206 uses `"${!_var}"` (bash indirect expansion) which is not supported by `/bin/sh` (dash) | Replace `"${!_var}"` with `eval "_val=\"\${$_var}\""` (POSIX-compatible) | `Infrastructure/entrypoint.sh` line 206 |
| 20 | `FRAD_is-fleet: Initialize-InterclawEnvironment not recognized` | Fleet 1Fleet.ps1 repo root detection assumed 2 parents from script dir, but container layout has script at `/home/node/app/Scripts/` (one parent = repo root). Also used `\` path sep on Linux | Use AGENTS.md marker for repo root detection, `[System.IO.Path]::PathSeparator`, explicitly import ModuleLoader module before calling Initialize-InterclawEnvironment | `Skills/Docker/1Fleet.ps1` |



---

## Error Table — Self-Improvement Protocol

When `fix-diagnose` fixes a novel error (no existing row matches the symptom):

1. Append a new row to the Error Table with:
   - Symptom: the exact error line or pattern
   - Root cause: what caused it (from diagnosis)
   - Fix: what was changed
   - Files changed: which files were edited
2. The new row's symptom must be regex-safe (escape special chars if needed)
3. Do NOT remove or re-number existing rows — just append

---

## Phase 4.5 — Health Check

After successful deploy, verify:

```powershell
docker stack ls
docker service ls
docker secret ls
docker ps
```

All 9 services should show `1/1` replicas and all containers should show `(healthy)` in `docker ps`:

| Stack service | Expected |
|---|---|
| `FRAD_is-bookkeeping` | 1/1, healthy |
| `FRAD_is-api` | 1/1, healthy |
| `FRAD_is-fleet` | 1/1, healthy |
| `FRAD_mcp_aqe` | 1/1, healthy |
| `FRAD_mcp_browserless` | 1/1, healthy |
| `FRAD_mcp_docusign` | 1/1, healthy |
| `FRAD_mcp_opencode` | 1/1, healthy |
| `FRAD_mcp_web` | 1/1, healthy |
| `FRAD_oc-base` | 1/1, healthy |

If any service is 0/1, investigate with `docker service ps <name> --no-trunc` and apply the fix from the error table below.

---

## Changelog
- 2026-07-01: Added post-deploy health check table (all 9 services 1/1), error entries for .psd1/.psm1 export mismatches and container runtime exit 255 + bind mount issues
- 2026-07-11: Fixed rubrics — corrected success signal to ORCHESTRATOR COMPLETE, switched to Log contains format for RunFix parser, removed dead Invoke-Rubrics function. Added $FLAGS (-DroneMode -SkipAWSLogin). Added Self-Improvement Protocol for error table learning.
- 2026-07-11: RunFix now sets AWS_SSO_PROFILE env var and attempts device-code re-auth on expired session. Invoke-AwsCommand always refreshes temp creds in ~/.aws/credentials every call.
- 2026-07-12: Added error entries 13-15: missing `#>` comment terminator in Get-SecretFromAws.ps1, extra `}` in port-registry.json, AWS_SSO_PROFILE env var not set. Updated preflight and flags to set env var.
- 2026-07-12: Added error entries 16-19: oc-base & mcp_opencode container crashes from bashisms, process.argv off-by-one in entrypoint.sh JS code, and `${!_var}` in validate_env. All fixed in `Infrastructure/entrypoint.sh` (3 POSIX compat fixes) and Dockerfile entrypoint override.
- 2026-07-12: Added error entry 20: is-fleet repo root detection and module import ordering. Removed retired schedule-poller service entries (originally 21-22).

## Interaction with User

If the root cause is not in the error table, the LLM diagnoses and fixes it autonomously, then appends the new error to the table per the Self-Improvement Protocol. If the fix requires human action (AWS console operations, physical device steps), stop, batch questions, and ask the user. Common questions: whether to skip specific phases via `-Phase` flag, adjust timeout values, or run with `-WhatIf` first.
