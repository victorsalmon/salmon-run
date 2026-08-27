# Skill: Troubleshoot

**Purpose**: Diagnose and fix common Docker/Swarm fleet issues — crash loops, DNS failures, health check flapping, volume mount problems, secret hydration failures, resource exhaustion, image build failures, and Swarm operational issues.

**Trigger**: "container keeps crashing", "service not starting", "DNS not resolving", "health check failing", "volume mount error", "deploy stuck", "diagnose fleet"

---

## Diagnostic Command Reference

| Command | What It Shows |
|---------|--------------|
| `docker service ls` | All services and their replica counts (`N/N` = healthy) |
| `docker service ps <service>` | Individual task states, exit codes, error messages |
| `docker service logs <service>` | Container stdout/stderr — best for runtime errors |
| `docker inspect <container>` | Full container metadata (mounts, env, network, health) |
| `docker stats` | Live CPU/memory usage per container |
| `docker system df` | Disk usage by images, containers, volumes, build cache |
| `docker service inspect <service>` | Service configuration (secrets, networks, env) |

---

## Issue Categories

### 1. Crash Loops

**Symptom**: Service shows `0/N` replicas or tasks show `Exited (1)` repeatedly.

**Diagnosis**:
```powershell
docker service ps <service>
docker service logs <service>
```

**Common causes and fixes**:

| Error Pattern | Likely Root Cause | Fix |
|--------------|-------------------|-----|
| `MODULE_NOT_FOUND` | Dockerfile missing `npm ci` / `npm install` | Add install step to Dockerfile, rebuild image |
| `non-zero exit (1)` + no log output | Entrypoint script error (permission, missing interpreter) | `chmod +x entrypoint.sh`, check shebang |
| `Cannot find module './auth/fleet-auth'` | Module not COPY'd into image | Add `COPY Infrastructure/auth/ /app/auth/` to Dockerfile |
| `ReferenceError: require is not defined` | `.js` file uses CJS but `package.json` has `"type": "module"` | Rename to `.cjs` and update import paths |
| `Service update paused` after `--force` | Swarm backoff — waiting 30s after crash loop | Wait 30s, then re-run `docker service update --force` |
| `Update paused due to failure` | Repeated crash prevents Swarm from restarting | Fix root cause, wait for backoff, force-update |

**Resolution**: Fix the root cause (usually in the Dockerfile or entrypoint), rebuild the image, then `docker service update --force <service>`.

### 2. DNS Resolution Failures

**Symptom**: Containers can't resolve hostnames (internal or external). `docker service logs` shows connection refused or name resolution errors.

**Common cause**: Docker DNS settings — Swarm services default to host DNS which may not resolve overlay network names.

**Fix**:
1. Verify `ndots:0` is set in compose (prevents search domain interference)
2. Set explicit public DNS: `8.8.8.8`, `1.1.1.1`
3. Restart the service: `docker service update --force <service>`
4. Check overlay network connectivity: `docker network inspect ORCHESTRATOR_overlay`
5. If the network watchdog (3 consecutive failures) triggers, the service auto-restarts

### 3. Health Check Flapping

**Symptom**: Service replicas oscillate between `Running` and `Unhealthy`. `docker service ps` shows tasks repeatedly restarting due to failed health checks.

**Diagnosis**:
```powershell
docker service ps <service> --filter "desired-state=running" --format "{{.Name}}\t{{.CurrentState}}"
```

**Common causes**:

| Cause | Fix |
|-------|-----|
| Slow application startup (> health check `start-period`) | Increase `start-period` in compose health check config |
| `/api/health` endpoint doesn't respond | Check the endpoint implementation; verify it returns 200 |
| Compose-level health check differs from Dockerfile `HEALTHCHECK` | Compose-level overrides Dockerfile — update compose |
| Health check probes wrong port | Verify port against `Infrastructure/port-registry.json` |
| Health check requires auth (browserless `/pressure` needs `?token=`) | Add token query param to health check URL |

### 4. Volume Mount Problems

**Symptom**: Service starts but can't read/write expected files. `docker service inspect <service>` shows volume mounts.

**Diagnosis**:
```powershell
docker service inspect <service> --format '{{json .Spec.TaskTemplate.ContainerSpec.Mounts}}'
docker inspect <container> --format '{{json .Mounts}}'
```

**Resolution**:
1. Verify the source path exists on the host
2. Check permissions on the host directory (containers run as `USER ORCHESTRATOR`)
3. For named volumes, verify they exist: `docker volume ls`
4. For bind mounts, the path must exist before the service starts
5. Run `docker container prune -f` to clear orphaned volumes

### 5. Secret Hydration Failures

**Symptom**: Service starts but can't find expected secrets. `/run/secrets/<bundle>` is missing or incomplete. `docker service logs` shows errors reading secret values.

**Diagnosis**:
```powershell
# Check if secrets are mounted
docker exec <container> ls /run/secrets/
# Check hydration phase logs
Get-Content Tasks/Logs/setup-*.log | Select-String "secrets"
```

**Resolution**:
1. Verify AWS SSO session is active: `aws sso login --profile intersite`
2. Check the bundle manifest in `SalmonRun.Secrets/Private/bundle-manifest.ps1` — is the key listed?
3. Re-run hydration: `deploy.ps1 -Phase DockerSecrets`
4. Check if the key is in AWS SM (ca-central-1)
5. Clear the secret cache: `Clear-SecretCache`

