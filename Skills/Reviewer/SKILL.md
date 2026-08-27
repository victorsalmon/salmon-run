---
name: opencode/workflow/review
description: Reviewer role workflow — audit completed session plans for quality, correctness, and completeness.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Review Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/review"

## Purpose
Audit completed session plans. Runs the Reviewer Iterative loop: claim plan → check outputs → assess completion → write feedback or archive. Drains the `Tasks/Review/` queue.

## Trigger
- User says "Review" or "review" (case-insensitive, see `role-routing.md`)
- An orchestrator dispatches `work-review` from opencode.json

## Workflow steps
See `workflow.md` (this folder) for the full interactive Reviewer procedure (Phase 1–5, including HANDSHAKE event, completion verification, and feedback generation).

## Audit patterns
**Best practices** distilled from past review passes — apply to every audit:

- **Git-first verification** — for post-hoc plans, use `git log --oneline -- <files>` and `git show HEAD:<file>` to confirm code is already in HEAD before re-running pipelines. Efficient when the plan describes work that was already committed
- **Batch-read for connascence** — when multiple review files share a session context, read them in parallel before auditing to surface cross-session dependencies
- **Per-file timing** — append elapsed seconds to `.session-timing.txt` per file; aids session telemetry and post-hoc review of which files took the most time
- **Manual task for in-flight bugs** — if the audit discovers a real bug (not the audit's responsibility to fix), create a `Tasks/Manual/<date>-<topic>.md` describing the bug, its current state, and what an agent/user needs to do
- **Verify scope of the claim** — when Coder says "X exists at path P", verify the file actually exists at P AND check the SKILL.md/documentation that references P (the path may be correct in the script but wrong in the docs)
- **Post-hoc plans: scan all task files** — use `Get-ChildItem -Filter "*.md"` to enumerate, not a glob filter that may miss files added since the plan was written

**Troubleshooting** — what doesn't work, and why:

- **Agent ID collision via shared `.session-agent.txt`** — when multiple agents run concurrently, the file that stores `$env:OC_RESERVATION_AGENT_ID` gets overwritten. Symptom: `Move-Item` errors with a path under a different agent's ID. Fix: set `$env:OC_RESERVATION_AGENT_ID` directly from a per-script variable, not from the shared file. Re-import modules after the variable change
- **Workflow events mutex contention** — the global `Interclaw-WorkflowEvents-Mutex` semaphore can be held by a concurrent agent. Symptom: `Write-WorkflowEvent: Mutex timeout after 5000ms`. Fix: add retry loop with 2-3s backoff, max 5 retries
- **Coder path claims in posthoc plans** — posthoc plans often record the path the Coder intended (e.g., `C:\Scripts\rdp.ps1`) but the actual file may live elsewhere (e.g., `~/Scripts/rdp.ps1`). Cross-check with the user when the claim is unverifiable
- **Encoding-fix reintroduction** — plans that claim "0 non-ASCII bytes" after an encoding fix can be undone by subsequent sessions adding decorative headers. Audit encoding-fix plans by checking the full file list, not just the plan's target files

**Helpful information** — context that aids future audits:

- The Coder/Release protocol uses `git show HEAD:<file>` and `git show <commit> --stat` to verify claims — these are the primary verification tools for post-hoc audits
- 76 pre-existing Skills Registry Gate failures (cross-reference drift) are long-standing and not regressions from any single session. New failures in a session's diff are regressions
- The 6-phase Update Skills workflow (`Skills/Create/Skill-Authoring/UpdateSkills/SKILL.md`) is the recommended way to capture review-session lessons. Run it after every non-trivial Review pass

## Sub-skills and tools
- `workflow.md` — full Reviewer Workflow (Phase 1–5)
- `tools.md` — tool configuration and constraints

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Connascence, Lock Header, Drain Queue)
- `Skills/Workflows/Shared/session-plan-format.md` — plan format spec
- `Skills/Cowork/handoff.md` — handoff and feedback generation
- `Skills/Create/Skill-Authoring/UpdateSkills/SKILL.md` — capture review-session lessons into skill bodies (single pass)

## Red lines
- **Never modify code** — Reviewer audits, Coder fixes. Feedback files go to `Tasks/Code/`.
- **Never skip Pester tests** — verify all tests pass before signing off.
- **Never skip the Lock Header** — every plan file gets a Lock Header on claim.
- **Never delete tasks created by other agents** — only modify tasks claimed by your own agent ID.

## Completion
Commit/push are part of the Finale step in `workflow.md` (step 3). After Finale, return to Drain Queue (step 4). After poll exhausts, emit `Status: Completed <task-name>`.

## Changelog
- 2026-06-16: Integrated Review session lessons (13-file audit pass) into Audit patterns + Troubleshooting sections; added UpdateSkills cross-reference; replaced legacy dated block with consolidated body
- 2026-06-15: Documented post-hoc plan auditing via git commits; recorded encoding-aware review patterns
