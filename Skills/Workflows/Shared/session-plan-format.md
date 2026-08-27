# Session Plan Format

Canonical template and format spec for writing session plans. Every plan written by the Planner must follow this format. **The format spec is for the Coder/Reviewer pipelines** — they import this file to verify the plan shape. Role-overview content (who the Planner is, how the role behaves) lives at `Skills/Planner/SKILL.md`. The Planner's full workflow (Discover → Write → Complete) lives at `Skills/Create/Skill-Authoring/workflow-primitives.md § Planner Workflow`.

> **Save location**: **Interactive** plans (ZCode/Cowork/ExitPlanMode — human in the loop, awaiting approval) are written to `~/.salmon/Tasks/Handoff/` by default (see `Write-SessionPlan.ps1`, whose default `OutputDir` is now `~/.salmon/Tasks/Handoff`). **Autonomous** plans (Audit mode, Planner persona — ready to dispatch with no human present) are written to `~/.salmon/Tasks/Code/`. See `AGENTS.md § Plan output location` for the standing rule and why the location (not the `Status` field) is the dispatch gate.

## Complexity Self-Check

Before invoking grill-me or writing a plan, score the task against the 8 complexity signals below. ≥2 firing signals (or 1 strong signal) means full Planner engagement is justified. Otherwise, direct Coder dispatch is appropriate.

1. **Multi-component scope** — task touches 3+ files, modules, or services
2. **Cross-cutting concerns** — changes span multiple architectural layers (API, database, UI, infra)
3. **Architectural decisions** — task requires choosing between fundamentally different approaches
4. **Unfamiliar territory** — working in a codebase or domain with no prior context
5. **Integration risk** — changes affect external APIs, shared state, or other teams' code
6. **Security surface** — task involves auth, permissions, user input handling, or secrets
7. **Ambiguous requirements** — the request leaves significant design decisions unspecified
8. **Greenfield work** — building a new system, service, or major feature from scratch

**Strong signal override**: Greenfield work and major architectural decisions trigger the full pipeline even when alone. Do not skip the Planner on these.

> **Related ADRs**: Signal 3 (architectural decisions) usually means a new ADR is warranted. Before writing a plan, check the [ADR index](../../../docs/Reference/Decisions/README.md) to see if a related decision already exists — if so, the new plan may be a *change* to an existing ADR (mark as `Superseded` and write a new one) rather than a greenfield decision.

**Skip conditions** — Full Planner is NOT needed when:
- Simple bug fixes with clear root cause
- Single-file changes with obvious implementation
- Documentation-only updates (markdown / prose, not code)
- Configuration changes (yaml / json / env-var tweaks)
- Tasks the user has explicitly said to "just do"

## Template

```markdown
# Session Plan: <date> <namespace> <iteration> <description> - <one-line scope>

**Status**: ready
<!-- For interactive/proposal plans, use `**Status**: proposal` and flip to `ready` on approval. See AGENTS.md § Plan output location. -->
**Date**: <date>
**DependsOn**: <Namespace-Iteration> (status: reviewed|complete|ready)
             <Namespace-Iteration> (status: complete)
**Repair passes**: <N>
**Repair depth**: <one-line summary of what each pass covers>
**Scope**: <1-sentence description>
**Connascence**: <filename>.md (files: <shared-file-paths>, loc: <Tasks|Review|Working>, status: <locked|released>), ... or "None"
**ConnascenceScope**: <comma-separated file paths this plan touches for precise conflict detection> (REQUIRED for plans touching >1 file; for single-file plans, set to same as Files)
**Token budget**: estimated <N> tokens (cap 250K)
**Challenge**: Flash | Daily | Complex | Frontier (optional; defaults to Flash)
**Overrides**: default | Harness=<harness>, Provider=<provider>, Model=<provider-specific-model>, Effort=<provider-specific-effort>, Challenge=<tier>
**Overrides confirmation**: not required | confirmed by user
**Validation Rubric**:
1. [ ] <first check>
2. [ ] <second check>
3. [ ] Estimated token budget (<N>) < 250,000
**Test baseline**: <N> passed, <N> failed
**Files**: <comma-separated list of files to modify> (MUST be a single comma-separated line; see § Files field rule)

**Usage**: appended at completion by `Add-PlanUsageMetadata.ps1`; stable fields are `Provider`, `Harness`, `Model`, `Effort`, `SessionId`, `Requests`, `Tokens`, `CostUSD`, and `Source`.

---

## Overview
<2-4 sentence summary of what this session accomplishes>

---

## Task 1: <task title>

**Why**: <reason this task is needed>
**Files**: `<path>` (<new or existing>)

**Changes**:
- <bullet list of specific changes>

**Acceptance**: <testable condition>
**Verification**: <command or test that confirms this task succeeded>

## Requirements (RFC 2119) [optional — see rubric]
<!-- Include this section when the plan triggers the "RFC 2119 required" rubric below. For documentation-only plans, write "N/A — documentation-only plan" and move on. -->
- The system MUST <testable requirement>.
- The system SHOULD <testable requirement>.
- The system MAY <testable requirement>.
```

