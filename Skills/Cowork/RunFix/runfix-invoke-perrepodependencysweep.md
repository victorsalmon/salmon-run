# Skill: RunFix Goals - `invoke-perrepodependencysweep`

**Purpose**: Goals file for `RunFix Invoke-PerRepoDependencySweep.ps1` - defines what success looks like, what errors to expect, and how to verify the sweep report is healthy after a run.

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

**Target script**: `Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1`

---

## Configuration (Script Mode)

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1` |
| `$LOG_PREFIX` | `runfix-invoke-perrepodependencysweep` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `720` |
| `$TIMEOUT_SECONDS` | `900` (npm/pip audits can exceed 5 min per manifest) |

Flags:

```powershell
& '<TARGET_SCRIPT>' -RepoRoot 'C:\Repos' -OutputPath 'C:\Repos\audit-deps-report.md'
# Scoped pilot: add -Repos @('salmon-orchestrator','currents-bookkeeping','clocklobster.com')
# JSON report: add -Json
```

---

## Preflight (Phase 0.5)

1. **npm installed** - `npm --version` (required for JS manifests; without it, npm manifests report `skipped - npm not installed`)
2. **pip-audit or uvx installed** - `pip-audit --version` or `uvx --version` (required for Python manifests; without either, Python manifests report `skipped - pip-audit/uvx not installed`)
3. **Repo root exists** - `Test-Path 'C:\Repos' -PathType Container`
4. **Script parses** - `[System.Management.Automation.Language.Parser]::ParseFile` returns no errors
5. **Registry access** - npm audit / pip-audit reach their registries; a blocked network yields per-manifest `error` rows, not a crash

---

## Rubrics

| Criterion | Passing condition |
|-----------|-------------------|
| Exit code | `$LASTEXITCODE -eq 0` |
| Success signal | Output contains `Dependency sweep report: <path>` |
| No hard errors | No `Write-Error` or uncaught exception in output |
| Report exists | Output file exists on disk and contains `Manifests scanned:` |

### Verification

```powershell
function Invoke-PerRepoDependencySweepRubrics {
    param([string]$OutputText)
    $failures = @()

    if ($global:LASTEXITCODE -ne 0) { $failures += "Exit code $($global:LASTEXITCODE)" }
    if ($OutputText -notmatch 'Dependency sweep report:') { $failures += 'Missing "Dependency sweep report:" success signal' }
    if ($OutputText -match '(?i)(write-error|fatal|unhandled)') { $failures += "Error pattern in output: $($matches[1])" }

    return @{
        Passed   = $failures.Count -eq 0
        Failures = $failures
    }
}
```

---

## Phase 2 - Error Table

| # | Error symptom | Root cause | Fix | Files changed |
|---|---|---|---|---|
| 1 | `Start-Job: Cannot validate argument on parameter 'WorkingDirectory'` | `Invoke-CommandWithTimeout` called without `-WorkingDirectory` (empty string passed) | Caller must supply a non-empty working dir, or omit the param when not needed | `Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1` |
| 2 | `The term 'npm' is not recognized` | npm not on PATH | Install Node.js/npm, or accept `skipped - npm not installed` rows | environment |
| 3 | `The term 'uvx' is not recognized` / `pip-audit` | Neither uvx nor pip-audit installed | `python -m pip install pip-audit` or `winget install astral-sh.uv` | environment |
| 4 | Every JS manifest reports `error` with registry/auth summary | npm registry unreachable or token expired | Fix network / `npm login`; audit rows are per-manifest and non-fatal | environment |
| 5 | Report shows `0 manifests` unexpectedly | `-Repos` filter matched no top-level dirs, or repo root path wrong | Verify repo names against `Get-ChildItem <RepoRoot> -Directory` | invocation |
| 6 | `Get-ChildItem` recursion slow over `C:\Repos` | Deep node_modules trees | Script already limits `-Depth 4` and path-filters; do not remove the depth cap | `Skills/Workflows/Audit/Invoke-PerRepoDependencySweep.ps1` |
| 7 | `vulnerable: N` rows but report table empty | Findings table only renders when `Total -gt 0`; check `## Details` rows for per-manifest status | Inspect `## Details`; a vuln row always appears there | report |

---

## Phase 4.5 - Health Check (optional)

After a successful run, verify the report is well-formed:

```powershell
# Report exists and has expected sections
$report = Get-Content 'C:\Repos\audit-deps-report.md' -Raw
$report -match '# Cross-Repo Dependency Sweep'       # header
$report -match '## Vulnerable Manifests'              # findings table
$report -match '## Per-Repo Summary'                  # repo rollup
$report -match '## Details'                           # per-manifest lines
```

---

## Interaction with User

If a root cause is not in the error table (e.g., a manifest type the script does not recognize, or a new audit tool preference), batch questions and ask the user: whether to add new manifest patterns, change `-Depth`, or switch `npm audit` flags (`--omit=dev` vs full).
