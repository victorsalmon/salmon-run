---
name: deprecation
description: Mark a component as superseded and remove it from active deployment while retaining the code for reference. Invoke when asked to deprecate, supersede, or remove a feature from the active stack. Triggers: "deprecate", "supersede", "sunset", "remove from active".
---

# Deprecation Skill

## Core Principles

- **Dead code is still reference** — deprecated code stays in the repository but is removed from the deploy pipeline. It serves as a historical record and prevents blind re-implementation.
- **Announce the replacement** — every deprecation must identify what supersedes it and why the new approach works.
- **No silent removal** — if another component depended on the deprecated feature, the dependency must be resolved first or a compatibility shim installed.

## Procedure

1. **Toggle off in install.json** — set `<feature>.install` to `false`.
2. **Remove from deploy pipeline** — strip the feature's service from `New-FleetCompose.ps1`, image build from `Invoke-ORCHESTRATORDeployment.ps1`, and any secret hydration from `Publish-FleetStack.ps1`.
3. **Clean up IAM** — if the deprecated feature had a dedicated IAM user, run `Invoke-OrphanIamCleanup` or `1Cleanup-AWS.ps1` to decommission.
4. **Document why it failed** — in the script header or a companion `.md`, record:
   - The exact error or symptom that broke it
   - The root cause
   - Any attempted fixes that also failed
5. **Name the replacement** — state which script/skill replaces it and why.
6. **Update SCRIPTS.md** — add the old script to a "Failed approaches" table.
7. **Update glossaries** — annotate the term as deprecated in `docs/Glossaries/`.
8. **Commit with `chore:` prefix** — message: `chore: deprecate <feature> -- superseded by <replacement>`.

## Deletion (post-deprecation)

After a deprecation has been in place for at least one full release cycle:

1. Remove the Dockerfile and any entrypoint scripts from `Infrastructure/`.
2. Remove the compose block from `New-FleetCompose.ps1` entirely (not just gated).
3. Remove image build functions from `SalmonRun.Images`.
4. Remove bundle manifests from `SalmonRun.Secrets/Private/bundle-manifest.ps1`.
5. Remove env-var-registry entries in `docker-manifest.json`.
6. Remove glossary entries and cross-references.

## Anti-patterns

- **Silent removal** — removing code without documentation means the next developer wastes time rediscovering why it didn't work.
- **Keeping dead IAM users** — unused IAM users are a security risk. Decommission them during deprecation, not later.
- **Partial removal** — leaving half the deploy pipeline references means the next agent hits confusing errors.
