---
name: review-manual-tasks
description: >
  Collect, verify, prune, and triage every open task in salmon-orchestrator\Tasks\
  (Manual/, Handoff/, ToDo/, queued Code/) plus any "human-do-next" / "needs-user" /
  "do not auto-apply" markers across the C:\Repos fleet, then sort the survivors into
  Manual Decisions vs Manual Actions, ask the user only the decision-point questions
  needed to minimize manual work, complete everything an agent can do autonomously,
  file completed items to Tasks\Complete\, and present a final sorted list. Use when
  the user says "review manual tasks", "review the queue", "triage handoffs", "clean
  up Manual/", "what's left for me to do", "stale tasks", or wants the task queue
  reconciled with current code/repo/AWS reality.
triggers:
  - user
  - model
---
# Review Manual Tasks

## Purpose
Reconcile the `C:\Repos\salmon-orchestrator\Tasks\` queue with current reality (code,
branches, deploys, AWS state), then hand the user a short, verified, sorted list of the
genuinely-human items. Most "manual" tasks are stale, superseded, or secretly automatable.

## Scope — what to collect
1. All `Tasks/Manual/*.md`, `Tasks/Handoff/*.md`, `Tasks/ToDo/*.md`, and queued
   `Tasks/Code/*.md` (a plan stuck in Code/ may be a misplaced handoff).
2. A ripgrep sweep of `C:\Repos\*` for `human-do-next`, `needs-user`, `MANUAL`,
   `do not auto-apply`, `operator action required` — catches items outside the queue.

## Workflow (the 9 steps)
1. **Collect** everything in Scope.
2. **Verify state & prune stale.** For each task: `git log`/`git show` on referenced
   commits & branches; rerun dry-run `branch-worktree-hygiene`; live AWS check where a
   profile can reach the resource (pause for SSO 2FA only if a re-login is actually
   required). Delete irrelevant/superseded; **update-in-place** for relevant-but-stale.
3. **Group** survivors into related collections (e.g. "Stripe/Helcim", "quality/compliance",
   "orchestrator dispatch hygiene epic").
4. **Sort** into **Manual Decisions** vs **Manual Actions**, annotating every row with the
   standard legend so the user sees the *kind* of blocker at a glance:
   `👤 human-only · 💬 decision (clearable via Q&A) · 🔑 needs deploy/credential access`.
   Most Decisions are 💬; Actions split into 👤 (judgement/browser steps) and 🔑
   (console/credential/deploy steps). Use the legend verbatim — it's the house style.
5. **Ask the decision questions** in one focused batch; record answers back into the handoffs.
6. **Refine + describe** the automated work; bound it clearly.
7. **Execute** the automated work. Report each outcome faithfully (green / red / skipped).
8. **Move completed** handoffs/tasks → `Tasks/Complete/` (flat at the root).
9. **Present** the final sorted lists; when the user reports an item done, verify to the
   best of your ability (git / AWS / browser) and move it to `Complete/`.

## Disposition rules
- **Delete** — irrelevant/superseded transient stubs (auto-generated triage, missing-dep
  markers, point-in-time snapshots overtaken by a fresh run). Confirm it isn't a lane
  mid-pipeline first (check `git log`, `Tasks/Working/`).
- **Update in place** — still relevant but specifics drifted (shifted `file:line`, a
  workaround now optional, status that has progressed). Stamp a `> Superseded by …`
  header on docs kept only for history.
- **Keep active** — genuine open decisions/actions awaiting the user.
- **Consolidate** — overlapping same-root-cause bug reports → one epic plan in
  `Tasks/Project/` (or `Tasks/Code/` if ready), not N parallel tickets.
- Everything salmon-orchestrator touches is git-tracked → deletions are reflog-recoverable.

## Patterns observed in the wild (lessons from the 2026-08-13 run)
- **Auto-generated stubs regenerate.** Tempo/health-check triage files reappear after
  deletion — deleting only clears them until the next cron. Note as orchestrator noise;
  don't fight them every run.
- **Consolidate same-root-cause bug reports into one epic.** 7 overlapping dispatch/recovery
  bug reports → 1 epic with 2 root-cause clusters + `file:line` evidence, routed to the planner.
- **Re-verify every "resolved" claim by re-running.** A blocker marked "RESOLVED — Skills/Docker
  populated" was only populated in salmon-orchestrator, not the app-repo targets; the rerun
  crashed. Trust nothing labeled done until you've re-executed it.
- **Sweep for out-of-queue `HUMAN-DO-NEXT.md` / `to-do.md` files** in each repo — they often
  hold active items the orchestrator queue doesn't (e.g. a repo's own SES request, CDN cutover).

## When to invoke manually
- The user asks "what's left for me", "review the queue", or returns after time away.
- `Manual/` or `Handoff/` accumulates > ~10 files (the active queue is getting noisy).
- Before a sprint review, deploy gate, or any point where the human needs a clean to-do list.

## Red lines
- **Never** apply a migration / deploy / outward-facing change the task explicitly gates
  to the user (e.g. "do not auto-apply without sign-off"). Surface it; don't act.
- **Never** leak secrets (AKIA strings, secret-key values, `~/.aws/credentials`).
- **Never** attribute a filesystem change to the user without `git log` verification.
- **Never** write task files to a target repo's `Tasks/` — the single queue is
  `salmon-orchestrator\Tasks\`.

## Output
A short final report with two tables — **Manual Decisions** and **Manual Actions** —
each row linking its source task file and annotated with the legend
(`👤 human-only · 💬 decision (clearable via Q&A) · 🔑 needs deploy/credential access`),
plus a one-line summary of what was automated, deleted, updated, and moved to `Complete/`.

> **Legend:** 👤 human-only · 💬 decision (clearable via Q&A) · 🔑 needs deploy/credential access
