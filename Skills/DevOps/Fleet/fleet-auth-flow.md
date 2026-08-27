# Fleet Auth Flow — Canonical Reference

Fleet services authenticate to each other via `FLEET_API_TOKEN_*` env vars. The contract is split across four sources: `bundle-manifest.ps1` (the token table), `Publish-FleetStack.ps1` (generation), `New-FleetCompose.ps1` (secret mapping), and `fleet-auth.cjs` (middleware validation). This document consolidates the flow.

## The contract

Every fleet service exposes `/api/*` and validates incoming requests via the `createFleetAuth` middleware (`Infrastructure/auth/fleet-auth.cjs`). Authenticated requests carry:

- `Authorization: Bearer <token>`

Exempt paths (no auth required, configurable per service):
- `/health` and `/api/health` — liveness checks
- `OPTIONS *` — CORS preflight
- Root path `/` and empty path — passthrough

The default exempt set is `['/health', '/api/health', '/api/ready']`.

> **CORS convention**: every fleet HTTP server MUST restrict CORS to an explicit allowlist — `Access-Control-Allow-Origin: *` is prohibited. Servers read a comma-separated origin allowlist from an env var (e.g. `CORS_ORIGIN` for `mcp_aqe`, `MARKETER_CORS_ORIGINS` for `is-marketer`, `BOOKKEEPING_CORS_ORIGINS` for `is-bookkeeping`, `FLEET_CORS_ORIGIN` for the proxy services) and echo the `Origin` header only when it matches an allowlist entry; when the allowlist is unset the header is omitted entirely. Preflight (`OPTIONS`) and method/header CORS headers are still sent regardless.

> **Warning**: the default exempt list is for health/readiness paths only. Credential-minting or mutating endpoints (e.g. `/zoho/token`, `/zoho/proxy`, `/books/*`) must NEVER be exempted via the default list — a service that needs such a path reachable without a token MUST pass an explicit `exemptPaths` argument and document the rationale.

On auth failure the middleware returns **403** with `{ error: 'forbidden' }`. No www-authenticate header is sent — this is an internal API, not a browser challenge.

## Token definitions

`Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` defines the `ServiceTokens` table under the `Fleet` section:

```
Service service name → FLEET_API_TOKEN_<NAME>
```

Token prefix: `FLEET_API_TOKEN`
All tokens are 32-byte cryptographically random strings (Base64-URL-safe, 43 chars).

The service tokens and per-service monitor tokens (source of truth: `ServiceTokens`/`MonitorTokens` in `bundle-manifest.ps1`):

| Service | API token | Monitor token |
|---------|-----------|---------------|
| `mcp_web` | `FLEET_API_TOKEN_WEB` | `FLEET_API_TOKEN_WEB_MONITOR` |
| `mcp_aqe` | `FLEET_API_TOKEN_AQE` | `FLEET_API_TOKEN_AQE_MONITOR` |
| `mcp_browserless` | `FLEET_API_TOKEN_BROWSERLESS` | `FLEET_API_TOKEN_BROWSERLESS_MONITOR` |
| `mcp_docusign` | `FLEET_API_TOKEN_DOCUSIGN` | `FLEET_API_TOKEN_DOCUSIGN_MONITOR` |
| `is_accountant` | `FLEET_API_TOKEN_IS_BOOKKEEPING` | `FLEET_API_TOKEN_IS_BOOKKEEPING_MONITOR` |
| `is_marketer` | `FLEET_API_TOKEN_MARKETER` | `FLEET_API_TOKEN_MARKETER_MONITOR` |
| `is_hermes` | `FLEET_API_TOKEN_HERMES` | — |
| `is_monitoring` | `FLEET_API_TOKEN_MONITORING` | — |
 — |
| `ops_funnel_proxy` | `FLEET_API_TOKEN_FUNNEL` | — |
| `is_fleet` | — (uses `fleet_monitor_token` for health checks) | `FLEET_API_TOKEN_MONITOR` |

Each service's monitor token is mounted at `/run/secrets/fleet_monitor_token` inside its own container. is-fleet mounts per-service monitor tokens under unique names (e.g., `fleet_web_monitor_token`) for health check authentication against each service. The shared `FLEET_API_TOKEN_MONITOR` is the read-only monitor token used across all fleet services for health/status checks. `FLEET_API_TOKEN_MONITORING` is `is_monitoring`'s per-service token (distinct from the shared monitor token).

## Token generation

`Publish-FleetStack.ps1` function `Get-ServiceApiToken`:

1. Checks AWS Secrets Manager for existing token (same `$TokenName`).
2. If found, reuses the existing value (idempotent).
3. If not found, generates 32 random bytes via `System.Security.Cryptography.RandomNumberGenerator`, Base64-encodes, and strips `+/=` and `-` characters.
4. Writes to AWS SM (`aws secretsmanager create-secret` or `put-secret-value` if already exists).
5. Publishes as a Docker Swarm secret via `Set-SwarmSecretSafe`.

