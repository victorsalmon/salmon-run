# Secret Bundle Cookbook — Canonical Reference

The `bundle-manifest.ps1` file at `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` is the single source of truth for all Docker Swarm secret bundles. This cookbook is the human-readable companion: it explains the 8 bundle types, the 6-touchpoint pipeline, and the add/rotate/observe cookbook that any agent or operator can follow.

## The 8 bundle types

| Bundle | Required keys | Optional keys | Consumer services |
|--------|---------------|---------------|-------------------|
| **Agent** | `aws_id`, `aws_secret`, `gateway_token`, plus role-specific coding key (`openrouter_orch_key` / `openrouter_veri_key` / `openrouter_api_key` for BASE) | Role-specific Telegram, GCP Maestro, etc. | ORCH, VERI, BASE agent containers |
| **Sentry** | `aws_id`, `aws_secret` | `gateway_token`, Telegram, monitoring | `sentry` container |
| **Coding** | `gateway_token`, AWS SM access for hydration | 1-5 coding keys (`opencode_go_key1`–`key5`) | `mcp_opencode` containers |
| **Proxy** | `aws_id`, `aws_secret`, `gateway_token` | `attio_read_key`, `attio_write_key`, `attio_archive_key` | `is-api` proxy container |
| **Docusign** | `DOCUSIGN_SMTP_HOST`, `DOCUSIGN_SMTP_PORT`, `DOCUSIGN_SMTP_USER`, `DOCUSIGN_SMTP_PASS`, `DOCUSIGN_SMTP_FROM` | `DOCUSIGN_BASE_URL`, `DOCUSIGN_NOTIFY_EMAIL` | `mcp_docusign` container |
| **Tailscale** | `tailscale_oauth_client_id`, `tailscale_oauth_secret`, `tailscale_auth_key` | — | `sentry` (subnet router), `opencode` containers |
| **WebMcp** | `tavily_api_key`, `firecrawl_api_key` | `mcp_web_*` | `mcp_web` container |
| **Bookkeeper** | `gocardless_secret_id`, `gocardless_secret_key`, `zoho_books_client_id`, `zoho_books_client_secret`, `zoho_books_refresh_token` | `receipts_imap_host`, `receipts_imap_user`, `receipts_imap_password` | `Bookkeeper` container |

## The 6-touchpoint pipeline

```
1. bundle-manifest.ps1  →  2. Publish-*.ps1  →  3. entrypoint.sh  →  4. env vars  →  5. server.js  →  6. install.json
```

| Touchpoint | What it does | Where to edit |
|------------|-------------|---------------|
| 1. `bundle-manifest.ps1` | Declares the bundle's Required, Optional, EnvMap, and SourceKeys | `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` |
| 2. `Publish-*.ps1` | Reads the manifest, hydrates from AWS SM, writes to Docker Swarm secrets | `Skills/Docker/Modules/SalmonRun.Secrets/Public/Publish-<Bundle>Bundle.ps1` |
| 3. `entrypoint.sh` | Maps Docker Swarm secret files to env vars in the container | `Infrastructure/<service>/entrypoint.sh` |
| 4. env vars | Process env inside the container | (set by entrypoint) |
| 5. `server.js` | Reads `process.env.*` for runtime use | `Infrastructure/<service>/server.js` |
| 6. `install.json` | Top-level config that toggles features (e.g., `features.docusign.install: false`) | `install.json` |

A 7th touchpoint — `docker-manifest.json` — declares which secrets bundles contain which keys at the fleet level.

## Adding a new secret (5-step cookbook)

1. **Add to `bundle-manifest.ps1`** — declare the new key as Required or Optional in the relevant bundle's `EnvMap`. This is the canonical declaration.
2. **Re-hydrate the bundle** — run the corresponding `Publish-<Bundle>Bundle.ps1` (e.g., `Publish-AgentBundle.ps1`) so the Docker Swarm secret reflects the new key.
3. **Update `entrypoint.sh`** if the env-var name differs from the bundle key. Most keys are 1:1, but some have aliases (e.g., `aws_id` → `AWS_ACCESS_KEY_ID`).
4. **Update `server.js`** to read the new env var. If the key is Optional, guard with a `process.env.MY_KEY &&` check.
5. **Restart the service** so the new bundle is loaded: `docker service update --force <service-name>`.

## Rotating a secret

There are two rotation modes:

**Manual rotation** (default for one-off rotations):
1. Update the secret in AWS Secrets Manager (UI or `aws secretsmanager put-secret-value`).
2. Re-run the `Publish-<Bundle>Bundle.ps1` script — it re-hydrates from SM and rewrites the Docker Swarm secret.
3. Force-restart the consuming service.

**Automated rotation** (Lambda-backed rotation; future work):
- A Lambda function updates the secret in AWS SM on a schedule.
- Re-publish + restart is triggered automatically.

For now, manual rotation is the canonical path. The `Skills/Docker/Scripts/Rotate-ApiKeys.ps1` script is the existing scaffold for batch rotation.

## Observing secrets

Three layers of observability:

1. **AWS SM audit trail** — every read of a secret is logged. Use `aws secretsmanager describe-secret` and the CloudTrail logs.
2. **`Tasks/Logs/Audit/<domain>/audit.jsonl`** — the ORCHESTRATOR audit trail. Every API call that uses a secret is logged with hash-chain signing. Domains: `Bookkeeper`, `marketer`, `web`, `deploy`, `adhoc`.
3. **`Tasks/Logs/agents/<agent-id>.log`** — per-agent setup log. Look for `Write-SetupLog "Hydrating bundle ..."` lines.

Never log a secret's value. Never commit a secret to the repo. The audit trail records the secret *name* (e.g., `ORCHESTRATOR_GATEWAY_TOKEN`) but never the value.

## AWS SM read-only policy

All agents have **READ-ONLY** access to AWS Secrets Manager. No agent may create, update, delete, or write to AWS SM. Writing requires explicit user permission + a confirmation prompt + the user's affirmative response.

## Common pitfalls

- **Env-var name mismatch** — the bundle key (`opencode_go_key1`) and the env var (`OPENCODE_GO_KEY1`) must match what `entrypoint.sh` and `server.js` expect. The `EnvMap` in `bundle-manifest.ps1` is the source of truth.
- **Optional key not in bundle** — if a key is `Optional` in the manifest and the bundle doesn't have it, the env var is unset. Code must guard with `process.env.MY_KEY && ...`.
- **Bundle not re-hydrated after change** — editing `bundle-manifest.ps1` doesn't automatically update Docker Swarm secrets. You must re-run `Publish-<Bundle>Bundle.ps1`.
- **Service not restarted** — the bundle is read at container start. Editing the bundle without restart leaves the service running with the old bundle.
- **Cross-bundle leakage** — never put a secret in a bundle the service doesn't need. Bundle types are scoped.

## Per-bundle specifics

See the manifest for exact field lists. The most-edited bundles are **Agent** (when adding a new role or coding key) and **Coding** (when adding `opencode_go_key6`–`key10`).

## Related skills

- `Skills/DevOps/Fleet/secrets/SKILL.md` — high-level skill entry point
- `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` — the manifest
- `Skills/DevOps/Fleet/fleet-auth-flow.md` — how the auth tokens flow at runtime
- `Skills/Docker/Scripts/Rotate-ApiKeys.ps1` — rotation script scaffold
- `Orchestrator/Orchestration/Invoke-SkillsRegistryGate.ps1` — verifies the registry is clean (catches broken secret refs)
