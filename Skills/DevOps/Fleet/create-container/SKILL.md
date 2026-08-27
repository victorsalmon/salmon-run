# Skill: Create Container

**Purpose**: Step-by-step checklist and integration guide for adding a new Docker container (service) to the ORCHESTRATOR fleet. Covers every integration point so nothing is missed — port registry, Dockerfile, image build, health endpoints, secret bundles, compose entry, MCP registration, and documentation.

**Trigger**: "add a new container", "create a service", "onboard a new Docker service", "new fleet container", "create a container for X", or when you need a checklist to ensure a new service is fully wired into the fleet.

---

## Decision Tree — What Kind of Container?

The **default** is an MCP-over-SSE server (Express + `@modelcontextprotocol/sdk`). Only answer "yes" when the container breaks this pattern:

| Question | If Yes | If No |
|----------|--------|-------|
| Is it a third-party upstream image? (e.g., Browserless Chrome) | Wrap with health proxy; skip auth middleware, skip MCP SSE registration | MCP SSE server — standard path |
| Does it need API keys or credentials? | Must create a secret bundle (§ 4) | Skip secret bundle; no secrets needed |
| Does it need filesystem access from the host? | Must add bind mount (§ 10) | Skip mount registry |
| Does it call external APIs? | MUST include retry/backoff, per-agent rate limiting, and audit logging | Skip retry/per-agent-limit sections |

---

## Integration Checklist (17 Steps)

### § 1. Port Registry

Pick the next available internal port from `Infrastructure/port-registry.json`:

- **MCP sidecar**: `mcp_sidecar_internal` range (21000–21999)
- **Upstream third-party**: `upstream_internal` range (3000–3999)
- **Host-published**: `gateway_host_ports` range (20100–39900) — only for gateway services

Add entry under `internal` (or `host` if host-published):

```json
"<service-name>": <next-available-port>
```

Update the `_notes` section if there's any special reason for the port choice.

**Files to modify**:
- [ ] `Infrastructure/port-registry.json`

---

### § 2. Health Endpoints

Every container that exposes an HTTP server **MUST** implement the common endpoints defined in `docs/Reference/API-Standards.md`:

| Endpoint | Required? | Purpose |
|----------|-----------|---------|
| `GET /api/health` | **Mandatory** | Liveness check — used by Docker healthcheck and Sentry |
| `GET /api/ready` | If container has dependencies | Readiness probe — returns 503 if deps are down |
| `GET /api/credentials` | If container uses API keys | Credential validity check (returns booleans only, no secrets) |
| `GET /api/routes` | **Mandatory** | Route discovery for agents |
| `GET /api/version` | **Mandatory** | Version metadata |
| `GET /tools/list` | **Mandatory** | MCP tool discovery (return `{"tools":[]}` if no tools) |

Health check response format:
```json
{ "status": "ok", "service": "<name>", "version": "1.0.0", "uptime": 3600 }
```

If the container embeds a third-party upstream (e.g., Browserless Chrome), proxy or alias these endpoints when feasible.

**Files to create/modify**:
- [ ] Server code (e.g., `Infrastructure/<name>-server.js` or `<name>-server.py`)
- [ ] `docs/Reference/API-Standards.md` — update per-container status table

---

### § 3. Dockerfile

Place at `Infrastructure/<name>.Dockerfile`. Conventions:

- **Base image**: Alpine-based. Pin digest — never use `:latest`.
- **Non-root user**: `USER ORCHESTRATOR` with `cap_drop ALL` and `security_opt: no-new-privileges`
- **HEALTHCHECK**: Dockerfile-level health check that curls `/api/health`
- **Dependencies**: Monorepo `npm install` for Node.js MCP servers (no separate `package.json` in the service dir unless unique dependencies are needed)

