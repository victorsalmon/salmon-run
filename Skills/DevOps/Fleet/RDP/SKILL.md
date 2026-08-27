# Skill: RDP — Cloudflared tunnel for fra.clocklobster.com

**Type**: tool-command
**Owner**: dev host (Windows)
**Container**: host (not available inside the fleet)
**Loaded via**: `& "C:\Scripts\rdp.ps1"` (or `rdp` once added to PATH)
**Script**: `C:\Scripts\rdp.ps1`

**Output locations**: none — long-running tunnel, runs in the foreground.

**Related**:
- `AGENTS.md § AWS Secrets Manager Policy` — READ-ONLY access; writes require explicit user permission.
- `AGENTS.md § Platform-First Resolution` — check MCP / container APIs before reaching for AWS SM.
- `AGENTS.md § AWS SSO Login Procedure` — `aws sso login --profile intersite`.

---

## Purpose

Run a cloudflared tunnel that exposes the local RDP service at
`http://localhost:3389` to the public hostname `fra.clocklobster.com`.

This is the dev-host's external access pattern for RDP. Note: `AGENTS.md`
records "Public Ingress: (no public ingress — cloudflared retired)" for the
**fleet** stack; this skill is scoped to the dev host only, not the fleet.

## When to invoke

- User says "RDP", "open RDP", "start the RDP tunnel", or "I need to RDP into the dev machine".
- Any time a long-running tunnel to `fra.clocklobster.com` is needed.

## How it works

1. Fetches the cloudflared tunnel token from AWS Secrets Manager:
   - Secret: `FRAD/Provisioning`
   - Key: any key matching `CF_*` (e.g. `CF_TOKEN`, `CF_TUNNEL_TOKEN`)
   - Region: `ca-central-1`
   - Profile: `interclaw`
2. Runs `cloudflared tunnel run --token <token> --url <origin>` in the foreground.

The public hostname (`fra.clocklobster.com`) and ingress rules are owned by
the Cloudflare side; this script only supplies the token + local origin. If
ingress rules already route the tunnel to the right service, `--url` is
ignored and the tunnel uses Cloudflare's configuration.

## Usage

```powershell
# From any directory:
& "C:\Scripts\rdp.ps1"

# Custom origin (e.g. Guacamole on 8080):
& "C:\Scripts\rdp.ps1" -Origin http://localhost:8080

# Different AWS profile / region / secret:
& "C:\Scripts\rdp.ps1" -Profile dev -Region eu-central-1 -SecretId "Other/Secret"
```

### Parameters

| Param | Default | Purpose |
|-------|---------|---------|
| `-SecretId` | `FRAD/Provisioning` | AWS SM secret name |
| `-KeyPrefix` | `CF_` | Prefix of the key holding the tunnel token |
| `-Profile` | `interclaw` | AWS CLI profile (needs `secretsmanager:GetSecretValue` on the secret) |
| `-Region` | `ca-central-1` | AWS region |
| `-Origin` | `http://localhost:3389` | Local service URL |

## Prerequisites

- `cloudflared` installed and on `PATH` (verified by the script).
- `aws` CLI installed and on `PATH` (verified by the script).
- AWS SSO session active for the `interclaw` profile:
  `aws sso login --profile interclaw`
- The `interclaw` SSO role has `secretsmanager:GetSecretValue` on the
  `FRAD/Provisioning` secret (currently NOT granted — see manual task
<!-- doc-lint: exempt -->
  `Tasks/Manual/2026.06.15-grant-frad-provisioning-rdp-sm-access.md`).
- Local service reachable at the configured `-Origin`.

## Red lines

- **Never log the token value** — the script logs only the key name and length.
- **Never commit the token** — always fetched at runtime from AWS SM.
- **Never write to AWS SM** — READ-ONLY per project policy.
- The `--token` flag passes the tunnel token directly to cloudflared; do not save it to disk.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `Failed to fetch secret ... AccessDeniedException` | SSO role lacks `secretsmanager:GetSecretValue` on the secret — grant the permission or use a different profile. |
| `No key matching 'CF_*' in secret ...` | The secret's key has changed — list keys and update `-KeyPrefix` or the secret. |
| `NoCredentialsError` | AWS SSO session expired — `aws sso login --profile intersite`. |
| `cloudflared: command not found` | Install from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/. |
| Tunnel connects but RDP fails | Verify `http://localhost:3389` is reachable locally. For raw TCP (port 3389) use `cloudflared access tcp` instead of `tunnel run`. |

## History

- 2026-06-15 — Initial creation. Scoped to the dev host (not the fleet) per
  the AGENTS.md "cloudflared retired" note for fleet public ingress.