### 6. Resource Exhaustion

**Symptom**: Services can't start, `docker service ps` shows `pending` (insufficient resources), or containers are OOM-killed.

**Diagnosis**:
```powershell
docker stats
docker system df
# Check host resources
Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID, Size, FreeSpace
```

**Resolution**:
1. `docker container prune -f` — remove stopped containers
2. `docker image prune -a -f` — remove unused images (caution: rebuild needed)
3. `docker volume prune -f` — remove orphaned volumes
4. Increase compose resource limits if persistent
5. Check `Measure-DockerResources` for fleet budget compliance

### 7. Image Build Failures

**Symptom**: `docker build` exits with non-zero code during `Start-ParallelImageBuild` or individual build.

**Diagnosis**: Look at the build output for the specific error line:
```powershell
# Rebuild standalone for detailed output
docker build -f Infrastructure/<name>.Dockerfile . --no-cache 2>&1
```

**Error table**:

| Error | Likely Root Cause | Fix |
|-------|-------------------|-----|
| `MODULE_NOT_FOUND` | Dockerfile missing `npm ci` / install step | Add install step before COPY |
| `not found` in COPY | File excluded by `.dockerignore` or path wrong | Check `.dockerignore` and file path |
| `tar: invalid magic / short read` | URL in Dockerfile returns 404 | `curl -sIL <url>` to check; fix URL |
| `pwsh: Permission denied` / exit 127 | Missing `chmod +x` after binary extraction | Add `chmod +x` step to Dockerfile |
| `Couldn't find ICU` | Missing `libicu` package on Debian | Add `apt-get install libicu72` |

### 8. Image Update Not Picked Up by Swarm

**Symptom**: After `docker build -t <service>:local` and `docker service update --image <service>:local <svc>`, the new container still runs the old image despite the tag pointing to a new digest.

**Root cause**: Docker Swarm caches the image digest when a service is first deployed with a given tag. `docker service update --image <tag>` does not re-resolve the tag against the local image store if the digest is already known. Without `--force`, Swarm assumes the tag hasn't changed and reuses the cached container image.

**Fix**:
```powershell
docker service update --force --image <service>:local <svc>
```

The `--force` flag triggers a full task re-deployment, forcing Swarm to re-resolve the tag and pick up the new local image digest. Without it, even `docker service update --image` with the same tag will silently use the old image.

**Alternative**: Tag each build with a unique identifier (timestamp or build number) to avoid tag collision:
```powershell
docker build -t <service>:local-<timestamp> .
docker service update --image <service>:local-<timestamp> <svc>
```

### 8. Swarm Operational Issues

**Symptom**: `docker stack deploy` hangs, services don't converge, or Swarm state is inconsistent.

| Issue | Fix |
|-------|-----|
| Stack deploy hangs | Check `docker service ls` for stuck services. Force-restart individual services |
| Service shows `0/1` with no error | Check resource limits, Docker Desktop resources, disk space |
| `docker service logs` returns nothing | Service may have never started — check `docker service ps` for exit codes |
| Orphaned volumes accumulating | Run `docker volume prune -f` or `Remove-OrphanedVolumes` |
| Overlay network unreachable | Check `docker network inspect ORCHESTRATOR_overlay`; restart Docker Desktop if persistent |

---

## General Troubleshooting Flow

1. **Check service status**: `docker service ls` — which services are not at `N/N`?
2. **Inspect failing tasks**: `docker service ps <service>` — what's the exit code and error?
3. **Read logs**: `docker service logs <service>` — what does the application say?
4. **Check secrets**: Is `/run/secrets/` populated? Is AWS SSO active?
5. **Fix the source, not the state**: A runtime error during deploy is a failure of the script logic. Fix the Dockerfile, compose, or module — don't patch running containers.
6. **Re-deploy after fix**: `docker service update --force <service>` (or re-run deploy phase).

---

## Red lines

- **Never restart all services at once** during diagnosis — causes fleet-wide outage.
- **Always check logs before force-updating** — force-update destroys the current container and its logs.
- **Never use `docker exec` for production fixes** — changes are ephemeral. Fix the source and re-deploy.
- **Compose-level health checks override Dockerfile `HEALTHCHECK`** — update compose, not the Dockerfile, to fix health check behavior.
- **Swarm backoff delays forced restarts** — after a crash loop, wait ~30s before re-running `docker service update --force`.
- **Port registry must match reality** — `Get-ServicePort` reads `Infrastructure/port-registry.json`. A mismatch causes silent health check failures.

---

## Changelog
- 2026-06-16: Added section 8 (Image Update Not Picked Up by Swarm) documenting `--force` requirement for local image tag re-resolution

## Cross-References

| Resource | Description |
|----------|-------------|
| `Skills/Cowork/RunFix/runfix-deploy.md` | Full redeploy workflow with error tables, health check (Phase 4.5), and lessons learned |
| `Skills/Docker/Modules/SalmonRun.Diagnostics/` | Diagnostic module — log analysis helpers |
| `Skills/Docker/Scripts/diagnose-volumes.ps1` | Volume diagnostic script |
| `Skills/DevOps/Fleet/fleet-health/SKILL.md` | Health check commands and sentry monitoring |
| `Skills/DevOps/Fleet/secrets/SKILL.md` | Secret lifecycle — hydration and bundle reference |
| `Skills/DevOps/Fleet/deploy-fleet/SKILL.md` | Deploy pipeline phase reference |
