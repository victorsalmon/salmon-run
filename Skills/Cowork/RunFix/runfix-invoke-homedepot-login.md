# Skill: RunFix — Home Depot Login

**Purpose**: Run `Invoke-HomeDepotLogin.ps1` with `-Headless` iteratively — diagnosing, fixing, and re-running until Home Depot Pro authentication succeeds.

**Target**: `Infrastructure/Browserless/Sites/homedepot.ca/Invoke-HomeDepotLogin.ps1`

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

---

## Configuration

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `Infrastructure/Browserless/Sites/homedepot.ca/Invoke-HomeDepotLogin.ps1` |
| `$LOG_PREFIX` | `runfix-invoke-homedepot-login` |
| `$CHECKPOINT_RESUME` | `false` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `720` |
| `$TIMEOUT_SECONDS` | `300` |

### Flags to pass

```powershell
$flags = @('-Headless')
```

---

## Phase 0.5 — Preflight

1. **Prerequisites**:
   - `node --version` succeeds
   - Playwright installed in `Infrastructure/Browserless/Sites/homedepot.ca/`
   - `INTERSITE_HOME_DEPOT_EMAIL` and `INTERSITE_HOME_DEPOT_PASSWORD` env vars set (or AWS SM access)

2. **Configuration checks**:
   - `homedepot-login.js` exists
   - AWS SM reachable if using credential source (optional — falls back to env vars)
   - CDP port 9222 available (`curl -sf http://localhost:9222/json/version`). NOTE: Home Depot blocks Playwright's bundled Chromium — the JS connects to user's real Chrome via CDP.

3. **Note about headless mode**: Home Depot Pro blocks headless browsers. The `homedepot-login.js` script uses `chromium.connectOverCDP()` to connect to the user's real Chrome. The `--headless` flag in `Invoke-HomeDepotLogin.ps1` is informational — the JS script ignores it. RunFix will still catch and fix other errors (credential loading, cookie persistence, CDP connection issues).

4. **Static analysis**:
   - `node --check homedepot-login.js`

---

## Rubrics

| Criterion | Passing condition |
|-----------|-------------------|
| Exit code | `$LASTEXITCODE -eq 0` |
| Success signal | Output contains `Cookie saved` or `Session valid` |
| No fatal errors | No `FATAL` or `ERROR` in output |
| CDP connection | No `connect ECONNREFUSED` or `Cannot connect` errors |

### Verification

```powershell
function Invoke-Rubrics {
    param([string]$OutputText)
    $failures = @()
    if ($global:LASTEXITCODE -ne 0) { $failures += "Exit code $($global:LASTEXITCODE)" }
    if ($OutputText -notmatch 'Cookie saved|Session valid|Login successful') { $failures += "Missing success signal" }
    if ($OutputText -match 'FATAL|ERROR') { $failures += "Error in output" }
    if ($OutputText -match 'ECONNREFUSED|Cannot connect') { $failures += "CDP connection failed" }
    return @{ Passed = $failures.Count -eq 0; Failures = $failures }
}
```

---

## Phase 2 — Error Table

| # | Error symptom | Root cause | Fix | Verification |
|---|---|---|---|---|
| 1 | `connect ECONNREFUSED 127.0.0.1:9222` | Chrome not launched with `--remote-debugging-port=9222` | Launch Chrome: `& "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222` | `curl -sf http://localhost:9222/json/version` |
| 2 | `Credentials not available` from AWS SM | AWS SSO session expired | `aws sso login --profile intersite` | `aws sts get-caller-identity --profile intersite` |
| 3 | `ERR_HTTP2_PROTOCOL_ERROR` | Home Depot blocks Playwright Chromium | Already handled by CDP approach — ensure not falling back to `chromium.launch()` | Check `homedepot-login.js` uses `connectOverCDP` not `launch` |
| 4 | `Timeout waiting for selector` | Home Depot page layout changed post-login | Update selectors in JS script | Run headed once to inspect current DOM |
| 5 | `Cookie file not found` | First run — no session persisted yet | Expected on first run; RunFix continues | Check `.homedepot-session.json` after run |
| 6 | `ERR_NAME_NOT_RESOLVED` | Network DNS failure | Check internet connectivity | `ping homedepot.ca` |

---

## Phase 4.5 — Health Check

```powershell
$cookieFile = Join-Path $PWD "Infrastructure/Browserless/Sites/homedepot.ca/.homedepot-session.json"
if (Test-Path $cookieFile) {
    $cookies = Get-Content $cookieFile -Raw | ConvertFrom-Json
    Write-Host "Session cookie file: $($cookies.cookies.Count) cookies" -ForegroundColor Gray
}
```

---

## Interaction with User

Ask whether Chrome is running with `--remote-debugging-port=9222`, and whether CDP connection is preferred over browser launch.