```dockerfile
FROM node:20-alpine@sha256:<pinned-digest>

WORKDIR /app

RUN apk add --no-cache curl && \
    adduser -D -u 1001 ORCHESTRATOR

RUN npm install express @modelcontextprotocol/sdk express-rate-limit

COPY Infrastructure/auth/ /app/auth/
COPY Infrastructure/<name>-server.js /app/

RUN chown -R ORCHESTRATOR:ORCHESTRATOR /app

USER ORCHESTRATOR

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=15s \
    CMD curl -sf http://localhost:<port>/api/health || exit 1

EXPOSE <port>
CMD ["node", "/app/<name>-server.js"]
```

If an entrypoint script is needed for secret hydration, use `ENTRYPOINT` instead of `CMD`.

**Test the Dockerfile** — before building for the fleet, verify it builds locally:
```powershell
docker build -f Infrastructure/<name>.Dockerfile -t <name>:test .
docker run --rm -d -p <port>:<port> --name <name>-test <name>:test
curl http://localhost:<port>/api/health
docker stop <name>-test
```

**Files to create**:
- [ ] `Infrastructure/<name>.Dockerfile`
- [ ] `Infrastructure/entrypoint-<name>.sh` (if secret hydration is needed)

---

### § 4. Secret Bundle

If the container needs API keys or credentials:

**a. Bundle manifest** — Add to `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1`:

```powershell
<Name> = @{
    BundleName = "<name>_secrets_bundle"
    Suffix     = "<name>_secrets_bundle"
    Required   = @()
    Optional   = @('my_api_key', 'my_other_key')
    EnvMap     = @{
        'my_api_key'   = 'MY_API_KEY'
        'my_other_key' = 'MY_OTHER_KEY'
    }
    SourceKeys  = @('MY_API_KEY', 'MY_OTHER_KEY')
}
```

**b. Fleet API token** — Add a ServiceToken entry in the same manifest:
```powershell
<NAME> = @{
    BoundServices = @('<name>')
    Audience      = '<name>'
}
```

Add the token env var to the `ServiceTokens` hashtable:
```powershell
is_<name> = "FLEET_API_TOKEN_<NAME>"
```

**c. Publish function** — Create `SalmonRun.Secrets/Public/Publish-<Name>Secrets.ps1` that reads source env vars and builds the bundle JSON. Follow the pattern from existing publish functions.

**d. Entrypoint hydration** — If the container reads env vars directly from the shell, create an entrypoint script that parses the bundle JSON and exports vars. If using Node.js `readSecret()` pattern (reading `process.env` directly), no shell script is needed.

**Files to create/modify**:
- [ ] `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1`
- [ ] `Skills/Docker/Modules/SalmonRun.Secrets/Public/Publish-<Name>Secrets.ps1`
- [ ] `Infrastructure/entrypoint-<name>.sh` (if needed)

---

### § 5. Image Build Function

Create `Skills/Docker/Modules/SalmonRun.Images/Public/Invoke-<Name>ImageBuild.ps1`:

- Parameter: `$TargetDir`
- Dockerfile path: `Join-Path $TargetDir "Infrastructure" "<name>.Dockerfile"`
- Image tag: `<name>:local`
- Source-hash label: `org.interclaw.<name>.source-hash`
- Build: `docker build -f $DockerfilePath -t "<name>:local" --label "org.interclaw.<name>.source-hash=$SourceHash" .`

Then wire it into `Start-ParallelImageBuild.ps1` so the fleet builds it during deployment.

**Files to create/modify**:
- [ ] `Skills/Docker/Modules/SalmonRun.Images/Public/Invoke-<Name>ImageBuild.ps1`
- [ ] `Skills/Docker/Modules/SalmonRun.Images/Public/Start-ParallelImageBuild.ps1`

---

### § 6. Compose Entry

Add a service definition to `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1`, gated by a feature flag:

