---
name: opencode/workflow/update-skills
description: Focused skill-upgrade pass — captures lessons learned, formalizes ad-hoc patterns into proper skill files, refactors utility scripts for reusability, updates the project Glossary with new domain terminology, and registers everything in the central skills manifest.
type: workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Update Skills Skill — opencode workflow

**Type**: workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/update-skills"

## Purpose
Focused skill-upgrade pass — captures lessons learned from every skill used in a session, formalizes ad-hoc patterns into proper skill files, refactors utility scripts for reusability, updates the project Glossary with new domain terminology, and registers everything in the central skills manifest. Designed to make future skill use by agents more efficient, less confusing, and more helpful.

## Trigger
- User says "Update Skills" (or "update skills") to any agent
- After completing any session that used skills and generated lessons worth preserving

## Workflow steps
See `workflow.md` (this folder) for the full 6-phase procedure: Inventory → Lessons Learned → Formalize → Script Audit → Glossary → Registry.

## Sub-skills and tools
- `workflow.md` — full Update Skills Workflow (Phase 0–5)
- `tools.md` — tool configuration and constraints

## Key cross-references
- `Skills/skills.json` — skill registry
- `Skills/skills.schema.json` — registry validation schema
- `docs/Glossaries/` — project glossary (per-domain and shared)
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives
- `AGENTS.md` — naming conventions, script best practices

## Red lines
- **No git operations**: This skill audits, improves, and creates files only. It does not stage, commit, or push. The caller's Completion Checklist handles CC wrap.
- **No data loss**: Every lesson, every script refactor, every new skill file must be written to disk before the skill reports completion.
- **Read-only AWS Secrets Manager**: Same policy as AGENTS.md — no agent may write to AWS SM.
- **No empty placeholders**: Every skill file must have meaningful content. No stub files.
- **Never delete files**: Mark stale in `skills.json` with `superseded_by` instead.
- **Registry validation**: Every change to `skills.json` must conform to `skills.schema.json`.
- **Scripts must exist on disk**: Before referencing a script in a skill, verify the script file exists via glob or read.
- **Semantic naming**: All created/renamed files must follow `Skills/<domain>/<topic>.md` or `Skills/<domain>/<topic>/SKILL.md` convention. Scripts follow `Verb-Noun.ps1` (PowerShell) or `kebab-case.{py,js}`.

## Completion
Reports completion when all 6 phases are done. Does NOT enter a drain/poll loop — single pass. The caller's Completion Checklist handles CC wrap.
