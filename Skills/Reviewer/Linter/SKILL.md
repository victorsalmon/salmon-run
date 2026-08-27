---
name: linter
description: >
  The Reviewer/Linter lane. After a Reviewer audit succeeds, this lane drains
  Tasks/Lint/, removes code smell, runs documentation lint and a secret audit,
  builds the project, runs unit tests and mutation testing, then decides
  pass/fail. Passing work moves to Tasks/Complete/; failing work returns to
  Tasks/Code/ with a feedback file. Use when a plan reaches the lint stage of
  the salmon-run queue (Review -> Lint -> AQE -> Complete).
triggers:
  - "lint this plan"
  - "run the lint lane"
  - "lint and build and test"
---

# Linter (Reviewer/Linter lane)

The Linter is the **validation lane** that sits between **Review** and **AQE**
in the salmon-run queue:

```
Intake -> Code -> Review -> Lint -> AQE -> Complete -> Archive
```

It is the automated gate that proves a plan's change actually builds, lints,
and passes tests before it reaches the **Complete** pond.

## Responsibilities

For each plan file in `Tasks/Lint/`, in order:

1. **Code smell** — apply `fix-code-smell` (remove duplication, rename for
   clarity, add targeted comments). Non-destructive: it edits working tree
   files, not the plan.
2. **Documentation lint** — run `Invoke-DocLint.ps1` over `docs/`, `AGENTS.md`,
   and `Skills/**/*.md`. Fail on broken file-path references.
3. **Secret audit** — scan changed files for committed secrets
   (`AKIA*`, `*_SECRET`, private key blocks, tokens). Fail on any hit.
4. **Build** — invoke the project build for the touched language
   (PowerShell: parse-check; Node: `npm run build` / `tsc`; Python:
   `python -m py_compile`).
5. **Unit tests** — run the suite for touched modules (Pester for PowerShell,
   `vitest`/`jest` for Node, `pytest` for Python).
6. **Mutation testing** — run the mutation gate for touched modules when a
   runner is configured (e.g. Stryker for Node). Optional but recommended.

## Decision

- **Pass** — all steps succeed. Write evidence to
  `~/.salmon/Tasks/Logs/lint-<plan>-<ts>.json` and move the plan to `~/.salmon/Tasks/Complete/`.
- **Fail** — any step fails. Write a feedback file to `~/.salmon/Tasks/Code/` using
  `~/.salmon/Tasks/Templates/lint-feedback-template.md`, fix what is safe to fix
  automatically, and move the plan back to `~/.salmon/Tasks/Code/` for the Coder to
  address. The Linter never silently rewrites behaviour that changes intent.

## Running the lane

The lane is drained by the dispatcher:

```powershell
& (Resolve-Path "Orchestrator/Orchestration/Invoke-LintLane.ps1") -Once
```

Loop mode (for the scheduler):

```powershell
& (Resolve-Path "Orchestrator/Orchestration/Invoke-LintLane.ps1") -Loop -IntervalSeconds 120
```

## Wiring into the orchestrator

After a Reviewer audit succeeds, the orchestrator should move the plan from
`Tasks/Review/` to `Tasks/Lint/` (the Lint lane input). This is configured in
the post-Review step of `LocalOrchestrator.ps1` and the review completion
handler. The lane itself is `Invoke-LintLane.ps1`.

## Evidence schema

`Tasks/Logs/lint-<plan>-<ts>.json`:

```json
{
  "plan": "<plan-name>",
  "started": "<iso-8601>",
  "finished": "<iso-8601>",
  "result": "pass | fail",
  "steps": {
    "codeSmell": "ok | skipped | fixed",
    "docLint": "pass | fail | skipped",
    "secretAudit": "pass | fail | skipped",
    "build": "pass | fail | skipped",
    "unitTests": "pass | fail | skipped",
    "mutation": "pass | fail | skipped"
  },
  "feedbackFile": "<path or null>"
}
```
