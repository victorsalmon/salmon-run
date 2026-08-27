# Tool Baseline — Canonical Reference

> **Audience**: Every persona (BASE, ORCH, VERI) loads this file at session startup. The persona-specific `tools.md` files link here instead of duplicating the common baseline.

Common tool constraints for all personas. Each persona's `tools.md` documents its deltas (typically 1-3 sections).

## Model defaults

- **Default**: deepseek-v4-flash (or tier-equivalent — see `Infrastructure/ORCHESTRATOR/providers/<tier>-ORCHESTRATOR.json`).
- **Escalation to Pro**: when the task involves multi-file architectural changes, debugging a non-trivial error, planning a multi-step session, or any task that exceeds 50% context window. The `complexity: complex` tag triggers Pro routing.
- **Never hardcode model names.** Use `complexity: complex` or `complexity: simple` to route. The role's `opencode.json` maps these tags to the configured models for the deployment's sovereignty tier.

## File operation rules

- **Read-before-write**: any file modification MUST be preceded by a Read of the current contents (unless creating a new file).
- **Paths via `$env:USERPROFILE`**: never hardcode `C:\Users\Victor\...` in commands. Use `$env:USERPROFILE\intersite-orchestrator\...` for the repo and `$env:USERPROFILE\.ORCHESTRATOR\...` for owner config.
- **Directory-agnostic commands**: commands must work from any working directory. Never `cd` to a path before running a command; use the `workdir` parameter or absolute paths.
- **Use the file-search tools, not shell `ls`**: use `Glob` for pattern matching, `Grep` for content search, `Read` for content. Reserve `bash` for git, docker, and tests.

## Error handling

- **Write-Error for recoverable**: errors that the next agent can fix (missing config, broken ref, etc.) are Write-Errors with a clear message. The agent should NOT halt the session.
- **Exit codes matter**: a non-zero exit is a hard failure. The agent should NOT proceed past a non-zero exit without investigating.
- **Circuit breakers**: 3 consecutive identical errors → halt and re-groom. 5 same-error or 8 total iterations → stop trigger (escalate).
- **No silent retries**: if a command fails, the agent must read the actual error before retrying.

## Credential safety

- **Never log a secret value**: only the secret *name* (e.g., `ORCHESTRATOR_GATEWAY_TOKEN`) is logged.
- **Never commit a secret**: any value starting with `aws_`, `token`, `key`, `secret` in a committed file is a P0 incident.
- **AWS SM is read-only**: agents never write to AWS Secrets Manager. See `AGENTS.md § AWS Secrets Manager Policy`.
- **Telegram bot tokens, Attio API keys, etc.** are mounted as Docker Swarm secrets. The agent reads them from `process.env.<NAME>` or `req.fleet.token`, never from a file.

## Git discipline