```powershell
if ($Install<Name> -eq "true") {
    $Port = Get-ServicePort -Service "<name>" -Type "internal"
    $Service = [ordered]@{
        image        = "<name>:local"
        hostname     = "${ProjectCode}-<name>"
        dns          = @("8.8.8.8", "1.1.1.1")
        networks     = @((Get-NetworkNames).ServiceNet)
        deploy       = [ordered]@{ resources = [ordered]@{...}; restart_policy = [ordered]@{...} }
        healthcheck  = [ordered]@{ test = @("CMD", "curl", "-sf", "http://localhost:${Port}/api/health"); ... }
        ports        = @("127.0.0.1:${Port}:${Port}")   # only if host-published
        secrets      = @(
            @{ source = "FLEET_API_TOKEN_<NAME>"; target = "fleet_api_token" }
            @{ source = "FLEET_API_TOKEN_MONITOR"; target = "fleet_monitor_token" }
        )
        cap_drop     = @("ALL")
        security_opt = @("no-new-privileges:true")
    }
    if ($Install<Name>Secrets) {
        $Service.secrets += @{ source = "<name>_secrets_bundle"; target = "<name>_secrets_bundle" }
    }
    $Compose.services["<name>"] = $Service
}
```

Add the feature flag to `deploy.ps1` configuration parameters (`$FleetFeatureFlags`) and to `install.json` schema validation.

**Health check `$$` escaping**: If the healthcheck command includes `$` for shell variables (e.g., `$(cat /run/secrets/...)`), escape every `$` as `$$` in the compose template — Docker Compose's variable substitution interprets unescaped `$` references.

**Files to modify**:
- [ ] `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1`
- [ ] `Skills/Docker/deploy.ps1` — add feature flag to `$FleetFeatureFlags`
<!-- doc-lint: exempt -->
- [ ] `Configuration/install.json.schema.json` — add feature flag to schema (if schema exists)
- [ ] `Infrastructure/manifests/docker-manifest.json` — add bundle entry if secrets are used

---

### § 7. opencode.json MCP Registration (SSE Only)

If the container exposes an MCP-over-SSE endpoint, register it in `Infrastructure/opencode/config/opencode.json`:

```json
"<name>": {
    "type": "sse",
    "url": "http://<name>:<port>/mcp/sse",
    "enabled": true,
    "timeout": 60000
}
```

The key name in opencode.json becomes the Docker DNS hostname that `entrypoint.sh` uses to inject auth tokens. Use underscores matching the token map (see § 8).

**Files to modify**:
- [ ] `Infrastructure/opencode/config/opencode.json`

---

### § 8. Token Header Injection

If the container has MCP tools that need fleet auth, add a token mapping in `Infrastructure/opencode/entrypoint.sh`:

```js
'<name>': 'FLEET_API_TOKEN_<NAME>',
```

The key name here must match the key used in `opencode.json` (step § 7).

**Files to modify**:
- [ ] `Infrastructure/opencode/entrypoint.sh`

---

### § 9. AWS SM Secret Hydration

If the container needs secrets from AWS Secrets Manager:

1. Ensure the secret exists in AWS SM (ca-central-1 region).
2. Verify it's referenced in the deploy pipeline's hydration step (`deploy.ps1 -Phase DockerSecrets` → `SalmonRun.Secrets`).
3. Add to the bundle manifest's `SourceKeys` array so it's hydrated from AWS SM.

**Files to modify**:
- [ ] `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` — ensure `SourceKeys` includes the new secret

---

### § 10. Bind Mounts (if needed)

If the container needs host filesystem access:

1. Add mount entries to `Infrastructure/mount-registry.json` under `bind_mounts`:
   ```json
   "<service-name>": [
       { "host": "${DEPLOY_REPO_ROOT}/some/path", "container": "/container/path", "type": "data", "purpose": "Description" }
   ]
   ```
2. Add `volumes` to the compose entry in `New-FleetCompose.ps1`.
3. Ensure the host directory is created in `Initialize-AgentVolumes.ps1`.

**Files to modify**:
- [ ] `Infrastructure/mount-registry.json`
- [ ] `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1`
- [ ] `Skills/Docker/Modules/SalmonRun.Deploy/Public/Initialize-AgentVolumes.ps1`

---

