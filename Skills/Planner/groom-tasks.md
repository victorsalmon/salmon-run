# Groom Tasks — Plan Mode Skill

Analyzes all task files in `Tasks/Code/` for naming correctness, connascence
extraction accuracy, and parallelization potential. Produces structured report
and optional execution order recommendation.

## When to invoke

- 10+ unprocessed plan files in `Tasks/Code/`
- Before dispatching a large batch to the orchestrator
- User says "groom tasks", "triage backlog", "audit naming"
- After an alignment audit generates a large batch of finding plans

## How it works

Single entry point: `Groom-Tasks-Skill/Invoke-GroomTaskInventory.ps1`

| Flag | Phase | What it does |
|------|-------|-------------|
| `-Validate` | 1-2 | Inventory + naming validation — flags date format drift, missing fields, lock conflicts |
| `-Analyze` | 3 | Connascence grouping — groups by corrected namespace, cross-refs Files + ConnascenceScope for overlap |
| `-SuggestOrder` | 4 | Topologically sorted execution order — parallel stages, serial chains, blocked items |
| `-FixNames [-Apply]` | 5 | Suggest/apply renames to standardize naming format |

Output: colorized console by default, or `-OutFile report.md`, or `-AsJson`.

## Dependencies

- `Get-ConnascenceGroups.ps1` — reuses cycle detection, DependsOn parser, ready-set computation
- `Invoke-GroomTaskRename.ps1` — rename executor (called by `-FixNames`)

## Canonical bug reported

The Groom skill detects that `Get-FileNamespace` in both
`LocalOrchestrator-FileHelpers.ps1` and `Get-ConnascenceGroups.ps1` uses regex
`^\d{4}\.\d{2}\.\d{2}` which only strips dot-separated dates. Files using
dash-separated dates (e.g. `2026-06-20-audit-1-32.md`) produce wrong namespaces.

The Groom skill uses its own corrected regex but does NOT patch the canonical
scripts. At the end of every `-Validate` run, it generates a Coder task stub to
fix the canonical `Get-FileNamespace` in both locations.
