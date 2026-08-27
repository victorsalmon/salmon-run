---
name: lifecycle
description: Entrypoint for the OpenCode Lifecycle track — shelving, deprecation, and retirement of projects and features. Invoke this skill first to determine which lifecycle stage applies, then load the specific sub-skill.
---

# Lifecycle Track

Components move through four states: **Active** → **Shelved** → **Deprecated** → **Retired**. Each transition removes more of the component from the active system while preserving or discarding artifacts deliberately.

## Decision flow

```
Is the feature still being worked on?
  ├── Yes → Active (no lifecycle action needed)
  └── No → Will it be worked on again?
              ├── Yes, eventually → use shelving skill
              └── No → Does it have a replacement?
                          ├── Yes → use deprecation skill
                          └── No → use retirement skill
```

## When to use each skill

| State | Trigger phrases | What happens |
|-------|----------------|--------------|
| **Active** | — | Normal development |
| **Shelved** | "shelve", "back-burner", "park", "indefinitely pause" | Toggle off, preserve all artifacts. One-toggle re-enable. |
| **Deprecated** | "deprecate", "supersede", "sunset", "remove from active" | Remove from pipeline, keep code as reference, decommission IAM. Has a named replacement. |
| **Retired** | "retire", "decommission", "purge", "full teardown" | Remove everything — code, pipeline, IAM, secrets, docs. No path back. |

## Sub-skills

- [Shelving](shelving.md) — pause with full preservation
- [Deprecation](deprecation.md) — supersede with code reference retained
- [Retirement](retirement.md) — permanent removal, full teardown