## DependsOn Field

### Namespace Model — Parallel Tracks vs Serial Dependencies

Each plan is assigned a **namespace** (the segment between the date prefix and the iteration number in the filename). The canonical extraction is the `Get-FileNamespace` function in `Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1` — always use it rather than parsing by hand, so connascence grouping and the `~/.salmon/Tasks/Complete/<namespace>/` routing agree. The orchestrator treats every namespace as an **independent parallel track**:

- `audit1sec-*`, `audit5skills-*`, and `audit6adr-*` are three different namespaces → Coders can pull each namespace's plans **fully independently** with zero conflict.
- Within a single namespace (e.g., `audit1sec-1`, `audit1sec-2`, `audit1sec-3`), plans are **sequential by default** — iteration 2 waits for iteration 1 to complete.

**Key rule**: If tasks are independent and don't share target files, put them in **different namespaces** to unlock parallel dispatch. If they must run one-after-another within the same concern, keep them in the **same namespace**.

### Cross-Namespace Dependency (DependsOn)

When parallel tracks (`audit5skills-*`, `audit6adr-*`) each depend on a shared serial track (`audit1sec-*`), use `**DependsOn**:` to express that ordering:

```markdown
**DependsOn**: audit1sec-1 (status: complete)
             audit1sec-2 (status: complete)
```

This means: "audit5skills-1 can run in parallel with audit5skills-2 and audit6adr-1 — but ALL of them must wait for audit1sec-1 and audit1sec-2 to finish first."

The orchestrator sees: `audit5skills-*` and `audit6adr-*` are different namespaces (parallel-safe), but all are **blocked on** `audit1sec-*` until those iterations reach `complete` status.

### Omission Rule
If a session has no upstream dependencies, omit `**DependsOn**:` entirely. This declares it a **root session** — safe to dispatch without waiting for any other session. Every non-root session MUST list at least one DependsOn entry. A session with zero DependsOn entries present is treated as root.

### Status Gates
Each dependency reference specifies a required completion status:

| Gate | Meaning |
|------|---------|
| `complete` | The dependency's changes are committed to the repo (`git log` on HEAD). The Coder may proceed. |
| `reviewed` | The dependency is committed AND its session file is in `~/.salmon/Tasks/Complete/` (passed review). The Coder must wait for this. |
| `ready` | The dependency plan exists in `~/.salmon/Tasks/Code/` with `Status: ready` but has not yet been started. The Coder must wait until the dependency is implemented. |

If no status is specified, the default is `reviewed` (conservative).

### Validation Rules
1. Every DependsOn reference must match a plan filename in `~/.salmon/Tasks/Code/`, `~/.salmon/Tasks/Working/`, `~/.salmon/Tasks/Review/`, or `~/.salmon/Tasks/Complete/` with the format `<date>-<namespace>-<iteration>-<description>.md`.
2. No dependency cycles (A→B→A) — checked by tooling at orchestration time.
3. No self-references — a session cannot depend on itself.
4. DependsOn references within the same namespace are redundant (same namespace already implies sequential ordering by iteration number). Cross-namespace DependsOn references are the meaningful use case — they let one parallel track wait on another.

See `Connascence` for file-level conflict rules.

