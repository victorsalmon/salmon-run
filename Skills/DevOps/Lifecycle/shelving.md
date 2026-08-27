---
name: shelving
description: Indefinitely pause a project or feature without removing its code, configuration, or secrets from the repository. Invoke when asked to shelve, back-burner, park, or mothball a component. Triggers: "shelve", "back-burner", "park", "mothball", "indefinitely pause".
---

# Shelving Skill

## Core Principles

- **Preserve, don't delete** — shelved components keep all code, Dockerfiles, compose definitions, secrets blocks, and documentation. Only the deploy toggle flips to `false`.
- **Re-enablement is one toggle** — a properly shelved feature requires only setting `install: true` in `install.json` and redeploying. If it needs more than that, the shelf was incomplete.
- **Document the shelf** — write a post-hoc plan or session log explaining why, what was preserved, and what would be needed to unshelve.

## Procedure

1. **Toggle the feature flag** — set `<feature>.install` to `false` in `install.json`. If the feature has a `secrets` block, leave it intact.
2. **Guard deploy-pipeline code paths** — wrap any unconditional secret hydration or pipeline logic in the feature's install gate so it makes no external calls when disabled.
3. **Update glossaries** — if the feature is documented in `docs/Glossaries/`, annotate its status as shelved (e.g., append "(shelved)" to the term name) so agents don't waste context on it.
4. **Update AGENTS.md** — annotate the feature's status in the Naming Conventions section.
5. **Commit with `chore:` prefix** — message format: `chore: shelve <feature> -- <reason>`.
6. **Orphans self-clean** — the next `docker stack deploy` removes the service; `Remove-OrphanedVolumes` purges associated volumes.

## Verification

After shelving:
- [ ] `install.json` shows `"install": false`
- [ ] No deploy-pipeline code makes AWS SM or external calls for the shelved feature
- [ ] Re-enablement requires only `install: true` + redeploy (verify by tracing the pipeline path)
- [ ] Glossary entry annotated
- [ ] AGENTS.md naming tables annotated

## Anti-patterns

- **Deleting secrets blocks** — credentials are lost and must be manually re-entered on unshelve.
- **Removing Dockerfiles or compose sections** — the architecture is erased, forcing re-creation from scratch.
- **Only fixing state, not source** — patching the current host's Docker services without touching `install.json` means the first redeploy re-creates the shelved service.
