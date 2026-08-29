# Salmon Run — Agent Context

`salmon-run` is the public, file-based Kanban control plane:
queue automation, pond dispatch, model routing, quality gates, and public packaging.

See `README.md` for the quick-start and `docs/PUBLIC_PACKAGE.md` for the runtime-layout.
The module catalog is in `docs/MODULES.md`.

## Public-package guardrails

- Runtime state lives under `~/.salmon` (or `%SALMON_RUN_HOME%`), never in the repo.
- Do not commit credentials, tokens, client hostnames, or internal fleet references.
- Use `~/.salmon/.env` for credential *redirects* (literal, `Env`, `File`, `AWS`, `GitHub`, `Worktree`, or custom resolvers), not literal secrets when avoidable.
- Prefer Salmon Run naming; preserve legacy aliases only when needed for compatibility.
- Modular commits, one concern each. Pull-rebase and push after each change.

## Runtime hygiene

- The orchestrator and health tools resolve the task root from `%SALMON_RUN_HOME%`
  and fall back to `~/.salmon`. Pester tests set this environment variable under
  the current user (`[Environment]::GetEnvironmentVariable('SALMON_RUN_HOME',
  'User')`) and sometimes leave it pointing at a temporary `TestDrive` path.
- Before starting `Run-SalmonRun.ps1` or calling `Get-SalmonRunHealthReport.ps1`,
  verify `SALMON_RUN_HOME` points to the intended runtime (e.g.
  `C:\Users\<user>\.salmon`). Clear a stale temp value with
  `[Environment]::SetEnvironmentVariable('SALMON_RUN_HOME', $null, 'User')` and
  set the process variable explicitly.
