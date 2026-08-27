# Skill: Build Preflight

**Purpose**: Validate all Dockerfiles under `Infrastructure/` by attempting a standalone build. Catches build failures (missing files, broken URLs, missing dependencies, permission errors) in parallel before any deploy run — collapsing what would be multiple deploy cycles into a single 2-minute preflight step.

**Type**: utility  
**Container**: opencode  
**Depends on**: Docker Desktop running, `docker` CLI  
**Called by**: `opencode/runfix-deploy`

---

## Workflow

### Step 1 — Discover Dockerfiles

```powershell
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$dockerfiles = Get-ChildItem -Path (Join-Path $repoRoot "Infrastructure") -Filter "*.Dockerfile"
if ($dockerfiles.Count -eq 0) {
    Write-Host "No Dockerfiles found in Infrastructure/" -ForegroundColor Yellow
    return
}
```

Finds all files matching `*.Dockerfile` in `Infrastructure/`. Skips the opencode Dockerfile (lives in `Infrastructure/opencode/`) and any others outside this path.

### Step 2 — Create Build Log Directory

```powershell
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildLogDir = Join-Path $repoRoot "Tasks" "Logs" "build-preflight-$timestamp"
$null = New-Item -ItemType Directory -Path $buildLogDir -Force
```

Each build gets its own log file so failures can be inspected individually without wading through interleaved output.

### Step 3 — Build Each Dockerfile

```powershell
$failures = @()
$successes = @()

foreach ($df in $dockerfiles) {
    $imageName = $df.BaseName   # e.g. "api-proxy" from "api-proxy.Dockerfile"
    $logPath = Join-Path $buildLogDir "$imageName.log"
    
    Write-Host "  [BUILD] $($df.Name) -> ${imageName}:preflight ..." -NoNewline
    Push-Location $repoRoot
    $buildOutput = docker build --progress=plain -f $df.FullName -t "${imageName}:preflight" . 2>&1
    Pop-Location
    $buildOutput | Out-File -FilePath $logPath -Encoding utf8
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
        $successes += $imageName
        # Clean up preflight image immediately to save disk space
        docker image rm "${imageName}:preflight" 2>&1 | Out-Null
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        $errorSummary = ($buildOutput |
            Select-String -Pattern "ERROR|failed|not found|not created" |
            Select-Object -First 3) -join "; "
        $failures += @{
            Dockerfile = $df.Name
            Image = $imageName
            Log = $logPath
            Error = $errorSummary
        }
    }
}
```

### Step 4 — Report Results

```powershell
if ($failures.Count -eq 0) {
    Write-Host "`n[OK] All $($dockerfiles.Count) Dockerfile(s) built successfully." -ForegroundColor Green
} else {
    Write-Host "`n[FAIL] $($failures.Count) / $($dockerfiles.Count) Dockerfile(s) failed:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  - $($f.Dockerfile)" -ForegroundColor Yellow
        Write-Host "    Error: $($f.Error)" -ForegroundColor DarkYellow
        Write-Host "    Full log: $($f.Log)" -ForegroundColor DarkYellow
    }
}
```

### Step 5 — Diagnose Failures

For each failed build, use these common patterns:

| Build error | Likely fix |
|---|---|
| `MODULE_NOT_FOUND` | Add `npm ci` or `npm install` to Dockerfile |
| `COPY` target `not found` | Check `.dockerignore` exclusions or fix COPY path |
| `tar: invalid magic / short read` | URL returns 404 — find correct URL |
| `pwsh: Permission denied` | Add `chmod +x` after tar extraction |
| `Couldn't find ICU` | Add `libicu72` to `apt-get install` |
| `CopyIgnoredFile` warning | Add `!path/to/file` negation to `.dockerignore` |

### Step 6 — Re-run (if fixed)

After fixing any Dockerfiles, re-run this skill to confirm all builds pass before proceeding to a full deploy.

---

## Cross-references

- `opencode/runfix-deploy` — RunFix Deploy workflow (calls this as a preflight step)
- `Infrastructure/*.Dockerfile` — all fleet Dockerfiles
- `.dockerignore` — build context exclusion rules
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives

## Red lines

- **Preflight images are ephemeral**: Always `docker image rm` preflight images after a successful build. They exist only to validate the Dockerfile.
- **No side effects**: This skill builds images but does not push them, deploy them, or modify any running services.
- **Build logs are local**: Log files go to `Tasks/Logs/build-preflight-<timestamp>/`. They are not committed.
- **Not a replacement for integration tests**: A passing build does not guarantee the container starts correctly. That coverage comes from Phase 4.5 (Health Check).

### Lessons Learned — consolidated

#### 2026-06-11 & 2026-06-14 — Preflight validation gaps

**What Didn't Work**:
- **Build exit 0 ≠ runtime works**: A Dockerfile that simply omits a `COPY` for a required module builds successfully (exit 0) and only fails at runtime with `MODULE_NOT_FOUND`. The preflight can't catch this — it only validates build-time errors.
- **Image-name misalignment**: `Invoke-FleetImageBuild.ps1` tags as `fleet:local` but `SalmonRun.Constants.ps1` references `is-fleet:local`. Both build and preflight passed; deployment failed with "No such image".
- **Healthcheck syntax stripped by Compose**: `$(cat /run/secrets/...)` in a Compose template was consumed by Docker variable interpolation, leaving broken shell syntax. The image built fine; the healthcheck command failed only in Swarm.
- **Secrets with `\r\n` line endings corrupt healthcheck URLs**: Valid syntax, invalid content. Neither build nor preflight catches this — only the 60s healthcheck window reveals it.

**Improvements for next run**:
- Add an optional post-build smoke test step: after each successful build, run `docker run --rm <image> node -e "require('<expected-module>')"` to verify critical imports resolve.
- Parse each Dockerfile's `COPY` instructions and verify every source path glob expands to at least one existing file on disk.
- Add a post-preflight cross-reference: read `docker-compose.interclaw.yml`, extract every `image:` value, and verify each one exists in `docker images`.
- Add a post-preflight healthcheck validator: run each `healthcheck.test` shell command inside `docker run --rm` with `sh -n` to verify syntax.
- Document this skill's limitation: "Preflight validates build-time correctness only — runtime behaviour (healthchecks, secrets, image-name alignment) requires additional preflight steps."
