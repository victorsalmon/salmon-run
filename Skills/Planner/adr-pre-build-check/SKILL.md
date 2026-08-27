# ADR Pre-Build Checklist

Before building any new container, service, or making networking/architectural changes, read all ADRs in `docs/Reference/Decisions/` and verify your design against this checklist.

## Mandatory checks

| # | Check | Source |
|---|-------|--------|
| 1 | Read all files in `docs/Reference/Decisions/` | ADR 0000 |
| 2 | Does the new component need Docker socket access? (Only sentry may have it) | ADR 0006 |
| 3 | Does it need third-party API credentials? Put them in the api-proxy bundle, NOT in the container | ADR 0011 |
| 4 | Does it run as non-root with minimal capabilities? | ADR 0001 |
| 5 | Does it have a HEALTHCHECK in its Dockerfile? | ADR 0004 |
| 6 | Does it have memory reservations and limits in compose? | ADR 0004 |
| 7 | Does it specify explicit DNS (`8.8.8.8`, `1.1.1.1`)? | ADR 0004 |
| 8 | Is it conditionally deployed via a toggle in `Initialize-FleetToggles`? | ADR 0002 |
| 9 | Is it defined in `New-FleetCompose.ps1` (not static YAML)? | ADR 0004 |
| 10 | Does it have an image build function with source-hash caching? | ADR 0002 |
| 11 | Is it in `Start-ParallelImageBuild.ps1`? | ADR 0002 |
| 12 | Are all secrets passed via Docker Swarm bundles (never env vars)? | ADR 0007 |
| 13 | Is it covered by sentry's `Test-SentrySidecarHealth`? | ADR 0006 |
| 14 | Is it accounted for in `Measure-DockerResources` and `Test-ResourceBudget`? | ADR 0001 |
| 15 | Does it join only the overlay networks it needs (service_net, not management_net)? | ADR 0004 |
| 16 | Is its port within the documented sidecar range (3100–3199)? | ADR 0004 |
| 17 | Is its service name consistent with fleet conventions (`oc-<name>`)? | ADR 0004 |
| 18 | Are its env vars documented in `env-var-registry.json`? | ADR 0002 |
| 19 | Are there Pester tests for compose generation with its toggle? | ADR 0002 |
| 20 | Does it use soft-delete (archive) instead of hard DELETE for data operations? | ADR 0001, ADR 0008 |

## How to use

When given a task to build a new container, service, or modify network topology:

1. **Stop.** Do not write any code yet.
2. **Read all ADRs** in `docs/Reference/Decisions/`.
3. **Run this checklist.** Verify each item against your design.
4. **Document deviations.** If any check cannot be satisfied, write the reason in the session plan.
5. **Proceed** only after all mandatory checks pass or deviations are documented.