## Namespace as Parallel Track

When the Planner or Auditor generates multiple session plans in a single pass, each namespace is an **independent parallel track**. Coders pull from each namespace independently — `audit1-*`, `audit2-*`, and `audit3-*` can all be worked on simultaneously without conflict.

### How namespaces interact

| Situation | Rule |
|-----------|------|
| Two plans in the **same namespace** | Sequential — the second waits for the first to be released (alpha sort by iteration) |
| Two plans in **different namespaces** that modify **different files** | Parallel — no conflict, no DependsOn needed |
| Two plans in **different namespaces** that **both MODIFY** the same file | The later namespace's plan must list a `DependsOn` on the earlier namespace's plan |
| One plan **MODIFIES** a file, another plan in a different namespace **REFERENCES** it (reads it as context/evidence but does not list it in `**Files:**`) | Parallel — not a conflict. The referencing plan does not change the file. |

### The MODIFIES vs REFERENCES distinction

The `**Files:**` field is the single source of truth for what a plan changes. A file appears in `**Files:**` only if the plan will create, edit, or delete it. If a plan's task body mentions a file as evidence, context, or a cross-reference — but does not list it in `**Files:**` — that is a **reference**, not a modification. References do not create connascence.

**Example**: An ADR drift plan might say "ADR-0014 references `port-registry.json` which has stale entries." If the plan's task is to update the ADR file (not the registry), then `**Files:**` lists only the ADR file. The `port-registry.json` is referenced, not modified. Another namespace that modifies `port-registry.json` can run in parallel without conflict.

### Resolving real cross-namespace conflicts

When two namespaces both MODIFY the same file (both list it in `**Files:**`), resolve with `DependsOn`:

```markdown
**DependsOn**: audit4manifest-1 (status: complete)
```

This blocks the current plan until `audit4manifest-1` has committed its changes to the shared file. The current plan then works on the file with the upstream changes already in place.

**Do NOT merge namespaces to resolve conflicts.** Merging destroys parallelism. Use `DependsOn` to express the dependency while keeping the namespaces independent for all other plans in the track.

## References

Every plan MUST include a References section populated with all relevant context. The Planner gathers these during the Phase 2 research pass. This section is the single source of truth for the Coder's prerequisite reading and the Reviewer's cross-reference audit.

```markdown
## References

### ADRs
- [ADR-XXXX: Title](../../../docs/Reference/Decisions/ADR-XXXX) — relevant because <reason>

### See also
- `<namespace-iteration-description.md>` — prior/sibling plan this builds on or relates to

### Documentation
- `docs/Reference/<topic>.md` — <what it provides>

### Key codebase files
- `<path/to/file>` — <what it defines or why the Coder should read it>

### Other resources
- <links, notes, considerations>
```

**Rules**:
- Every ADR relevant to the plan's scope MUST be listed — the Coder should not discover a governing ADR mid-implementation.
- Prior plans in `~/.salmon/Tasks/Complete/` that touched the same files or namespace should be cross-referenced as "See also" entries.
- If no external references are needed, write `None — self-contained plan` rather than omitting the section.
- The section serves both the Coder (pre-execution context) and the Reviewer (cross-reference integrity check).

## Resolved Decisions

For plans that ran the Pre-code Questionnaire (Complexity Self-Check ≥2), include the Resolved Decisions table. For stub-mode or trivial plans, write `None — stub-mode skip`.

```markdown
## Resolved Decisions

| # | Question | Answer | Mapped Requirements |
|---|----------|--------|-------------------|
| 1 | Should we use X or Y? | X — lower latency | SHOULD use X |
| 2 | ... | ... | ... |
```

## Deferred Decisions

For questions that could not be resolved during the questionnaire:

```markdown
## Deferred Decisions
- <question>: <why deferred> → Manual task at `~/.salmon/Tasks/Manual/<date>-<topic>.md`
```

## When to use the Requirements section

