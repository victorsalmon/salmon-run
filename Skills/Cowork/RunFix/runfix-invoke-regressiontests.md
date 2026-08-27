# Skill: RunFix — Invoke-RegressionTests.ps1

**Purpose**: Run `Skills/Docker/Tests/Invoke-RegressionTests.ps1` iteratively — diagnosing and fixing Regression Test failures until the full suite passes. Used as Phase 5 of the refactor pipeline.

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

---

## Configuration

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Skills/Docker/Tests/Invoke-RegressionTests.ps1` |
| `$LOG_PREFIX` | `runfix-invoke-regressiontests` |
| `$CHECKPOINT_RESUME` | `false` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `720` |
| `$TIMEOUT_SECONDS` | `300` |

Flags: `-PassThru`

---

## Preflight

1. **Pester installed** — `Get-Module -ListAvailable Pester`
2. **Script exists** — `Test-Path "Skills/Docker/Tests/Invoke-RegressionTests.ps1"`
3. **Test directory has files** — `Get-ChildItem "Skills/Docker/Tests/*.Tests.ps1"`
4. **No stale results** — `Remove-Item "Tasks/Logs/regression-tests-*.json" -Force -ErrorAction SilentlyContinue`
5. **Clean working tree** — `git status --porcelain` (warn if dirty)

## Rubrics

| Criterion | Passing condition |
|-----------|-------------------|
| Exit code | `$LASTEXITCODE -eq 0` |
| No failures | Output shows `failedCount == 0` |

### Verification

```powershell
function Invoke-RegressionTestRubrics {
    param([string]$OutputText)
    $failures = @()
    if ($global:LASTEXITCODE -ne 0) { $failures += "Exit code $($global:LASTEXITCODE)" }
    if ($OutputText -match '(\d+) failed' -and [int]$matches[1] -gt 0) { $failures += "$($matches[1]) test(s) failed" }
    return @{ Passed = $failures.Count -eq 0; Failures = $failures }
}
```

## Error Table

| # | Error symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `Invoke-Pester` not recognized | Pester not installed | `Install-Module -Name Pester -Force -SkipPublisherCheck` |
| 2 | Test file syntax error | PowerShell parser error | Fix syntax in `.Tests.ps1` file |
| 3 | Test assertion fails | Source/test mismatch | Fix test or fix source code |
| 4 | `CommandNotFoundException` | Function renamed/removed | Update test to use current name |
| 5 | All tests skip (tag mismatch) | No tests match -Tag | Remove tag or fix filter |
| 6 | 0 tests found / no results | Empty test dir or Pester issue | Run `Invoke-Pester -Path Skills/Docker/Tests/` directly |

## Changelog

- 2026-06-23: Initial creation.
