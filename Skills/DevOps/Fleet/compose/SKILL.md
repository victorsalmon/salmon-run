# Skill: Compose

**Purpose**: Docker Compose generation for the fleet stack — `New-FleetCompose.ps1` flow, feature flags, service topology table, adding a new service, and constraints.

**Trigger**: "regenerate compose", "add a service to the stack", "compose generation failed", "feature flag for service X", "edit compose"

---

## Compose Generation Flow

The compose file is dynamically generated — never edited by hand.

1. `New-FleetCompose.ps1` reads agent configurations, feature flags, and the bundle manifest
2. Builds an ordered hashtable with `version`, `services`, `networks`, `volumes`, `secrets`, and `configs`
<!-- doc-lint: exempt -->
3. Outputs `Infrastructure/docker-compose.interclaw.yml` at the repo root
4. Validated by `docker stack deploy --compose-file docker-compose.interclaw.yml`

```powershell
# Called from 1Deploy.ps1 during deployment
New-FleetCompose -Agents $AgentConfigs -ProjectCode $ProjectCode
```

### Feature Flags

Services are gated by feature flag parameters passed to `New-FleetCompose`:

| Flag | Default | Purpose |
|------|---------|---------|
| `InstallSentry` | `true` | Include the sentry monitoring service |
| `InstallTailscale` | `false` | Include Tailscale sidecar |
| `InstallDocusign` | `false` | ~~Include Docusign service~~ Retired 2026-08-19 |
| `InstallBrowserless` | `false` | Include browserless automation service |
| `InstallWebMcp` | `false` | ~~Include Web MCP service (Tavily, Firecrawl)~~ Retired 2026-08-22; use the cross-harness `/web-research` skill |
| `InstallBookkeeping` | `false` | Include Bookkeeper bookkeeping service |
| `InstallAqe` | `true` | Include AQE quality engineering service |
| `InstallFunnel` | `false` | Include funnel proxy service |

---

## Service Topology

| Compose Service | Image | Internal Port | Networks | Secrets Bundle | Health Check | Feature Flag |
|----------------|-------|---------------|----------|---------------|-------------|-------------|
| `oc-orch-N` | `opencode:local` | 21000 (mcp) / 20100+ (gateway) | `ORCHESTRATOR_overlay` + `ORCHESTRATOR_agent` | `agent_secrets_bundle` | `/api/health` | Always (per-agent) |
| `oc-veri-N` | `opencode:local` | 21000 (mcp) / 20200+ (gateway) | `ORCHESTRATOR_overlay` + `ORCHESTRATOR_agent` | `agent_secrets_bundle` | `/api/health` | Always (per-agent) |
| `oc-base-N` | `opencode:local` | 21000 (mcp) / 20300+ (gateway) | `ORCHESTRATOR_overlay` + `ORCHESTRATOR_agent` | `agent_secrets_bundle` | `/api/health` | Always (per-agent) |
| `is-fleet` | `sentry:local` | 21002 / 29999 (host) | `ORCHESTRATOR_overlay` | `sentry_secrets_bundle` | `/api/health` | `InstallSentry` |
| `mcp_opencode` | `opencode:local` | 21000–21001 | `ORCHESTRATOR_overlay` | `coding_secrets_bundle` | `/api/health` | Always |
| `mcp_browserless` | `mcp_browserless:local` | 3003 | `ORCHESTRATOR_overlay` | `proxy_secrets_bundle` | `/pressure?token=$TOKEN` | `InstallBrowserless` |
| `mcp_aqe` | `mcp_aqe:local` | 21004 | `ORCHESTRATOR_overlay` | `coding_secrets_bundle` | `/api/health` | `InstallAqe` |
| `mcp_web` | ~~`mcp_web:local`~~ | ~~21005~~ | `ORCHESTRATOR_overlay` | ~~`web_mcp_secrets_bundle`~~ | `/api/health` | ~~`InstallWebMcp`~~ (retired 2026-08-22; use `/web-research`) |
| `mcp_docusign` | ~~`docusign:local`~~ | 21007 | `ORCHESTRATOR_overlay` | `docusign_secrets_bundle` | `/health` | ~~`InstallDocusign`~~ (retired 2026-08-19) |
| `is-bookkeeping` | ~~`bookkeeping:local`~~ | 21008 | `ORCHESTRATOR_overlay` | `bookkeeping_secrets_bundle` | `/api/health` | ~~`InstallBookkeeping`~~ (retired 2026-08-21; use `Skills/Bookkeeping/` and `Plugins/reconcile-account`) |
| `ops-funnel-proxy` | `funnel-proxy:local` | 21009 | `ORCHESTRATOR_overlay` | `proxy_secrets_bundle` | `/api/health` | `InstallFunnel` |