### § 11. Fleet Topology Documentation

Update `Skills/DevOps/Fleet/fleet-topology.md`:

- **Service inventory table**: Add the new service row (Service, Name, Role, Network, Notes)
- **Credential mounts table**: If the service uses secrets, add its row
- **Bind mounts table**: If the service has bind mounts, add its row

**Files to modify**:
- [ ] `Skills/DevOps/Fleet/fleet-topology.md`

---

### § 12. Compose Skill Table

Update `Skills/DevOps/Fleet/compose/SKILL.md` — add the new service to the service topology table with its port, bundle, health check, and feature flag.

**Files to modify**:
- [ ] `Skills/DevOps/Fleet/compose/SKILL.md`

---

### § 13. Image Inventory Table

Update `Skills/DevOps/Fleet/images/SKILL.md` — add the new image to the image inventory table (Dockerfile, build function, base image, rebuild trigger).

**Files to modify**:
- [ ] `Skills/DevOps/Fleet/images/SKILL.md`

---

### § 14. ADR Record (if architecturally significant)

If the new container introduces a new service category, a new technology stack, or a significant architectural pattern, create or update an ADR:

- Add entry to `docs/Reference/Decisions/README.md`
- Create ADR document following existing conventions

**Files to create/modify**:
- [ ] `docs/Reference/Decisions/`

---

### § 15. API Contracts Documentation

If the container exposes REST endpoints beyond the standard health endpoints, document them:

- Add to `docs/Reference/API-Contracts.md` or create a service-specific contract section

**Files to modify**:
- [ ] `docs/Reference/API-Contracts.md`

---

### § 16. First Build & Health Verification

After all code is written, do a first build and manual verification:

```powershell
# Build the image
docker build -f Infrastructure/<name>.Dockerfile -t <name>:test .

# Run it with port mapping
docker run --rm -d -p <port>:<port> --name <name>-test <name>:test

# Verify health endpoint
curl http://localhost:<port>/api/health

# Verify other standard endpoints
curl http://localhost:<port>/api/ready
curl http://localhost:<port>/api/routes
curl http://localhost:<port>/api/version
curl http://localhost:<port>/tools/list

# If MCP SSE, verify SSE connect
curl -N http://localhost:<port>/mcp/sse

# Test error envelope
curl http://localhost:<port>/api/nonexistent
# Expected: {"error":"NOT_FOUND","message":"..."}

# Cleanup
docker stop <name>-test
```

- [ ] Image builds successfully
- [ ] Health endpoint returns 200 with expected schema
- [ ] All standard endpoints respond
- [ ] Error responses use standard envelope
- [ ] Container starts cleanly (logs show no errors)
- [ ] CORS headers present on responses
- [ ] Request logging in structured JSON format

---

### § 17. Clean Up After Yourself

If the container has client-side code, scripts, or companion files:

- [ ] Add reference to `Skills/skills-index.json` if the container comes with skills or utilities
<!-- doc-lint: exempt -->
- [ ] Add reference to `Skills/ORCHESTRATOR/Skills/Workflows/Shared/tools.md` if the container exposes new tools
- [ ] Update `AGENTS.md` file tables if applicable
- [ ] Remove any temp/test artifacts (test containers, local test images)

---

## Reference: Complete File Change Summary

