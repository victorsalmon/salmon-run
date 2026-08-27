---
name: opencode/repos
description: Thin pointer to the ZCode-client skill at .agents/skills/repos/SKILL.md. Bridges the orchestrator skill registry to the cross-repo ZCode (OpenCode) client skill system. The canonical repo index lives in the ZCode skill.
---

> **Canonical skill:** `C:\Repos\.agents\skills\repos\SKILL.md`
> (ZCode-client skill, auto-discovered by the ZCode/OpenCode client; not
> duplicated here.)

This is a **thin pointer**. The authoritative repo index — the 12-repo table
(purpose, stack, key files, build/test commands, top-level directories,
cross-repo dependencies) — lives in the ZCode-client skill at
`.agents/skills/repos/SKILL.md`.

## Why this pointer exists

Two skill systems coexist under `C:\Repos`:

1. **`C:\Repos\.agents\skills\`** — the ZCode (OpenCode) client's auto-discovered
   skills (`SKILL.md` format). This is where `repos` and `feature-planning` live.
2. **`C:\Repos\salmon-orchestrator\Skills\`** — the orchestrator's own skill
   registry (`.md`/`.ps1`, catalogued in `skills.json`).

The orchestrator registry has no native repo index. This pointer registers the
ZCode skill in `skills.json` so orchestrator tooling that searches the registry
(cross-refs, `depends_on`, discovery) can find it, without duplicating the
12-repo table into a second file that would drift (the repo list changes as
repos are added/renamed/retired — e.g. `currentsbk` → `currentsbk.ca` on
2026-08-04).

## How to use it

- **From the ZCode client:** the skill is already available as `/repos`. Do not
  invoke this pointer.
- **From orchestrator tooling:** reference it as `opencode/repos` in
  `depends_on` / `cross_refs`, or read the canonical file directly at the path
  above.

## When the canonical file moves or changes

Update this pointer's frontmatter `description` and the path in the blockquote
above, then update the matching `path` in `skills.json`. Do not copy the repo
table here — that defeats the single-source-of-truth purpose.
