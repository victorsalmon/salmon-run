# Name Session Plan

Generate session plan filenames following the Print naming convention.

## When to use

- **Plan mode**: After grilling and writing the plan content, use `Write-SessionPlan.ps1` to generate the correctly-named file instead of constructing the filename by hand.
- **Audit mode (Phase B)**: After grouping findings into session-sized batches, use `Write-SessionPlan.ps1` to write each plan with a correct filename.
- **Any mode** that writes a `.md` file to `Tasks/Code/`.

## Naming convention

Per `session-plan-format.md`:

Before calling `Write-SessionPlan.ps1`, build the plan content with the `Overrides` header from that format. Use `**Overrides**: default` unless this plan intentionally overrides the orchestrator run profile. For any Overrides value, an interactive Planner must show the resolved harness, provider, model, and effort to the user and write `**Overrides confirmation**: confirmed by user` only after explicit approval. `Write-SessionPlan.ps1` names and writes the file; the plan content remains the source of truth for Overrides.

```
<date>-<namespace>-<iteration>-<description>.md
```

| Segment | Format | Example |
|---------|--------|---------|
| date | `yyyy.MM.dd` | `2026.06.22` |
| namespace | Semantic kebab-case | `secrets-port-registry` |
| iteration | Alpha-sort key | `1`, `3a`, `3b` |
| description | Short kebab-case phrase | `verify-bundle-manifest` |

The full filename: `2026.06.22-secrets-port-registry-1-verify-bundle-manifest.md`

## Script: `Write-SessionPlan.ps1`

The single executable source of truth for this convention. Lives at `Skills/Planner/Write-SessionPlan.ps1`.

```powershell
. "Skills/Planner/Write-SessionPlan.ps1"

# Basic usage — write a plan file with content
$content = @"
# Session Plan: 2026.06.22 secrets-port-registry 1 verify-bundle-manifest - Audit finding fix
**Status**: ready
...
"@

Write-SessionPlan -Namespace "secrets-port-registry" `
    -Iteration "1" `
    -Description "verify-bundle-manifest" `
    -Content $content

# Get the path back for further processing
$path = Write-SessionPlan -Namespace "adr-alignment" `
    -Iteration "2" `
    -Description "drift-check" `
    -Content $planContent `
    -PassThru

# Dry-run — see what would be generated
Write-SessionPlan -Namespace "codebase-health" `
    -Iteration "3a" `
    -Description "test-gaps" `
    -DryRun
```

## Cross-references

- `session-plan-format.md` — full plan content template and field reference
- `Write-SessionPlan.ps1` — executable naming helper
- `AGENTS.md` — naming format reference in Glossary section