- **Required when** the plan satisfies BOTH of: (a) the Complexity Self-Check (above) flags ≥2 signals, AND (b) the plan modifies 2+ files across different architectural layers (e.g., one script and one config; one module and one test; one source file and one documentation file that references its API).
- **Recommended when** the plan modifies any of: auth code, security-sensitive code, public APIs, or shared modules used by other code paths.
- **Skip when** all modified files are documentation-only (`.md`, `.txt`, non-code).
- **Skip when** the plan is a single-task fix with obvious scope (e.g., rename a function, fix a typo). The Complexity Self-Check 0–1 signal path.

## Stub-Mode Plan Shape

Stub mode is a leaner alternative to the standard multi-task plan shape, for trivial work where the full ceremony is overhead. Stubs are intentionally under-specified; the Coder re-grooms each task immediately before execution.

**Shape**: Single plan-phase, 3–6 coarse tasks, each task body is a markdown bullet checklist of 2–5 file-level steps. No sub-phases, no implementation specifics, no pre-groomed detail.

**Auto-detect heuristic** (3 conditions, all required):
1. The plan introduces no new external dependencies or services (e.g., no new npm packages, no new Docker images, no new AWS resources)
2. All work is topologically serial — no parallel-independent streams
3. No `risk:high` markers and no architectural unknowns surfaced by the Planner's grilling