| # | What | File | Condition |
|---|------|------|-----------|
| 1 | Port registry | `Infrastructure/port-registry.json` | Always |
| 2 | Health endpoints | Server source code | If HTTP server |
| 3 | Dockerfile | `Infrastructure/<name>.Dockerfile` | Always |
| 3b | Entrypoint script | `Infrastructure/entrypoint-<name>.sh` | If secret hydration needed |
| 4 | Bundle manifest | `SalmonRun.Secrets/Private/bundle-manifest.ps1` | If secrets needed |
| 4b | Bundle publish function | `SalmonRun.Secrets/Public/Publish-<Name>Secrets.ps1` | If secrets needed |
| 5 | Image build function | `SalmonRun.Images/Public/Invoke-<Name>ImageBuild.ps1` | Always |
| 5b | Parallel build wiring | `Start-ParallelImageBuild.ps1` | Always |
| 6 | Compose entry | `New-FleetCompose.ps1` | Always |
| 6b | Feature flag schema | `install.json.schema.json` + `deploy.ps1` | Always |
| 7 | MCP registration | `Infrastructure/opencode/config/opencode.json` | Default (MCP SSE) |
| 8 | Token injection | `Infrastructure/opencode/entrypoint.sh` | Default (MCP SSE) |
| 9 | AWS SM hydration | Bundle manifest `SourceKeys` | If secrets from AWS SM |
| 10 | Bind mounts | `mount-registry.json` + `Initialize-AgentVolumes.ps1` | If host FS access |
| 11 | Fleet topology | `fleet-topology.md` | Always |
| 12 | Compose skill table | `compose/SKILL.md` | Always |
| 13 | Image inventory | `images/SKILL.md` | Always |
| 14 | ADR | `docs/Reference/Decisions/` | If architecturally significant |
| 15 | API contracts | `docs/Reference/API-Contracts.md` | If custom REST endpoints |
| 16 | First build & verify | Manual test | Always |
| 17 | Cleanup | Various | Always |

---

## Common Mistakes & Red Lines

- **Missing port registration** — `Get-ServicePort` will throw "Service not found". Always update port-registry.json before compose generation.
- **Unescaped `$` in healthcheck strings** — Docker Compose treats `$` as variable interpolation. Use `$$` for literal `$` in compose templates. See `compose/SKILL.md ┬º Lessons Learned` for the full bug story.
- **Secrets with trailing `\r\n`** — Docker secrets on Windows can carry `\r` characters. Always `tr -d '\r\n' < /run/secrets/<name>` before using a secret in a URL or HTTP header.
- **HEALTHCHECK vs healthcheck** — Dockerfile-level `HEALTHCHECK` is overridden by compose-level `healthcheck` in Swarm mode. Define both: the Dockerfile one for `docker run`, the compose one for Swarm.
- **No global rate limiter** — Every service making external API calls MUST include `express-rate-limit` (Node.js) or equivalent. Without it, one misbehaving agent can exhaust upstream API quotas.
- **No per-agent rate limiter** — MCP servers should track per-session or per-agent request counts to prevent one agent from starving others.
- **Skipping audit logging** — Every HTTP server should log structured JSON to stdout + audit file. The `SalmonRun.Audit` compliance chain depends on this.
- **Hardcoded API URLs** — Always read API base URLs from env vars with sensible defaults. This enables mock-server injection during testing and graceful version upgrades.
- **Missing `fleet-auth.cjs` middleware** — All REST endpoints (except `/api/health`) must authenticate through the fleet-auth middleware.
- **SSRF in URL-accepting MCP tools** — Always validate external URLs with `new URL()` and reject non-HTTP(S) schemes.
- **Image name constant drift** — The image tag in the build function must match the tag in the compose entry and the constant module. Test the round-trip.
- **Missing AGENTS.md/.git marker in container images** — `Get-ORCHESTRATORRepoRoot` (in `SalmonRun.Paths`) walks up from `$PSScriptRoot` looking for `AGENTS.md` or `.git`. Inside a Docker image, neither exists, so the function returns empty string. Fix: either (a) set `$env:REPO_ROOT` in the entrypoint before calling `Import-ORCHESTRATORModule`, or (b) add a `COPY AGENTS.md` or `.repo-root` marker to the Dockerfile. The `$env:REPO_ROOT` fallback was added to `Get-ORCHESTRATORRepoRoot` to handle this.
- **Missing COPY of Infrastructure files in Dockerfile** — The tempo Dockerfile originally only copied `Skills/Docker/1Tempo.ps1` and `Skills/Docker/Modules/`. It didn't copy `Infrastructure/port-registry.json`, causing port lookups to fail. Include all `Infrastructure/` files the entrypoint needs.
- **Static compose file drift** — When adding a new service, the generated compose (from `Add-SidecarServicesToCompose.ps1`) is correct, but the static `docker-compose.interclaw.yml` also needs updating. Both must be in sync for `docker stack deploy -c` to work without the generation pipeline.
- **Tempo uses an empty secret bundle** — Services that need no secret keys still need a bundle entry in `bundle-manifest.ps1` with `Required = @()` and `Optional = @()`. The bundle is created as `{}` and the `Set-ContainerSecretBundle` function handles empty entries gracefully.
- **`ENTRYPOINT` must match shell dialect** — If the entrypoint script uses bash-specific syntax (`${!VAR}`, `&>/dev/null`), the compose `entrypoint` must invoke `/bin/bash`, not `/bin/sh`. On Debian, `/bin/sh` is dash, which rejects bashisms with "Bad substitution". Use POSIX-compatible syntax (`eval "_val=\"\${$_var}\""`, `>/dev/null 2>&1`) if the entrypoint must run under `/bin/sh`.
- **`process.argv[2]` for bundle path** — In Node.js heredoc scripts inside shell entrypoints that are called via `node script.js /path/to/bundle`, the bundle path is `process.argv[2]` (argv[1] is the script file path). This applies to all three entrypoint scripts: `entrypoint.sh`, `entrypoint-web-mcp.sh`, and any new entrypoint using the standard bundle hydration pattern.
- **No nested `Start-Job` on Linux background jobs** — When a PowerShell `Start-Job` starts another `Start-Job`, the inner job is a child process. When the outer job's script block completes (even if the inner job is non-blocking), the outer pwsh process exits, killing the orphaned inner process. On Windows this doesn't happen because jobs share a process. Fix: run the HTTP listener inline in the outer job — the blocking `while` loop keeps the process alive.
- **`PSModulePath` separator is platform-specific** — Linux uses `:`, Windows uses `;`. Use `[System.IO.Path]::PathSeparator` instead of hardcoded `";"` in scripts that run inside Linux containers.

