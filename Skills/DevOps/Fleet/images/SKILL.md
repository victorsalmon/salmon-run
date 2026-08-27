# Skill: Images

**Purpose**: Docker image build orchestration for the fleet — image inventory, build functions, parallel build patterns, Dockerfile conventions, and rebuild triggers.

**Trigger**: "build images", "rebuild service X", "image build failed", "add a new Dockerfile", "update image"

---

## Image Inventory

| Image | Dockerfile | Build Function | Base Image | Rebuild Trigger |
|-------|-----------|---------------|------------|----------------|
| `is-api` (proxy) | `Infrastructure/api-proxy.Dockerfile` | `Invoke-ProxyImageBuild` | Alpine-based | Proxy module changes, API handler changes |
| `opencode` | N/A (pulled from registry) | `Invoke-OpencodeImageBuild` | `opencode/opencode:latest` | opencode version bump, entrypoint/config changes |
| `docusign` | `intersite-docs/Docusign/server/docusign.Dockerfile` | `Invoke-DocusignImageBuild` | Alpine-based | Docusign service changes |
| `mcp_browserless` | `Infrastructure/mcp_browserless.Dockerfile` | `Invoke-McpBrowserlessImageBuild` | `browserless/chrome:latest` | Browserless version or skill updates |
| `mcp_aqe` | retired - no Dockerfile | ~~`Invoke-McpAqeImageBuild`~~ | - | Retired 2026-08-21; quality engineering via the cross-harness `/aqe` skill (`Skills/AQE/SKILL.md`) |
| `mcp_web` | retired - no Dockerfile | ~~`Invoke-McpWebImageBuild`~~ | - | Retired 2026-08-22; web research via the cross-harness `/web-research` skill (`Skills/DevOps/Web/SKILL.md`); rent tracking moved to `upscale-havens/backend` (`/api/rent/*`) |
| `is-bookkeeping` | retired — no Dockerfile | ~~`Invoke-BookkeepingImageBuild`~~ | — | Retired 2026-08-21; shared assets moved to `Skills/Bookkeeping/`; use `Plugins/reconcile-account` tools and `Skills/Bookkeeping/handlers/SalmonRun.Bookkeeping` |
| `funnel-proxy` | `Infrastructure/funnel-proxy.Dockerfile` | `Invoke-FunnelProxyImageBuild` | Alpine-based | Funnel proxy changes |

---

## Build Orchestration

### Parallel builds
`Start-ParallelImageBuild` orchestrates all image builds in parallel. It:
1. Determines which images need building based on fleet configuration (feature flags, changed files)
2. Launches each `Invoke-*ImageBuild` function as a parallel job
3. Collects results and reports failures
4. Used by `1Deploy.ps1` and `deploy.ps1 Phase 11` (FleetDeploy)

```powershell
# Build all images
Start-ParallelImageBuild

# Build specific images
Start-ParallelImageBuild -ImageNames @("sentry", "is-api")
```

### Individual build functions
Each `Invoke-*ImageBuild` function:
1. Reads source hash from `Get-ImageSourceHash` for cache-busting labels
2. Runs `docker build` with the correct Dockerfile, context, and tags
3. Tags as `:local` for development, with source-hash label for change detection
4. Outputs build logs for debugging

```powershell
# Build a single image
Invoke-SentryImageBuild
```

---

## Dockerfile Conventions

All fleet Dockerfiles follow these conventions:

- **Base**: Alpine-based (except `mcp_browserless` which uses `browserless/chrome`)
- **Digests**: Base image digests are pinned — never use `:latest`
- **HEALTHCHECK**: Every image includes a `HEALTHCHECK` instruction (Dockerfile-level, though compose-level overrides it in Swarm)
- **User**: `USER ORCHESTRATOR` (non-root) with `cap_drop ALL` and `--no-new-privileges`
- **Labels**: Source-hash labels for change detection via `Get-ImageSourceHash`

---

## When to Rebuild

| Change Type | Rebuild Needed? |
|------------|----------------|
| Code changes (modules, handlers) | Yes — rebuild affected image |
| Dependency changes (package.json, requirements.txt) | Yes — rebuild and update base digest |
| Base image CVE fix | Yes — rebuild and update pinned digest |
| Config-only (environment variables, compose) | No — config change doesn't touch image |
| Skill/doc changes only | No — skills are mounted as volumes |
| Entrypoint script changes | Yes — entrypoint is baked into the image |

---

## Red lines

- **Never use `latest` tags** — always pin base image digests for reproducible builds.
- **Never run `docker build` manually** during deploy — use `Start-ParallelImageBuild` for consistent orchestration.
- **Never skip the HEALTHCHECK** — every image must define one. Compose-level health checks override Dockerfile-level ones in Swarm mode.
- **Image builds require Docker** — ensure Docker Desktop is running before any build operation.
- **opencode image is pulled, not built locally** — `Invoke-OpencodeImageBuild` pulls the pre-built image from the opencode registry.

---

## Cross-References

| Resource | Description |
|----------|-------------|
| `Skills/Docker/Modules/SalmonRun.Images/` | Image build module — all `Invoke-*ImageBuild` functions |
| `Skills/DevOps/Fleet/compose/SKILL.md` | Compose generation — how built images become services |
| `Infrastructure/*.Dockerfile` | Dockerfile source files |
