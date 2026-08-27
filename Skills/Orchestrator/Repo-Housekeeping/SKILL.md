---
name: opencode/workflow/repo-housekeeping
description: Cross-repo maintenance workflow — archive stale plans, clean working trees, audit roadmaps against implementation, write gap-fill session plans, and dispatch the local orchestrator.
type: workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Repo Housekeeping Workflow

**Type**: workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/repo-housekeeping"

## Purpose
Provides a repeatable, multi-repo maintenance pass for the ORCHESTRATOR fleet: archive completed plans that exceed a retention window, rescue worthwhile plans from failed/superseded storage, clean dirty working trees across repositories, audit roadmaps against implementation status, convert gaps into session plans, and dispatch the local orchestrator to process them.

## Trigger
- User asks for "repo housekeeping", "clean up repos", "archive old plans", "commit and push everything", or "find roadmap gaps and write plans".
- After a burst of parallel agent activity leaves working trees dirty or `Tasks/Complete/` unarchived.
- When the orchestrator has drained and a new batch of work needs to be queued.

## Workflow steps

### Phase 0: Discover repositories
1. Scan `C:\Repos` (or the configured workspace root) for directories containing `.git`.
2. Record the repo list and their current `git status --porcelain` counts.

### Phase 1: Archive stale completed plans
1. Determine the cutoff date (default: plans older than 7 days).
2. List all `.md` files under `<repo>/Tasks/Complete/` whose filename contains a parseable date before the cutoff.
3. For each file, compute the target path under `<repo>/Tasks/Archive/Complete/` preserving subdirectory structure.
4. If the destination already exists, move with a `-duplicate<N>` suffix rather than overwriting.
5. Use `git mv` per file or per small batch; avoid moving multiple sources into an existing destination directory in one `git mv` call.
6. Stage, commit, pull-rebase, push per repo with modular messages (e.g., `archive: move 2026-06 completed plans`).

### Phase 2: Rescue worthwhile failed plans
1. Read the contents of `<repo>/Tasks/Archive/Failed/` (or equivalent).
2. Classify each item:
   - **Deprecated / superseded**: daemon architecture, removed features, empty stubs — leave archived.
   - **Actual plan files for active features**: move to `<repo>/Tasks/Review/` for a review pass.
   - **Failure logs (`*.failure.md`)**: not plans; do not rescue unless they contain unique diagnostic value.
3. Commit rescued plans with `review: rescue X from Archive/Failed`.

### Phase 3: Clean working trees
1. For each repo with uncommitted changes, inspect `git status --porcelain`.
2. Group changes into modular, semantic commits:
   - `plan:` for `.zcode/plans/` or session-plan files
   - `feat:` / `fix:` for source changes
   - `docs:` for documentation
   - `chore:` for config, `.gitignore`, env examples
   - `archive:` for moved/deleted plans
3. Do not commit runtime artifacts (PID files, `.agent-id.txt`, `Tasks/Working/` state). Add them to `.gitignore` instead.
4. Run `git pull --rebase --autostash && git push` after each repo's commits.

### Phase 4: Audit roadmaps and implementation
1. For each repo, locate `roadmap.md` and `implementation.md` (or `ROADMAP.md` / `IMPLEMENTATION.md`).
2. Use parallel read-only subagents to compare stated roadmap items with actual files:
   - Search for `TODO`, `FIXME`, `not-implemented`, `NotImplementedException`.
   - Compare milestone tables to directory/module inventory.
   - Identify completed-but-not-marked and scoped-but-not-started items.
3. Synthesize a gap list per repo with file paths and recommended session-plan titles.

### Phase 5: Write gap-fill session plans
1. For each actionable, code-able gap, create a session plan under `<fleet-repo>/Tasks/Code/` using the `YYYY.MM.DD-<namespace>-<description>.md` convention.
2. Set `ConnascenceScope` to the affected files. For cross-repo work, use absolute paths like `C:\Repos\<repo>\...` and include explicit `cd` / `git -C` instructions in the plan.
3. Keep plans focused: one concern per plan. Avoid umbrella plans that would exceed a single agent session.
4. Commit the new plans before starting the orchestrator.

### Phase 6: Dispatch the orchestrator
1. Check `Get-Process | Where-Object { $_.Name -match 'orchestrat|pwsh|opencode' }` and `Tasks/Logs/orchestrator-*.log` for an active orchestrator.
2. If not running, launch with `& 'Orchestrator/Orchestration/Invoke-Orchestrate.ps1' -DetachWatchdog`.
3. Verify heartbeats appear in `Tasks/Logs/agents/` and the `Tasks/Code/` count begins to drop.

## Red lines
- **No `git add -A` / `git commit -a`**: stage per concern.
- **No cross-repo `git mv`**: archive within each repo; do not bulk-move files between repos.
- **No committing of runtime artifacts**: agent IDs, heartbeats, `Tasks/Working/` contents, `.complete` markers belong in `.gitignore`.
- **Do not force-push**: always `pull --rebase --autostash` before push.
- **No credentials in skill files or session plans**.

## Changelog
- 2026-07-23: Created from 2026-07-23 multi-repo housekeeping, archive, rescue, roadmap-audit, and orchestrator-dispatch session.

## Cross-references
- `Skills/Create/Skill-Authoring/UpdateSkills/SKILL.md` — skill-upgrade pass after this workflow
- `Skills/Planner/Write-SessionPlan.ps1` — naming helper for new plans
- `Orchestrator/Orchestration/Invoke-Orchestrate.ps1` — orchestrator launcher
- `Orchestrator/Orchestration/Invoke-MonitorSubagents.ps1` — live agent status
- `AGENTS.md` — git and commit conventions