**Planner override**: Add `**Stub-Mode**: true` to the plan header to force stub mode regardless of the heuristic. Add `**Stub-Mode**: false` to force standard mode (e.g., when the plan's topic *sounds* trivial but the Planner suspects hidden complexity).

**Coder expectation**: In stub mode, the Coder treats the bullet checklist as a *starting point*, not a contract. The Coder re-explores the codebase per the re-groom rule in `Skills/Create/Skill-Authoring/workflow-primitives.md` § Coder re-groom rule, and adapts the bullets to match what the codebase actually looks like.

**Example** — a single stub task's body shape:
```
## Task 1: Add retry helper to SalmonRun.Core
- Create `Modules/SalmonRun.Core/Public/Retry.ps1` with the function signature
- Add Pester tests in `Orchestrator/Tests/SalmonRun.Core.Tests.ps1`
- Update `SalmonRun.Core.psd1` FunctionsToExport list
```

## Field Reference

| Field | Purpose |
|-------|---------|
| `Status` | `draft` | `proposal` | `ready` | `locked` | `review` | `complete`. `ready` = approved for autonomous dispatch. `proposal` = written but not yet approved. **Caveat (2026-07-28): the orchestrator's auto-dispatch does NOT currently filter on `Status` — a `proposal` plan placed in `~/.salmon/Tasks/Code/` will be picked up and executed regardless.** The reliable gate is **location**: write interactive/`proposal` plans to `~/.salmon/Tasks/Handoff/` (off the dispatch path); move to `~/.salmon/Tasks/Code/` and flip to `ready` only when approved. See `AGENTS.md § Plan output location`. |
| `Repair passes` | 1 for simple tasks, 2+ for staged depth. Pass 1 handles obvious fix, pass 2 handles deeper refinement from validation feedback. |
| `DependsOn` | Cross-namespace dependencies with status gates. Format: `Namespace-Iteration (status: reviewed|complete|ready)`. One per line. Omit for root sessions. See the [Project Glossary](../../../docs/Reference/glossary.md) for definitions of DependsOn, connascence, and related terms. |
| `Depends on` | **Deprecated** in favor of `DependsOn`. Retained for backward compat — tooling reads `DependsOn` first, falls back to `Depends on` free-text if missing. |
| `Connascence` | Lists every connascent plan file outside `~/.salmon/Tasks/Complete/` that shares files with this plan. **Machine-parseable format** — do NOT write prose descriptions of the namespace's role (that belongs in `## Overview`). Format: `<filename>.md (files: <shared-file-paths>, loc: <Tasks|Review|Working>, status: <locked|released>)`. If no connascent files exist, write `None`. See the [Project Glossary](../../../docs/Reference/glossary.md) for the definition of connascence. |
| `ConnascenceScope` | **Required** for any plan touching >1 file. Comma-separated file paths (same format as `Files:`). This is the field `Get-ConnascenceGroups.ps1` uses for precise conflict detection. When absent, the extractor falls back to namespace-only grouping, which may miss file-level conflicts. For plans touching 1 file, set `ConnascenceScope` to the same path as `Files:`. See the [Project Glossary](../../../docs/Reference/glossary.md) for the definition of connascence and related terms. |
| `Token budget` | Estimated token cost (plan + read + reasoning + output). Must be < 250,000 (the Flash Max exit-context target). See `Skills/Planner/workflow.md` § Token Estimation Heuristic for how to estimate. If the estimate exceeds 200K, split the plan. |
| `Overrides` | Optional, machine-readable plan override. Use `Harness=<value>, Provider=<value>, Model=<value>, Effort=<value>`; use `default` to inherit the orchestrator run defaults. Any specified value supersedes that run default. Plans co-dispatched in one namespace must resolve to the same Overrides. Values must exist in `Orchestrator/Modules/SalmonRun.Orchestrate/Config/harness-defaults.json`. |
| `Overrides confirmation` | Required when `Overrides` is not `default`. An interactive Planner must ask the user to confirm the exact resolved harness, provider, model, and effort, then write `confirmed by user`. The scheduler rejects unconfirmed Overrides; this prevents a plan from silently spending a different model profile than the user approved. Use `not required` when `Overrides` is `default`. |
| `Validation Rubric` | 2-4 named checks the Coder must verify and Reviewer must audit against. Each independently pass/fail. Must include the token budget check. |
| `Test baseline` | Number of passing/failing tests before changes. |
| `Nurture` | Boolean (default `false`). When `true`, the Coder runs a quality pass after tests (check TODOs, test coverage, doc drift). |
| `Secure` | Boolean (default `false`). When `true`, the Coder runs a security pass after tests (secrets scan, injection vectors, hardcoded credentials). |
| `Lean` | Boolean (default `false`). When `true`, the Coder compresses status output, lazy-loads references, skips DEBUG logging. |
| `Verification` | How the agent confirms the task completed correctly. Must be an executable check (test command, API call, diff comparison). Narrative-only checks are prohibited. |
| `Files` | **Mandatory** — must list every file the task **modifies** (create, edit, delete). Do NOT list files that are only read, referenced, or cited as evidence — those are context, not targets. **Format**: MUST be a single comma-separated line: `**Files**: path/to/file1.ext, path/to/file2.ext`. Do NOT use a bulleted list — `Get-ConnascenceGroups.ps1`'s `Get-FilesField` regex only matches a single line. If you need annotations (new/extend), put them in the task body's `**Files**:` sub-section, not in the header. VERI uses this field for independence analysis and parallel dispatch. A file listed here in two different namespaces creates a cross-namespace conflict that must be resolved with `DependsOn`. A file listed here in one namespace but only mentioned in another namespace's task body (not in its `Files` field) is NOT a conflict — the second namespace is merely referencing it. |

> **Note on Post-Implementation Audit**: The `## Post-Implementation Audit` section template is no longer in this file. It lives at `Skills/Create/Skill-Authoring/workflow-primitives.md § Post-Implementation Audit Hook` (the canonical, consolidated version). See that section for the format and the three Planner questions to answer in the plan.

## Changelog
- 2026-06-20: Added "Namespace as Parallel Track" section. Sharpened `Files` field definition to emphasize MODIFIES-only (not REFERENCES). Added MODIFIES vs REFERENCES distinction and cross-namespace conflict resolution via DependsOn.
- 2026-07-14: Tightened format spec per plan-role-01. Files: MUST be comma-separated (single line). ConnascenceScope: REQUIRED for multi-file plans. Connascence: machine-parseable format (no prose). Token budget: cap lowered from 400K to 250K. DependsOn: added `ready` status gate.
- 2026-07-27 — Added `proposal` Status value for interactive/ExitPlanMode plans; documented save location.
- 2026-07-28 — **Interactive plans now route to `~/.salmon/Tasks/Handoff/`, not `~/.salmon/Tasks/Code/`.** The `proposal`-status "auto-dispatch skips it" claim did not hold in practice (orchestrator dispatches regardless of `Status`); location is now the gate. `Write-SessionPlan.ps1` default `OutputDir` changed from `~/.salmon/Tasks/Code` to `~/.salmon/Tasks/Handoff`. Corrected the `Status` field caveat and Save location note.