---

## Adding Bind Mounts to Agent Services

Agent services (oc-orch, oc-veri, oc-base) use named volumes for config and persistence by default. To add a host bind mount:

1. **Get the repo root** via `Get-ORCHESTRATORRepoRoot` (same pattern as sentry bind mounts in `New-FleetCompose.ps1`).
2. **Append to `$Service.volumes`** inside the agent service definition loop (after the ORCH/VERI conditional block at line 157).
3. **Ensure the host directory exists** by adding directory creation to `Initialize-AgentVolumes.ps1`.

```powershell
# Inside New-FleetCompose.ps1, agent service loop, ORCH/VERI block:
if ($Agent.Role -eq "ORCH" -or $Agent.Role -eq "VERI") {
    $RepoRoot = Get-ORCHESTRATORRepoRoot
    $Service.volumes += "${RepoRoot}/some/path:/container/path"
}
```

4. **Document** all mounts (bind + named volumes) in `Infrastructure/mount-registry.json`.

| Mount type | Config location | Documentation |
|------------|----------------|---------------|
| Named volumes | `$Service.volumes` array (line 125) | `mount-registry.json` § `named_volumes` |
| Host bind mounts | `$Service.volumes` append (ORCH/VERI block, line 164) | `mount-registry.json` § `bind_mounts` |
| Fleet bind mounts | Sentry block (line 202) | `mount-registry.json` § `bind_mounts.is-fleet` |

---

## Adding a New Service
   ```powershell
   if ($InstallXxx -eq "true") {
       $Compose.services["my-service"] = [ordered]@{
           image      = "my-image:local"
           networks   = @("ORCHESTRATOR_overlay")
           secrets    = @("my_secrets_bundle")
           deploy     = [ordered]@{ ... }
           healthcheck = [ordered]@{ ... }
       }
   }
   ```
3. **Add secret mounts**: If the service needs secrets, add the bundle reference and ensure the bundle type exists in `bundle-manifest.ps1`.
4. **Register port**: Add the internal port to `Infrastructure/port-registry.json` under `internal`.
5. **Add health check**: Every service must expose `/api/health` (or equivalent) with a compose-level `healthcheck`.
6. **Test generation**: Run `New-FleetCompose` and verify the output YAML is valid.

---

## Red lines

- **Never edit `docker-compose.interclaw.yml` by hand** — it is auto-generated. Changes must go through `New-FleetCompose.ps1`.
- **Always add feature flags** for new services — gating prevents breaking existing deployments.
- **Never expose internal ports to the host** — host mappings, where required for operational access (tooling/health), MUST be loopback-only (`127.0.0.1:<port>:<port>`). Internal (`21000-21999`) stay on the overlay network; bare `<port>:<port>` mappings (which publish to all host interfaces) are prohibited. Gateway ports (`20100-39900`) are published as needed.
- **Secrets bundles must exist before compose generation** — run `deploy.ps1 -Phase DockerSecrets` first if adding a new bundle.
- **Port registry must match reality** — `Get-ServicePort` reads `Infrastructure/port-registry.json`. Verify the registry entry matches the actual service port.

---

## Cross-References

| Resource | Description |
|----------|-------------|
| `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1` | Compose generation source |
| `Infrastructure/port-registry.json` | Port allocation registry |
| `Infrastructure/mount-registry.json` | Mount registry (bind mounts + named volumes) |
<!-- doc-lint: exempt -->
| `Infrastructure/docker-compose.interclaw.yml` | Generated compose file (read-only) |
| `Skills/DevOps/Fleet/images/SKILL.md` | Image build orchestration — images referenced by compose |
| `Skills/DevOps/Fleet/deploy-fleet/SKILL.md` | Deploy pipeline — how compose is deployed to Swarm |
| `Skills/Cowork/RunFix/runfix-deploy.md` | Redeploy skill — when compose healthchecks fail after a deploy |

