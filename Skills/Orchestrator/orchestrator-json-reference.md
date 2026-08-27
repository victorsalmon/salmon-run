# ORCHESTRATOR JSON Config Files — Canonical Reference

The ORCHESTRATOR fleet is configured by 5 interrelated JSON files. Each has a clear owner, scope, and validator. This document is the canonical entry point — any time you wonder "what does this file control?" or "who edits this?", look here first.

## File inventory

| File | Purpose | Owner (writes) | Validator | Schema |
|------|---------|----------------|-----------|--------|
| `opencode.json` | opencode CLI config (top of repo) | Operators + skill updates | `Skills/Create/Skill-Authoring/Install-Skills.ps1` | inline (opencode) |
| `install.json` | Fleet install config (top of repo) | `config.ps1` Phase 1a | `Skills/Docker/Tests/InstallJsonSchema.Tests.ps1` | `install.json.schema.json` |
| `Infrastructure/port-registry.json` | Port allocation registry | `SalmonRun.Ports` module | `Skills/Docker/Tests/SalmonRun.Ports.Tests.ps1` | inline (SalmonRun.Ports) |
| `docs/Reference/env-var-registry.json` | Env-var documentation | `SalmonRun.Provision` | manual review | inline |
| `Infrastructure/manifests/docker-manifest.json` | Fleet container manifest (secrets → bundles) | `SalmonRun.Secrets` / `SalmonRun.Deploy` | `Skills/Docker/Tests/DockerManifest.Tests.ps1` | inline |

## `opencode.json`

The opencode CLI config. Loaded by `opencode serve` on startup. Defines:
- `command` templates — one entry per `opencode run --command <name>` (e.g., `work-code`, `work-review`).
- `permission` — the permission rules for the opencode CLI (which tools the agent can use).
- `mcp` — the MCP server registrations (one block per server: `mcp_opencode`, `mcp_aqe`, `mcp_web`, etc.).
- `provider` — model routing per provider (opencode-go, openrouter).
- `agent` — agent-level overrides.

**Convention**: any new command template MUST have a corresponding entry in `Skills/Workflows/*/SKILL.md` (the skill that owns the command). `Skills/Create/Skill-Authoring/Install-Skills.ps1` reconciles the two on skill updates.

**When to edit**: adding a new command, changing a permission, registering a new MCP server, or changing model routing.

## `install.json`

The fleet install config. Read by every phase of `Skills/Docker/deploy.ps1`. Defines:
- `agents` — the agent instances (name, role, instance ID).
- `services` — the fleet services (oc-ORCH, oc-VERI, mcp_opencode, is-api, Bookkeeper, sentry, etc.).
- `features` — feature flags (e.g., `features.docusign.install: false`, `features.tailscale.enabled: true`).
- `secrets` — references to the AWS SM keys to hydrate.
- `bundle_types` — which secret bundles this install uses.

**Convention**: `install.json` is the source of truth for fleet identity. The agents, services, and feature flags all derive from it. The repo-root `install.json` and the `1Deploy.ps1` deployment read this file.

**When to edit**: adding a new agent, changing feature flags, changing the bundle composition, or onboarding a new fleet (FRAD, NEXUS, etc.).

## `Infrastructure/port-registry.json`

The port allocation registry. Defines:
- `internal` — ports in the `21000-21999` range used by service-to-service traffic inside the Docker Swarm network.
- `host` — ports in the `20100-39900` range published to the host (only sentry and a few debug ports).
- `gateway` — the opencode gateway port (default `18789`).

**Convention**: `Get-ServicePort -Service <name>` from `SalmonRun.Ports` reads from this file. Never hardcode a port in a script — always go through the registry.

**When to edit**: adding a new service that needs a port; changing an existing port. Always run the Pester tests for port conflicts.

## `docs/Reference/env-var-registry.json`

The env-var documentation. Defines every env var the fleet uses, with:
- `name` — the env var name
- `purpose` — one-sentence description
- `source` — where the value comes from (AWS SM key, literal, or env-passthrough)
- `consumer` — which service(s) read it
- `required` — boolean

**Convention**: every env var MUST be documented in this registry. Adding a new env var without an entry is a code-review failure.

**When to edit**: adding a new env var, changing a value's source, or onboarding a new consumer.

## `Infrastructure/manifests/docker-manifest.json`

The fleet container manifest. Declares:
- `containers` — every container in the fleet (image, build function, secrets bundles mounted, env vars from the env-var-registry).
- `bundles` — the secret bundle composition per service.

**Convention**: `1Deploy.ps1` and `New-FleetCompose.ps1` read from this manifest to generate the compose file. The `BundleDrift` Pester test catches drift between `docker-manifest.json` and `bundle-manifest.ps1`.

**When to edit**: adding a new service, changing bundle composition, or onboarding a new container image.

## Relationships

```
                  ┌──────────────┐
                  │ install.json │  (fleet identity, features)
                  └──────┬───────┘
                         │ read by deploy.ps1
                         ▼
   ┌─────────────────────────────────────────────┐
   │ docker-manifest.json                         │  (containers + bundles)
   │   ├─→ env-var-registry.json                  │
   │   ├─→ port-registry.json                     │
   │   └─→ bundle-manifest.ps1 (SalmonRun.Secrets)│
   └─────────────────┬───────────────────────────┘
                     │ generates
                     ▼
   ┌─────────────────────────────────────────────┐
   │ Infrastructure/docker-compose.interclaw.yml  │  (output)
   └─────────────────┬───────────────────────────┘
                     │ runs
                     ▼
   ┌─────────────────────────────────────────────┐
   │ opencode.json (per-container CLI config)     │
   │   └─→ mcp server registrations               │
   │   └─→ command templates → Skills/Workflows/*/SKILL.md
   └─────────────────────────────────────────────┘
```

## Validation

| File | Pester test |
|------|-------------|
| `install.json` | `Skills/Docker/Tests/InstallJsonSchema.Tests.ps1` |
| `docker-manifest.json` | `Skills/Docker/Tests/DockerManifest.Tests.ps1` (BundleDrift) |
| `port-registry.json` | `Skills/Docker/Tests/SalmonRun.Ports.Tests.ps1` |
| `env-var-registry.json` | manual review (no automated test yet) |
| `opencode.json` | manual review + `Skills/Create/Skill-Authoring/Install-Skills.ps1` reconciliation |

The `Orchestrator/Orchestration/Invoke-SkillsRegistryGate.ps1` script validates the *registry* that references these files (via `path`, `cross_refs`, `depends_on`).

## Common pitfalls

- **Port conflicts** — adding a new service without updating `port-registry.json` causes a Swarm port conflict. Always run the Pester tests.
- **Env-var name mismatches** — `entrypoint.sh` reads `process.env.MY_VAR` but the bundle manifest declares `my_var`. The `EnvMap` is the source of truth.
- **Secrets bundle drift** — `docker-manifest.json` and `bundle-manifest.ps1` can drift; the `BundleDrift` test catches it.
- **`opencode.json` command references missing workflow** — every command template MUST have a corresponding `SKILL.md`. The Install-Skills script reconciles.

## Related skills

- `Skills/DevOps/Fleet/deploy-fleet/SKILL.md` — deploys from these files
- `Skills/DevOps/Fleet/images/SKILL.md` — image builds (referenced by docker-manifest.json)
- `Skills/DevOps/Fleet/secrets/SKILL.md` — secrets (bundle-manifest.ps1 lives here)
- `Skills/DevOps/Fleet/fleet-auth-flow.md` — the auth flow that uses these configs
- `Skills/Fleet&DevOps/secret-bundle-cookbook.md` — the secret bundle pipeline