All API tokens (service tokens + per-service monitor tokens, per the `ServiceTokens`/`MonitorTokens` tables above) are generated during the fleet deploy phase before the stack is published. They persist across redeploys — AWS SM is the source of truth. The shared monitor token (`FLEET_API_TOKEN_MONITOR`) is auto-rotated on each stack deploy and is accepted for read paths only.

## Token storage

### Docker Swarm secrets
Each token is published as a Docker Swarm secret named after the token itself (e.g., `FLEET_API_TOKEN_WEB`). `New-FleetCompose.ps1` maps each token into the container that needs it:

```powershell
# Each service's compose definition maps the token secret
[ordered]@{ source = "FLEET_API_TOKEN_WEB"; target = "fleet_api_token" }
```

The target is always `fleet_api_token` (or `fleet_monitor_token` for the per-service monitor token).

### Agent bundles
The service tokens are also added to each agent's secret bundle at deploy time (see `Publish-FleetStack.ps1`):
- `FLEET_API_TOKEN_WEB`, `FLEET_API_TOKEN_AQE`, `FLEET_API_TOKEN_BROWSERLESS`
- `FLEET_API_TOKEN_DOCUSIGN`, `FLEET_API_TOKEN_IS_BOOKKEEPING`, and any enabled sidecar service tokens

This lets an agent proxy authenticate to a service it calls. Each request must present the **target service's own token** (or the monitor token on read paths) — the middleware does not accept a foreign service token (see Token Validation Step 5).

## Token injection (MCP servers)

`Infrastructure/opencode/entrypoint.sh` injects tokens into `opencode.json` for MCP servers that need fleet authentication. The `tokenMap` at line 119 maps MCP server names to token env vars:

```js
const tokenMap = {
    'mcp_web': 'FLEET_API_TOKEN_WEB',
};
```

At startup, `entrypoint.sh` iterates the MCP server entries in `opencode.json`, looks up each name in `tokenMap`, reads the env var, and injects it as:

```json
"headers": {
    "Authorization": "Bearer <token>"
}
```

This is only done for the opencode container's own MCP servers. Other fleet services read the secret directly from the filesystem.

## Token validation

`Infrastructure/auth/fleet-auth.cjs` exports `createFleetAuth(options)` which returns Express middleware. The middleware:

1. Attempts to read tokens from `/run/secrets/fleet_api_token` and `/run/secrets/fleet_monitor_token` at **middleware creation time** (not per-request).
2. If neither secret file exists, passes all requests through (dev mode with a console.warn). If a secret file exists but is **empty**, the middleware treats it as a misconfiguration and exits the process (non-dev mode) — it does not fail open.
3. Exempts configured paths, root path `/`, and `OPTIONS` requests.
4. Extracts the `Authorization: Bearer <token>` header value.
5. Compares the extracted token against the service's **OWN token** (`ownServiceToken`, read from `/run/secrets/FLEET_API_TOKEN_<SERVICE>`, falling back to `fleet_api_token`) and the **monitor token**, using `crypto.timingSafeEqual` (constant-time) via the `timingSafeCompare` helper exported from `fleet-auth.cjs`. Either validates — a **foreign service's token does NOT validate**.
6. The monitor token is **rejected on write paths**: deploy (`/api/deploy*`), secret rotation/refresh (`/api/secret/rotate*`, `/api/secret/refresh*`), and all business-mutating route families — `/zoho/proxy`, `/books/`, `/sources/`, `/receipts/`, `/tax/`, `/vision/`, `/api/rent/payments/manual`, `/api/rent/rooms/`, `/api/rent/status-page`, `/api/rent/notifications/delivered`, `/api/rent/inbox/`, `/api/rent/templates/`, `/attio/companies` — return 403 when authenticated with the monitor token (see `MONITOR_DENIED_WRITE_PREFIXES` in `fleet-auth.cjs`).
7. On match (own token, or monitor token on a non-write path), calls `next()`.
8. On mismatch, returns **403** JSON `{ error: 'forbidden' }`.

Key design properties:
- Secrets are read once at startup — container restart required to pick up new tokens.
- No `X-Fleet-Token` or alternative header is supported.
- Comparison uses `crypto.timingSafeEqual` (constant-time) via the `timingSafeCompare` helper — not `===`.
- Two-token model: the service's own token for normal operation, the per-service monitor token for health checks. Either validates on read paths; the monitor token cannot write.

## Adding a new service (3 steps)

1. **Add to `bundle-manifest.ps1` ServiceTokens**
   Add the new service name and its `FLEET_API_TOKEN_<NAME>` to the `ServiceTokens` hashtable.

