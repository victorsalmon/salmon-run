# Skill: Secrets

**Purpose**: Full secret lifecycle for the fleet — AWS SM storage, caching, hydration, Docker Swarm secret injection, bundle types, and rotation procedures.

**Trigger**: "add a secret", "rotate API key", "secret not found", "hydration failed", "how do secrets work", "add coding key"

---

## Secret Pipeline (5 Stages)

### 1. Storage — AWS Secrets Manager

All secrets originate in AWS Secrets Manager, region `ca-central-1`. Each secret is stored as a JSON object with key-value pairs. The fleet uses AWS SM as the single source of truth — secrets are never committed to the repo.

- **Master provisioning secret**: Created by `1Provision.ps1` during initial deployment. Contains the gateway token, Telegram bot tokens, OpenRouter keys, and third-party API keys.
- **Per-service secrets**: Individual secrets for coding keys (`opencode_go_key1`–`key5`), Docusign SMTP credentials, Tailscale auth key, etc.
- **Read-only policy**: Agents have READ-ONLY access to AWS SM. Never write to AWS SM — see constraints below.

### 2. Caching

`Get-SecretFromAws` caches retrieved secrets in `$SecretCache` (script-scoped hashtable). Subsequent calls within the same session use the cache instead of making redundant API calls. `Clear-SecretCache` resets it explicitly.

### 3. Hydration

Hydration is the process of reading secrets from AWS SM and creating Docker Swarm secrets:

1. `Import-SecretsFromAws` — Reads the master provisioning secret and resolves all required/optional keys from AWS SM
2. `Publish-*Secrets` functions — Each bundle type has a dedicated publish function (e.g., `Publish-CodingKeySecrets`, `Publish-WebMcpSecrets`)
3. `Set-SwarmSecretSafe` — Creates the Docker Swarm secret with proper naming

Hydration is invoked during `deploy.ps1` Phase 10 (DockerSecrets) and can be triggered manually via `1Provision.ps1 -Phase Secrets`.

### 4. Injection — Docker Swarm Secrets

Hydrated secrets become Docker Swarm secrets mounted as files at `/run/secrets/<bundle_name>` inside each container. The bundle is a JSON file containing all required and optional keys for that service.

The container's `entrypoint.sh` reads the bundle JSON and exports each key as an environment variable using the EnvMap defined in the bundle manifest. Optional keys that are absent are skipped with `$ErrorAction SilentlyContinue`.

### 5. Consumption

| Runtime | Method | Details |
|---------|--------|---------|
| Node.js | `readSecret(name)` | Reads from env var (set by entrypoint), falls back to file read at `/run/secrets/` |
| PowerShell | `Get-SecretFromAws` | Falls back from cache → file read → direct AWS SM call |
| Shell (entrypoint) | `jq -r .key /run/secrets/bundle` | Exports to env vars for the application process |

---

## Bundle Manifest Reference

The canonical bundle manifest lives at `SalmonRun.Secrets/Private/bundle-manifest.ps1`. It defines 8 bundle types:

| Bundle | Required Keys | Optional Keys | Consumers | EnvMap |
|--------|--------------|---------------|-----------|--------|
| **Agent** (ORCH/VERI/BASE) | `aws_id`, `aws_secret`, `gateway_token`, openrouter key | `telegram_bot_token_*`, `gcp_maestro_*` | Gateway agents (oc-orch, oc-veri, oc-base) | Maps to `AWS_ACCESS_KEY_ID`, `ORCHESTRATOR_GATEWAY_TOKEN`, `OPENROUTER_*_KEY`, etc. |
| **Sentry** | — | `sentry_aws_id`, `sentry_aws_secret`, `GITHUB_TOKEN_READALL` | is-fleet container | Maps to `AWS_ACCESS_KEY_ID`, `GITHUB_TOKEN_READALL` |
| **Coding** | `OPENCODE_GO1_KEY` | `OPENCODE_GO2_KEY`–`GO5_KEY`, emails, `GITHUB_TOKEN_*`, `OPENCODE_SERVER_PASSWORD`, `OPENROUTER_CODE_KEY` | opencode containers (mcp_opencode) | Direct key-to-env (key name = env name) |
| **Proxy** | `attio_write_key`, `attio_archive_key` | `ATTIO_READ_KEY`, `APOLLO_*`, `ZEROBOUNCE_*`, `BROWSERLESS_*`, `SMARTLEAD_*`, `HUNTER_*`, `GCP_SERVICE_SECRET`, `ZOHO_*`, `WAVE_*`, `GDRIVE_*` | is-api container | No direct EnvMap — entrypoint uses Read-ProxySecret |
| **Docusign (retired)** | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` | `BASE_URL`, `NOTIFY_EMAIL` | no live container (retired) | JSON bundle retired 2026-08-19; kept as historical reference |
| **Tailscale** | `TAILSCALE_KEY` | — | Tailscale sidecar | Direct env mapping |
| **WebMcp** (retired) - see bundle-manifest.ps1 for keys | ~~mcp_web container~~ - retired 2026-08-22; web research via `/web-research` skill, rent tracking via `Skills/DevOps/Web/rent-tracking.md` | Maps to `TAVILY_API_KEY`, `FIRECRAWL_API_KEY`, `RECEIPTS_*`, etc. |
| **Bookkeeper** (retired) | `GOCARDLESS_PAY_READ`, `GOCARDLESS_PAY_RW` | `receipts_*`, `ZOHO_*`, `CLOUDTAX_*`, `homedepot_*` | ~~is-bookkeeping container~~ — retired 2026-08-21 | Maps to `GOCARDLESS_*`, `RECEIPTS_*`, `ZOHO_*`, etc. |


Plus a **Fleet** token section that generates per-service API tokens (`FLEET_API_TOKEN_*`) for inter-service auth. The `FleetApiTokens.ServiceTokens` table in `bundle-manifest.ps1` must include an entry for every service that participates in fleet API auth — add `is_<name> = "FLEET_API_TOKEN_<NAME>"` when adding a new service.

---

## Adding a New Secret

1. **Add to AWS SM**: Open the AWS Secrets Manager console (ca-central-1), select the relevant secret, add the new key-value pair.
2. **Add to bundle manifest**: Edit `SalmonRun.Secrets/Private/bundle-manifest.ps1` — add the key to `Required` or `Optional`, the EnvMap entry, and the SourceKeys list.
3. **Create publish function** (if a new bundle type): Create `Publish-NewBundleSecrets.ps1` in `SalmonRun.Secrets/Public/`.
4. **Wire into entrypoint**: If the container uses a custom entrypoint (`entrypoint.sh`), add export logic for the new env var. If using auto-export (most bundles), the EnvMap handles it.
5. **Re-deploy**: Run `deploy.ps1 -Phase DockerSecrets` to hydrate the new secret, then `deploy.ps1 -Phase FleetDeploy` to restart services.

---

## Rotating a Secret

### API key rotation (manual)
1. Generate new key from the vendor (Tavily, Firecrawl, OpenRouter, etc.)
2. Update the key in AWS SM (ca-central-1)
3. Re-run hydration: `deploy.ps1 -Phase DockerSecrets`
4. Restart affected services: `docker service update --force <service>`

### Automated rotation (scaffold)
`Skills/Docker/Scripts/Rotate-ApiKeys.ps1` provides a scaffold for automated key rotation. Current status: not yet wired into the deployment pipeline — manual steps above are the default approach.

### Coding key rotation
Coding keys (`OPENCODE_GO_KEY1`–`5`) are consumed by `mcp_opencode` containers. Rotate by:
1. Generating new opencode-go API keys in the opencode.ai dashboard
2. Updating the keys in AWS SM
3. Re-running hydration and fleet deploy

---

## Red lines

- **READ-ONLY to AWS SM**: No agent may create, update, or delete AWS SM secrets. Writing requires explicit user permission and confirmation.
- **Never log secret values**: Secrets must never appear in log output, console, or file writes. Use `$ErrorAction SilentlyContinue` for optional secrets.
- **AWS SM access requires SSO**: `aws sso login --profile intersite` must be active before any AWS SM operation.
- **Bundle changes require manifest edits**: Changing a bundle's keys requires one edit — the bundle manifest. All consumers derive from it.
- **Sentry IAM keys are runtime-generated**: `sentry_aws_id` and `sentry_aws_secret` are created by `New-SentryIamUser` at deploy time, not stored in AWS SM. This is a by-design exception.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `Get-SecretFromAws` returns null | AWS SM access denied or key not found | Verify `aws sso login --profile intersite` is active; check secret name in AWS SM |
| Secret not found in container | Bundle missing the key, or key in Optional but not hydrated | Check bundle manifest; re-run hydration |
| `docker service logs` shows `MODULE_NOT_FOUND` for auth lib | Secret not exported to env var | Check EnvMap in bundle manifest; verify entrypoint.sh reads the bundle |
| Hydration phase fails | AWS SM secret malformed or unreachable | Check AWS SM console for the secret JSON structure |