---

## Cross-References

- `Skills/DevOps/Fleet/create-mcp/SKILL.md` — Deep-dive for MCP-over-SSE servers (code templates, auth, secret bundle cookbook)
- `Skills/DevOps/Fleet/compose/SKILL.md` — Compose generation, feature flags, service topology table
- `Skills/DevOps/Fleet/images/SKILL.md` — Image build orchestration, inventory, Dockerfile conventions
- `Skills/DevOps/Fleet/secrets/SKILL.md` — Secret bundle lifecycle
- `Skills/DevOps/Fleet/deploy-fleet/SKILL.md` — Deploy pipeline, re-run guidance
- `Skills/Fleet&DevOps/secret-bundle-cookbook.md` — Bundle pipeline deep-dive
- `docs/Reference/API-Standards.md` — Common endpoint specs, error envelope, adoption checklist
- `docs/Reference/API-Contracts.md` — Service-specific API contracts
- `Infrastructure/port-registry.json` — Port allocation scheme
- `Infrastructure/mount-registry.json` — Bind mount registry
- `Infrastructure/opencode/config/opencode.json` — MCP server registration
- `Infrastructure/opencode/entrypoint.sh` — Token header injection
- `Skills/DevOps/Fleet/fleet-topology.md` — Canonical service topology reference
- `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` — Bundle manifest schema
- `Skills/Docker/Modules/SalmonRun.Images/Public/` — Image build function patterns
- `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1` — Compose generation source
- `docs/Reference/Decisions/README.md` — ADR index

---

## Changelog

- 2026-07-12: Added lessons: ENTRYPOINT shell dialect (bash vs sh), process.argv[2] for bundle path, nested Start-Job on Linux, PSModulePath platform separator
- 2026-06-26: Initial version — 18-step checklist covering port registry → health endpoints → Dockerfile → secrets → image build → compose → MCP registration → token injection → documentation → verification → cleanup