2. **Add to `Publish-FleetStack.ps1` token list**
   Add the new token name to the `$FleetTokenNames` hashtable (line 275). If the new service needs bundle access, add it to the `$serviceTokenNames` array at line 303.

3. **Add to the service's Docker Compose config in `New-FleetCompose.ps1`**
   Add a secrets mapping entry: `[ordered]@{ source = "FLEET_API_TOKEN_<NAME>"; target = "fleet_api_token" }`.

Then use `createFleetAuth()` in the new service's API code:
```js
const { createFleetAuth } = require('./auth/fleet-auth.cjs');
app.use(createFleetAuth({ exemptPaths: ['/health', '/api/health'] }));
```

If the service needs to call another fleet service, reference the token from the bundle:
```js
const token = process.env.FLEET_API_TOKEN_<TARGET>;
```

## Common pitfalls

- **Token not in bundle**: The service starts but the `FLEET_API_TOKEN_*` env var is empty. Re-publish the bundle (`Publish-FleetStack.ps1` does this automatically) and restart the service.
- **Token not injected into MCP server**: The `entrypoint.sh` `tokenMap` is missing the new MCP server name. Edit `entrypoint.sh` and rebuild the image.
- **Service calling without auth header**: The caller forgot to add `Authorization: Bearer <token>`. Check the calling service's HTTP client code.
- **Wrong exempt list**: Health check endpoints returning 403. Update the service's `exemptPaths` to include all health-check paths.
- **Secrets read once at startup**: If a token is rotated, the consuming container must be restarted to pick up the new secret file content. A rolling `docker service update --force` is required.

## Rotation

1. Delete or update the token in AWS SM (manual or via `Rotate-ApiKeys.ps1`).
2. Re-run `Publish-FleetStack.ps1` (or the relevant deploy phase) to regenerate and re-publish the Swarm secret.
3. Force-restart the consuming service: `docker service update --force <service>`.

The rotation is eventually consistent per-service. During the window between secret update and container restart, the old token and new token are both valid for different containers. There is no built-in dual-token support — zero-downtime rotation requires manual orchestration.

## Host-side agent access

Host-side agents (running `opencode` CLI directly on the dev machine, not inside a fleet container) cannot reach the internal Docker overlay network — container ports like `21005` are not published to the host. However, the host **can** use `docker exec` to tunnel API calls through any running container.

### One-liner — single `docker exec` with shell substitution

```powershell
$result = docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d sh -c "curl -s -H 'Authorization: Bearer \$(cat /run/secrets/fleet_api_token)' http://localhost:21005/api/routes" 2>&1
```

### Two-step — read token, then call from a container

```powershell
$token = docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d cat /run/secrets/fleet_api_token
docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d curl -s -H "Authorization: Bearer $token" http://localhost:21005/api/health
```

### Target any fleet service — pick the right container

You don't have to use `mcp_web` — any running container that has `curl` also works. Use whichever container's image has `curl` installed:

| Service | Image | Has curl? |
|---------|-------|-----------|
| `mcp_web` | `mcp_web:local` (Node) | Yes (Alpine) |
| `mcp_aqe` | `mcp_aqe:local` (Python) | Yes |
| `mcp_browserless` | `mcp_browserless:local` (Node) | Yes |
| `is-fleet` | `fleet:local` (PowerShell) | No (no curl) |

To call another service (e.g. `is-api` on port `21003`), run the curl from the `mcp_web` container but target the other service's hostname (Docker DNS):

```powershell
$token = docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d cat /run/secrets/fleet_api_token
docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d curl -s -H "Authorization: Bearer $token" http://is-api:21003/api/health
```

### Per-service token names

Every service has its own `FLEET_API_TOKEN_*` stored in Docker Swarm secrets. The secret inside the container is always at `/run/secrets/fleet_api_token`, but the value differs per service. The `fleet_api_token` file in a container holds *that service's own token*: the `createFleetAuth` middleware validates the bearer token against the target service's OWN token (plus the monitor token, on read paths only) — a host-side agent must present the target service's own token or a monitor token. A foreign service's token does NOT authenticate (see Token Validation Step 5 above).

### Calling the check-receipt-email API (worked example)

```powershell
# Dry-run — see what's in the inbox without downloading
$token = docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d cat /run/secrets/fleet_api_token
docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d curl -s -H "Authorization: Bearer $token" -H "Content-Type: application/json" -X POST -d '{"mailbox":"rentals"}' "http://localhost:21005/api/check-receipt-email?dry-run=true"

# Live run — download unseen attachments
docker exec FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d curl -s -H "Authorization: Bearer $token" -H "Content-Type: application/json" -X POST -d '{"mailbox":"rentals"}' http://localhost:21005/api/check-receipt-email
```

