# Salmon Run — Agent Context

`salmon-run` is the public, file-based Kanban control plane:
queue automation, pond dispatch, model routing, quality gates, and public packaging.

See `README.md` for the quick-start and `docs/PUBLIC_PACKAGE.md` for the runtime-layout.
The module catalog is in `docs/MODULES.md`.

## Public-package guardrails

- Runtime state lives under `~/.salmon` (or `%SALMON_RUN_HOME%`), never in the repo.
- Do not commit credentials, tokens, client hostnames, or internal fleet references.
- Prefer Salmon Run naming; preserve legacy aliases only when needed for compatibility.
- Modular commits, one concern each. Pull-rebase and push after each change.