## Changelog
- 2026-06-20: Added bind mount pattern for agent services; documented mount-registry.json in cross-refs

### Lessons Learned — 2026-06-14

**What Didn't Work**:
- **Unquoted healthcheck strings lose their shell command structure to Compose variable interpolation**: The browserless healthcheck was written as an unquoted YAML scalar: `TOKEN=$(cat /run/secrets/fleet_api_token 2>/dev/null); ...`. Docker Compose v2 processes unquoted strings the same as quoted ones for variable interpolation — it saw `$(cat /run/secrets/...)` as a variable reference attempt, stripped the `$`, and left the literal `TOKEN=(cat /run/secrets/...)`. The dash shell inside the container rejected the malformed `(` as a syntax error, and the healthcheck failed 3 times in a row → 1-minute crash loop. **Always escape every `$` in healthcheck strings as `$$` so Compose passes the literal through.**
- **Docker secrets can contain Windows line endings**: A secret written via `ConvertTo-SecureString $string -AsPlainText -Force` followed by `Set-SwarmSecretSafe` round-trips the string exactly as PowerShell received it. If the source string ended with `\r\n` (or even just `\r`), the file mounted at `/run/secrets/<name>` inside the container has the same trailing characters. When a healthcheck constructs a URL with the secret value (e.g., `?token=$TOKEN`), the `\r` corrupts the URL and curl exits 3 ("URL malformed"). **Always `tr -d '\r\n' < /run/secrets/<name>` before using a secret in a URL or HTTP header.**
- **Image-name constants in source code drift from build tags**: `SalmonRun.Constants.SentryImage` was set to `is-fleet:local`, but the corresponding `Invoke-SentryImageBuild.ps1` tags the image as `sentry:local`. Both were correct in isolation, but the mismatch was invisible until `docker stack deploy` rolled the running service to the wrong image and Swarm rejected it with "No such image: is-fleet:local". Pester tests on the constant module only assert non-null — they don't round-trip a build tag back to the constant. **Image-name constants are the interface between two modules (constant module + image-build module); the contract should be tested end-to-end.**

**Improvements for next run**:
- Add a pre-commit lint that scans every `healthcheck.test` block in the generated compose for un-escaped `$(` and `$` (where the value is not a Compose variable). Warn or fail on raw `$(...)` or `$\w+` patterns inside healthcheck strings.
- Add a pre-commit lint that, for every `image:` reference in the generated compose, verifies the referenced tag exists in `docker images` (or, more practically, in the `Images` module's expected-tag table).
- When adding a new healthcheck that uses a secret, always template the command as `tr -d '\r\n' < /run/secrets/<name>` for the token extraction — never assume the secret is clean. Add a Pester test that runs the healthcheck against a docker run with a `\r`-suffixed secret value and verifies the URL is still valid.
- Document the canonical Compose variable-escape pattern in a top-of-file comment in `New-FleetCompose.ps1`, with a one-line example. Every healthcheck string template should reference the same pattern.

**Helpful Information**:
- `docker service inspect <svc> --format '{{json .Spec.TaskTemplate.ContainerSpec.Healthcheck.Test}}'` returns the post-interpolation healthcheck string. When a deploy says the healthcheck failed but the template looks correct, this command shows the *actual* command Swarm is running — and the difference between template and reality is the bug.
- Docker Compose's variable substitution list (for unquoted strings too): `$VAR`, `${VAR}`, `$$` (literal `$`). `$(...)` is *not* a Compose syntax, but Compose's substitution logic still tries to interpret it as a variable reference starting with `$` and may strip the `$(` if the parens are followed by characters that don't form a valid variable name.
- The dash shell (`/bin/sh` in Debian) does not parse bash array assignment syntax. `TOKEN=(cat ...)` errors with `Syntax error: '(' unexpected`. Always use `VAR=$(cmd)` form for healthcheck strings.
- Browserless's `TOKEN` env var is a built-in feature: when set, every API request (including the healthcheck) must include `?token=<value>`. When not set, the token is not required. The current healthcheck pattern (`if [ -n "$TOKEN"]; then ...; else ...; fi`) handles both cases — but only after `tr -d '\r\n'` has cleaned the token value.
| `Skills/DevOps/Fleet/secrets/SKILL.md` | Secret bundles referenced by compose services |