### Short-lived tokens — caveat

Fleet tokens are static (32-byte random, persisted to AWS SM). The token you read from a container is valid until rotated. It is **not** scoped, timed, or audited per-read. Treat it as a long-lived credential.

### Lessons Learned — 2026-06-15

**What Worked**:
- `docker exec <container> cat /run/secrets/fleet_api_token` reads the service token without needing to mount the secret on the host — works on any running fleet container
- Single `docker exec sh -c "curl ... \$(cat /run/secrets/fleet_api_token)"` works for one-liners (shell substitution in the container)
- Cross-service calls from a host-side agent work when the caller presents the **target service's own token** (or a monitor token) — the middleware validates against the target's own token, not "any service token"
- `POST /api/check-receipt-email` on mcp_web now uses `IMAP_HOST = 'webhosting2049.is.cc'` (was fixed in a prior deployment) — both `intersite` and `rentals` mailboxes connect successfully

**What Didn't Work**:
- Direct host-to-container HTTP calls fail because internal Docker ports (21005, etc.) are not published to the host — `curl http://localhost:21005/...` from the host goes nowhere
- `docker exec` into `is-fleet` is not useful for API calls — the fleet image is PowerShell-based and doesn't have `curl`
- The `/api/routes` endpoint returns `403` even with a valid token — the middleware checks `req.path` which may mismatch the registered exempt paths (routes endpoint is not in the exempt list)
- The `POST /api/check-receipt-email` response only returns `checked`, `downloaded`, `files` but not `found` (count of unseen messages) — limited visibility in dry-run mode

**Improvements for next run**:
- Consider documenting which containers have `curl` in `fleet-topology.md` so agents don't guess
- The `check-receipt-email` endpoint should return `found` (unseen count) even in dry-run mode so agents can see whether there's mail without downloading
- Consider exposing the fleet API token to the host via a Docker volume mount on the `interclaw_workspace` volume so host-side agents can read it directly without `docker exec`

**Helpful Information**:
- Docker Swarm secret names: per-service `FLEET_API_TOKEN_<SERVICE>` and per-service `FLEET_API_TOKEN_<SERVICE>_MONITOR` (see the token table above) — all are generated at deploy time and persisted in AWS SM
- The secret inside any container is always at `/run/secrets/fleet_api_token` regardless of which service it belongs to — the Docker Compose mapping (`source → target`) normalizes them
- `is-fleet` and `is-monitoring` use PowerShell (`pwsh`) and don't have `curl`. For API calls from those containers, use PowerShell's `Invoke-RestMethod` instead
- Container task names (e.g. `FRAD_mcp_web.1.ivzhxxyuh3i0xm6qe3zq8ze0d`) change after service updates — always verify the container name with `docker ps` before running `docker exec`

## Source files

| File | Role |
|------|------|
| `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` | Defines `ServiceTokens`/`MonitorTokens` tables (canonical token names) |
| `Skills/Docker/Modules/SalmonRun.Deploy/Public/Publish-FleetStack.ps1` | Generates, persists, and publishes tokens |
| `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1` | Maps tokens to container secrets in compose YAML |
| `Infrastructure/auth/fleet-auth.cjs` | Auth middleware (token validation) |
| `Infrastructure/opencode/entrypoint.sh` | Token injection into MCP server configs |

## Changelog

- **2026-08-06** — Added the CORS allowlist convention: every fleet HTTP server MUST restrict CORS to an explicit origin allowlist (`Access-Control-Allow-Origin: *` prohibited); `mcp_aqe` and `is-marketer` now echo the origin only for allowlisted requests (`CORS_ORIGIN` / `MARKETER_CORS_ORIGINS`, comma-separated, omitted when unset).
- **2026-08-01** — Canonicalized the shared monitor token as `FLEET_API_TOKEN_MONITOR` (was `FLEET_API_TOKEN_FLEET_MONITOR`); renamed `is_monitoring`'s service token from `FLEET_API_TOKEN_MONITOR` to `FLEET_API_TOKEN_MONITORING` to eliminate the naming collision.
- **2026-08-01** — Corrected the Token Validation section to match `fleet-auth.cjs`: comparison uses `crypto.timingSafeEqual` (via `timingSafeCompare`), the middleware validates the service's OWN token plus the monitor token (a foreign service's token does NOT validate), the monitor token is rejected on write paths (`/api/deploy*`, `/api/secret/rotate`, `/api/secret/refresh`), and an empty-but-present secret file fails closed. Retired `is_api` / `is-sentry` references and the shared `FLEET_API_TOKEN_MONITOR`; aligned the token table with `bundle-manifest.ps1` `ServiceTokens`/`MonitorTokens`. Removed the non-existent `fleet-auth.json` source row from the Source files table.
