---
name: retirement
description: Permanently remove a component from the codebase, infrastructure, and documentation. Invoke when asked to retire, decommission, purge, or fully remove a service or feature. Triggers: "retire", "decommission", "purge", "full teardown", "remove entirely".
---

# Retirement Skill

## Core Principles

- **Retirement is final** — retired code is removed from the repository. There is no toggle to bring it back. This is the appropriate action only when:
  - The component was never deployed (removed before first deploy).
  - The component has been deprecated for at least one full release cycle.
  - There is no conceivable scenario where the component would be re-enabled.
- **Full lifecycle required** — retirement must cover code, infrastructure, secrets, IAM, documentation, and cross-references. A partial retirement leaves security holes and confusing dead ends.

## Procedure

1. **Toggle off and remove from install.json** — delete the feature's entire block (including any `secrets` section).
2. **Strip from deploy pipeline** — remove service generation, image builds, secret hydration, and all feature-gate checks from every pipeline module.
3. **Remove Docker artifacts** — delete the Dockerfile and any entrypoint scripts from `Infrastructure/`.
4. **Remove image build** — delete the `Invoke-*ImageBuild` function from `SalmonRun.Images` and remove the call site.
5. **Remove bundle manifest** — delete or remove the bundle entry from `SalmonRun.Secrets/Private/bundle-manifest.ps1`.
6. **Remove env-var-registry entries** — strip entries from `docker-manifest.json`.
7. **Decommission IAM** — delete any dedicated IAM users/roles via `1Cleanup-AWS.ps1`.
8. **Remove Docker secrets** — manually remove any stale Swarm secrets (`docker secret rm <name>`).
9. **Clean up port registry** — remove the port assignment from `Infrastructure/port-registry.json`.
10. **Remove glossary entries** — delete terms from `docs/Glossaries/`.
11. **Update AGENTS.md** — remove the feature from Docker services naming, architecture tables, and any cross-references.
12. **Update diagrams** — remove the node from Mermaid diagrams in `docs/Reference/Diagrams.md`.
13. **Commit with `chore:` prefix** — message: `chore: retire <feature> -- <reason>`.

## Verification

After retirement:
- [ ] `install.json` has no trace of the feature
- [ ] No pipeline module references the feature
- [ ] Dockerfile removed from `Infrastructure/`
- [ ] No IAM users remain for the feature
- [ ] No Docker Swarm secrets for the feature
- [ ] Glossary entry removed
- [ ] AGENTS.md cleaned up
- [ ] Diagrams updated
- [ ] Port registry cleaned up

## Comparison

| State | Deploy toggle | Code in repo | IAM | Docs | Re-enable effort |
|-------|:---:|:---:|:---:|:---:|:---:|
| Active | `true` | Yes | Active | Current | N/A |
| Shelved | `false` | Yes | Preserved | Annotated | One toggle |
| Deprecated | `false` | Yes (removed from pipeline) | Decommissioned | Annotated | Re-write from code |
| Retired | Removed | No | Removed | Removed | Re-build from scratch |
