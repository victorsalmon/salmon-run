# OpenCode Workflow Tool Baseline — Canonical Reference

> **Audience**: Every opencode workflow (Bookkeeper, Audit, Code, Cowork, Plan, Redeploy, Rescue, Review, Secrets, Therapy, UpdateSkills). The per-workflow `tools.md` links here instead of duplicating the common baseline.

This is the opencode-CLI side of the tool baseline (the fleet container side is at `Skills/Orchestrator/Personas/Shared/tool-baseline.md`). The two are similar but distinct audiences — the opencode CLI has different allowed tools than the fleet containers.

## Allowed tools

Every opencode workflow gets the standard tool set:

| Tool | Purpose |
|------|---------|
| `Bash` | Run scripts, git operations, docker commands, tests |
| `Read` | Read existing files (code, config, docs) |
| `Write` | Write new files |
| `Edit` | Edit existing files |
| `Glob` | Find files by pattern |
| `Grep` | Search for patterns in file contents |
| `WebFetch` | Fetch web pages for research |
| `Skill` | Load named skills from the registry |

Workflows that need additional tools (e.g., Playwright for browser automation) declare them in their per-workflow `tools.md`.

## Model defaults

- **Default**: deepseek-v4-flash (or tier-equivalent — see `Infrastructure/ORCHESTRATOR/providers/<tier>-ORCHESTRATOR.json`).
- **Escalation to Pro**: when the task involves multi-file architectural changes, debugging a non-trivial error, planning a multi-step session, or any task that exceeds 50% context window. The `complexity: complex` tag triggers Pro routing.
- **Never hardcode model names.** Use `complexity: complex` or `complexity: simple` to route.

## File operation rules

- **Read-before-write**: any file modification MUST be preceded by a Read of the current contents (unless creating a new file).
- **Paths via `$env:USERPROFILE`**: never hardcode `C:\Users\Victor\...` in commands.
- **Directory-agnostic commands**: commands must work from any working directory.
- **Use the file-search tools, not shell `ls`**: use `Glob` for pattern matching, `Grep` for content search, `Read` for content.

## Error handling

- **Write-Error for recoverable**: errors that the next agent can fix are Write-Errors with a clear message.
- **Exit codes matter**: a non-zero exit is a hard failure.
- **Circuit breakers**: 3 consecutive identical errors → halt and re-groom. 5 same-error or 8 total iterations → stop trigger.
- **No silent retries**: if a command fails, the agent must read the actual error before retrying.

## Credential safety

- **Never log a secret value**: only the secret *name* (e.g., `ORCHESTRATOR_GATEWAY_TOKEN`) is logged.
- **Never commit a secret**: any value starting with `aws_`, `token`, `key`, `secret` in a committed file is a P0 incident.
- **AWS SM is read-only**: agents never write to AWS Secrets Manager.

## Git discipline

- **Per-file staging**: `git add <file>` per-file. Never `git add -A` or `git commit -a`.
- **No force-push to main**: `git push --force` to `main` is forbidden.
- **No amend of pushed commits**: once a commit is pushed, it's immutable.
- **Rebase before push**: Run `Invoke-GitPullSafe` (`Skills/DevOps/Git/Invoke-GitPullSafe.ps1`) before `git push` to avoid restoring stale deleted files.
- **Per-concern commits**: one logical change per commit. Use semantic messages.

## Output conventions

- **Terse responses**: short, direct answers. No preamble, no postamble.
- **Test-before-report**: every "task completed" claim must have supporting output (test pass, command stdout, API response).
- **No preamble**: don't announce what you're about to do. Just do it.
- **Markdown only**: do not mix Markdown and HTML. Use GitHub-flavored markdown.

## Tool timeout defaults

- **Default `timeout`**: 120s (the bash tool's default). Override with `timeout` parameter for longer operations.
- **Long operations** (10-cycle polling, 20 min): set `-Timeout 600000` (10 min) for individual bash calls. The full 20-min polling is composed of multiple 2-min sleeps.
- **Test runs**: Pester tests typically finish in 60-300s. Use `-Timeout 600000` for the full test suite.
- **RunFix Deploy**: docker image builds can take 5-10 min per image. Use `-Timeout 1800000` (30 min) for redeploy operations.

## Tool selection notes

- **`rg` (ripgrep) preferred over `Select-String` for cross-platform** — but `rg` may not be available on Windows PowerShell. Use `Select-String` natively; use `rg` when on Linux/macOS or when installed.
- **`Test-Path`, `Get-ChildItem`, `Select-String` work natively** in PowerShell — no extra dependencies.
- **Glob/Grep tools** are preferred over shell equivalents when searching the workspace — they handle encoding and binary files correctly.
- **Read tool** is preferred over `Get-Content` — it returns structured output with line numbers.

## Per-workflow deltas

Each workflow's `tools.md` documents its deltas (typically 1-3 sections):

- **Bookkeeper** — Zoho Books API credential resolution, container paths, scripts inventory
- **RunFix Deploy** — Docker build preflight, 5-layer diagnosis
- **Secrets** — `execSync` with secret ID detection, TLS validation
- **Therapy** — guardrails G1-G16, modality explanations
- **UpdateSkills** — registry validation, skill audit checks

## Related skills

- `Skills/Workflows/<workflow>/tools.md` — workflow-specific deltas
- `Skills/Orchestrator/Personas/Shared/tool-baseline.md` — fleet container side (similar but distinct)
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — workflow primitives (different topic)