- **Per-file staging**: `git add <file>` per-file. Never `git add -A` or `git commit -a`.
- **No force-push to main**: `git push --force` to `main` is forbidden. Use feature branches.
- **No amend of pushed commits**: once a commit is pushed, it's immutable.
- **Rebase before push**: Run `Invoke-GitPullSafe` (`Skills/DevOps/Git/Invoke-GitPullSafe.ps1`) before `git push` to resolve non-fast-forward conflicts without restoring stale deleted files.
- **Per-concern commits**: one logical change per commit. Use semantic messages (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`).

## Log levels

- **DEBUG**: detailed per-step info (e.g., a single file edit). Verbose. Set `ORCHESTRATOR_LOG_LEVEL=DEBUG` to enable.
- **INFO**: state transitions (start/end of a task, lock acquired, commit made). Default level.
- **WARN**: recoverable errors, degraded state, audit anomalies. Should be reviewed.
- **ERROR**: hard failures that require agent action. Always logged.

Set `$env:ORCHESTRATOR_LOG_LEVEL = 'DEBUG'` for verbose logging during debugging. Default is INFO.

## Memory & context

- **Compact-and-persist at handoff**: when context exceeds 100K tokens or 10% of total context window, the agent writes a namespace log entry via `Write-NamespaceLog -Namespace <domain> -Type NOTE` and starts fresh.
- **Fresh session on new task**: don't carry over state from a previous task. The new task gets a fresh context.
- **Lean mode**: if the plan has `**Lean**: true`, skip multi-line status blocks, use `Write-SetupLog` directly with condensed messages.

## Communication rules

- **Telegram/Signal formatting**: bullet lists only (no tables), links in `<>` brackets, code in backticks. Tables don't render on Signal.
- **Approval queue gate**: external communications (emails, LinkedIn, social media) go through the approval queue. Never send without explicit owner authorization.
- **Heartbeat protocol**: every N minutes, the agent runs a heartbeat poll to check for new work. See `Personas/<ROLE>/heartbeat.md`.

## Documentation-First Principle

> When asked about any tool, service, or capability, consult relevant documentation first. Do not guess.

If the answer is in a skill file, read it. If it's in a `.md` reference, read it. If it's in code, read the source. Never fabricate an API surface or behavior.

## Red lines

- **Never expose secrets in logs or commits.**
- **Never update git config, skip hooks, or force-push to main.**
- **Never declare "done" with uncommitted changes in the working tree** — `git status --porcelain` must be empty.
- **Never skip the Cross-Reference consistency check** — every code change must update `AGENTS.md`, `Diagrams.md`, and the affected persona templates.
- **Never use `trash`/`rm` without a verification step.** Read the file first; if the file is untracked, ask before deleting.

## Script troubleshooting (RunFixFleet)

When a script fails and the root cause is unclear, use the **RunFixFleet methodology** — a self-looping iterative fix technique that works in any environment (host or fleet container) with no PowerShell dependency.

**How it works:** The agent reads the methodology at `Skills/Archive/workflow-runfix-runfix-fleet-template.md`, then self-loops within the current session: run target → check output against rubrics → diagnose and fix source → re-run until success or max cycles. No subprocess, no detached engine, no opencode command registration needed.

**Invocation pattern** — include this line in any handoff doc, plan, or prompt:
> Use the RunFixFleet methodology at `Skills/Archive/workflow-runfix-runfix-fleet-template.md` — self-loop until the script passes exit code 0 with no `CRASH_EVIDENCE:` markers, or write an unfixable plan to `Tasks/Code/` if diagnosis fails.

**Built-in rubric defaults** (used when no goals file exists):
- Exit code 0
- No `CRASH_EVIDENCE:` in output (agent crash detection)
- Max 10 cycles
- Auto-detect script mode (has extension) vs command mode (no extension)

**Agent crash detection:** The `CRASH_EVIDENCE:` marker in output indicates a subagent (coder/reviewer) crashed. This is a hard failure — investigate the evidence files at the path after `->` in the marker, fix the root cause in source code, and only then re-run. If unfixable, write a plan to `Tasks/Code/` with what was tried and what needs fixing.

**When to use:**
- A fleet container script fails with an unfamiliar error
- A host-run PowerShell script (deploy.ps1, etc.) fails and the host RunFix engine is not available or appropriate
- Any troubleshooting that would benefit from iterative run → diagnose → fix cycles

**When to use the host RunFix instead:** For long-running autonomous loops (60+ cycles, multi-hour runs) on the host machine, use `opencode run --command runfix` with a goals file at `Skills/Workflows/RunFix/runfix-<name>.md`. The host RunFix runs as a detached PowerShell process that survives TUI crashes and doesn't consume session context.

## Per-persona deltas

- **ORCH** — Telegram/Signal formatting rules, Approval Queue Protocol (delegated to VERI)
- **VERI** — mcp_opencode dispatch (the Two-Agent Workflow), VERI never communicates directly with `{OWNER_SHORT_NAME}`. VERI dispatches to fleet containers that use RunFixFleet for troubleshooting.
- **BASE** — Self-verification rubric (mandatory before delivery), Solo self-loop

## Related skills

- `Personas/{BASE,ORCH,VERI}/tools.md` — persona-specific deltas
- `Skills/Orchestrator/tools.md` — opencode workflow tool baseline (similar but distinct audience)
- `Skills/Orchestrator/Personas/Shared/protocols.md § Logging Protocol` — log level details
- `Skills/Archive/workflow-runfix-runfix-fleet-template.md` — RunFixFleet methodology reference
- `Skills/Cowork/RunFix/runfix.md` — Host RunFix engine (PowerShell-based)
- `Skills/Cowork/RunFix/runfix-localorchestrator.md` — Orchestrator-specific RunFix goals with agent crash evidence rubrics
