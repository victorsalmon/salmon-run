---
name: intake
description: >
  Intake session workflow for salmon-orchestrator. Use when a request is too
  large, too ambiguous, or depends on facts/answers that must be gathered before
  implementation plans can be safely split into Code sessions. An Intake session
  lives in Tasks/Intake/, asks focused questions, records evidence, and produces
  one or more Tasks/Code/ plans.
triggers:
  - user
  - model
---

# Intake Session Workflow

An **Intake** is a question-and-evidence-gathering session for work that cannot
be safely dispatched as a Code session yet. It is the planning analogue of a
doctor's intake: collect symptoms and history before writing a prescription.

## When to use Intake

Use an Intake session before creating `Tasks/Code/` plans when any of the
following are true:

- The request spans multiple Code sessions and the exact split is not yet known.
- Important product, architecture, or deployment decisions are still open.
- The codebase inspection has revealed blockers or contradictions that a human
  must resolve.
- The session's output is intended to be **other session plans**, not code.

Do **not** use Intake as a substitute for repository inspection. If the answer
can be found by `grep`, `read`, or running tests, record it directly in the
Intake evidence log and do not list it as a question.

## Output location

- Intake session plans: `C:\Repos\salmon-orchestrator\Tasks\Intake\`
- Format: same session plan format as `Tasks/Code/`, but `**Status**` may be
  `intake`.
- Artifacts produced by the Intake (answers, evidence, decision records) live in
  the same `Tasks/Intake/` directory.
- Once the Intake is complete, the author creates the resulting `Tasks/Code/`
  plans and updates the Intake with `Code plans created:` references.

## Intake plan structure

Each Intake plan MUST contain:

1. **Objective** — the decision/evidence the session must produce.
2. **Scope** — what is in and out of this Intake (do not also do the
   implementation here).
3. **Question inventory** — each question classified as one of:
   - `inspectable` — answerable from the repository (state the command/file that
     provides it).
   - `human/product` — requires a human decision.
   - `deployment/env` — requires a deployed environment, secrets, or external
     service evidence.
4. **Evidence log** — commands and file references used to answer inspectable
   questions. Update this as the session proceeds.
5. **Decision matrix** — for each human/product question, the viable options,
   recommendation, trade-offs, and the final answer once recorded.
6. **Follow-up Code plan split map** — a concrete list of `Tasks/Code/`
   sessions to create after the answers are in, including namespace, title,
   dependencies, and the unknown each plan resolves.
7. **Acceptance** — "this Intake is done when all questions are answered and the
   downstream Code plans exist."

## From Intake to Code plans

### Feature-planning gate (default)

When the Intake is a feature or configuration request — i.e., the work
introduces, changes, or expands product behavior — run `opencode/feature-planning`
by default **before** creating `Tasks/Code/` plans.

1. Read `Skills/Intake/feature-planning.md` and the canonical ZCode skill
   at `C:\Repos\.agents\skills\feature-planning\SKILL.md`.
2. Feed the Intake evidence, decision matrix, and follow-up split map into the
   feature-planning workflow.
3. Use Discover → Interview → Prioritize → Print to produce a prioritized set of
   `Tasks/Code/` session plans.
4. Record the feature-planning output (prioritized wave list, key configuration
   decisions, and scope boundaries) in the Intake file.
5. Do not move the Intake to a Code planning phase until the feature-planning
   output is recorded or the downstream `Tasks/Code/` plans are created.

If the Intake is **not** a feature or configuration request (e.g., a pure
bug-fix, refactor, ops task, security patch, or documentation change),
feature-planning is optional. The Intake agent may still run it if the user
explicitly asks or the remaining ambiguity justifies it.

### Sizing rules

When splitting the Intake into `Tasks/Code/` sessions:

- One coherent concern per plan.
- A plan should touch no more than 8–12 files or one cross-file service concern.
- If a plan needs more than one `Repair pass` or a token budget > 100K, split it.
- Plans that modify the same file must use `DependsOn` and be serial; independent
  namespaces may run in parallel.
- Each resulting Code plan must include the relevant Intake answer in its
  `References` section.

## Closing the loop

After the downstream Code plans are written:

1. Append a `## Code Plans Created` section to the Intake file.
2. Link each new `Tasks/Code/` plan from the Intake.
3. Run `Build-SkillsIndex.ps1` if the Intake introduced or renamed any skills.
4. Do not move the Intake to `Tasks/Complete/` until the work it describes is
   fully implemented and merged; Intake files are reference artifacts.

## References

- `Skills/Workflows/Shared/session-plan-format.md` — canonical plan format.
- `Skills/Intake/feature-planning.md` — default feature-planning step
  for feature/configuration intakes.
- `Skills/Planner/SKILL.md` — planning workflow.
