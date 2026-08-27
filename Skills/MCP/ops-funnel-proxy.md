# ops-funnel-proxy — Operational Funnel Proxy (nginx)

**Image**: `funnel-proxy:local` (nginx:1.27-alpine + nodejs based)
**Port**: 21009
**Auth**: inbound webhook bearer validated per request by `funnel-auth.cjs` (auth_request); the fleet token (`/run/secrets/fleet_api_token` = `FLEET_API_TOKEN_DOCUSIGN`) is forwarded to upstream requests — never written to a config file

## Overview

`ops-funnel-proxy` is an nginx-based reverse proxy that exposes Docusign webhooks to the public internet via Tailscale Funnel. Inbound webhook requests are validated at request time: nginx issues an `auth_request` subrequest to the local Node verifier (`funnel-auth.cjs`, loopback `127.0.0.1:21017`), which reads `/run/secrets/fleet_api_token` and timing-safely compares the `Authorization: Bearer <token>` header. On match the request is proxied to the internal `mcp_docusign` service with the fleet API token attached as an `Authorization` header; on mismatch nginx returns 401.

## Routes

| Method | Path | Description |
|--------|------|-------------|
| POST | `/webhook/docusign/` | Proxy to Docusign webhook handler (`http://mcp_docusign:21007/`) |
| GET | `/api/health` | Liveness check |
| GET | `/api/ready` | Readiness probe (proxies to docusign) |
| GET | `/api/credentials` | Credential validity (none managed here) |
| GET | `/api/routes` | Route discovery |
| GET | `/api/version` | Version info |

## How It Works

Tailscale Funnel exposes `https://FRAD-funnel.vdeskgame-richmond.ts.net:443` to the internet. Docusign sends webhook events to `/webhook/docusign/`. The funnel-proxy validates the webhook bearer token via the `auth_request` verifier, then forwards to `mcp_docusign:21007` with the token attached.

## Related Skills

<!-- doc-lint: exempt -->
- `Skills/MCP/mcp_docusign.md` — Upstream Docusign server
- `Skills/MCP/mcp-catalog.md` — MCP server catalog

## Common Usage

Docusign webhook routing: configure Docusign Connect to send webhooks to `https://FRAD-funnel.vdeskgame-richmond.ts.net:443/webhook/docusign/`. The funnel-proxy validates the webhook bearer token (auth_request against `funnel-auth.cjs`) and adds the required auth token before forwarding.

## Source Code

- `Infrastructure/funnel-auth.cjs` — Request-time bearer verifier (reads the secret per request, never writes it to disk config)
- `Infrastructure/funnel-entrypoint.sh` — Entrypoint script (fail-closed secret check, starts verifier + nginx)
- `Infrastructure/funnel-nginx.conf` — Static nginx configuration (auth_request model)
- `Infrastructure/funnel-proxy.Dockerfile` — Container build
- `Infrastructure/funnel.json` — Tailscale Funnel configuration
