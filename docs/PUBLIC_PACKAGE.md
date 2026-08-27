# salmon-run public package layout

## Separation of concerns

The `salmon-run` repo is the public, source-only package. It contains code,
skills, docs, and tooling. It must never contain personal or environment-specific
data.

The runtime home is `~/.salmon` (or `%SALMON_RUN_HOME%`). This is where all
mutable, user-specific, and potentially sensitive state lives.

| What | Repo path | Runtime home path |
|------|-----------|-------------------|
| Source modules, skills, docs | `Modules/`, `Skills/`, `docs/` | - |
| Task queue files | - | `~/.salmon/Tasks/*` |
| Session logs | - | `~/.salmon/Tasks/Logs` |
| User configuration | `dot-salmon.example/config.example.json` | `~/.salmon/config.json` |
| Credential redirects | `dot-salmon.example/.env.example` | `~/.salmon/.env` |
| Runtime secrets / cache | - | `~/.salmon/secrets`, `~/.salmon/cache` |
| Installed modules | - | `~/.salmon/Modules` or `$PSModulePath` location |
| Build/package metadata | `package.json`, `install.ps1` | - |

## `.salmon` contents

The installer (`install.ps1`) creates and owns these directories:

- `~/.salmon/Tasks/Intake` - interactive intake and feature-discovery stubs
- `~/.salmon/Tasks/Code` - coder plans
- `~/.salmon/Tasks/Review` - completed plans awaiting review
- `~/.salmon/Tasks/QA` - property/mutation test maturation
- `~/.salmon/Tasks/Audit` - best-practice and code-smell review
- `~/.salmon/Tasks/Working` - in-progress plans and lock files
- `~/.salmon/Tasks/Complete` - completed plans awaiting archival
- `~/.salmon/Tasks/Archive` - archived plans
- `~/.salmon/Tasks/Failed` - failed or blocked plans
- `~/.salmon/Tasks/Manual` - human-action instructions
- `~/.salmon/Tasks/Handoffs` - handoff stubs
- `~/.salmon/Tasks/Temp` - temporary plan drafts
- `~/.salmon/Tasks/Logs` - agent and orchestrator logs
- `~/.salmon/Tasks/Project` - project plans
- `~/.salmon/Tasks/ProjectReview` - project review plans
- `~/.salmon/Tasks/Schedules` - scheduled plan files
- `~/.salmon/cache` - runtime cache
- `~/.salmon/secrets` - local secret storage (fallback, never committed)

## Copying from the canonical repo

Use `scripts/Sync-FromCanonical.ps1` to copy canonical source into this repo.
After copying, run `scripts/Invoke-LeakCheck.ps1` and fix every hit before
committing. The sync script intentionally does **not** copy the `Tasks/`,
`docs/`, or private configuration trees.

## Module catalog

See `docs/MODULES.md` for the list of public modules and how to add a new one.
