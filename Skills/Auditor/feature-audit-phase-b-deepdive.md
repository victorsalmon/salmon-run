# Skill: Feature Audit — Phase B (Feature Completeness Deep Dive)

**Part of**: Feature Audit (`Skills/Auditor/feature-audit.md`) <!-- doc-lint: exempt -->
<!-- master file created by faud-1 (same wave) — forward reference; link lands when faud-1 completes -->
**Sibling**: Phase A (`feature-audit-phase-a-strategy.md`) — interactive strategic review; Phase B runs independently of it
**Trigger**: User says "Feature Audit" / `/audit feature --deep-dive` (or the deep-dive half of a full `/audit feature` run)
**Purpose**: A headless, read-only deep dive into a product repo's feature completeness and fullness — whether the features actually work, whether the functions backing them make sense, whether the feature set fits the product's niche and enterprise-grade bar, and whether new features have created drift or regressions by superseding old ones. It produces dispatchable session plans (the Coder's queue) and an evidence report.

> **Relationship to Phase A**: Phase B is **independent** — the `--deep-dive` path runs Phase B alone with no Phase A prerequisite. When Phase A has run, its handoff *optionally* narrows Phase B's focus (e.g. "these are the priority features — look there first"), but Phase B never blocks on it. The enterprise-grade bar (Dimension 3) comes from Phase A's interview when available; otherwise Phase B applies a reasonable default and flags assumptions.

---

## 1. Mode Declaration (headless, read-only)

Phase B is **headless** and **read-only**, mirroring the three existing tracks (Alignment, Architectural, Functional). The Auditor surveys; the Coder fixes. Phase B never modifies source code in the target repo.

**Output**:
- `Status: ready` session plans in `Tasks/Code/` — **dispatchable**, picked up by Coder lanes automatically.
- An evidence report in `Tasks/Logs/Audit/feature/`.

Per `Skills/Workflows/Shared/session-plan-format.md`: autonomous sessions output to `Tasks/Code/`; interactive sessions output to `Tasks/Handoff/`. Phase B follows the autonomous rule — it runs without user input and produces plans the fleet can execute.

---

## 2. Phase 0 — Feature Inventory

Before surveying dimensions, enumerate the product's feature surface so each dimension has a complete target set. The inventory is the cross-reference backbone for dimensions 6, 7, and 8 (telemetry gaps, surface parity, migration drift).

**Target repo**: given by `--repo <name>` per the master `feature-audit.md`; if omitted and Phase A ran, reuse its target; otherwise pick the product repo to deep-dive.

Produce an inventory covering:

- **Routes / endpoints** — scan the backend (router files, OpenAPI spec, server route registrations, Lambda handlers, API Gateway config) for every exposed route/endpoint.
- **UI pages / screens** — scan templates/components/views for every user-facing page or screen.
- **CLI commands** — scan command registrations (Cobra commands, Typer apps, npm bin scripts, PowerShell command defs).
- **README / docs feature list** — extract the explicitly-marketed feature list from README, docs, help text, and the landing page.
- **Roadmap items** — pull claimed features from `roadmap.md` / `implementation.md` (features claimed as shipped).

The inventory itself goes into the report's Phase 0 section (see §7). Cross-references between these sources are the raw material for dimensions 6, 7, and 8.

---

## 3. The 9 Dimensions

Each dimension is a discrete subsection with a one-line **core question** (from the user's original brief / the design interview), a **what to look for** list, and **detection heuristics** (concrete, runnable greps/reads — not vague directives). All 9 MUST be checked; skipping any invalidates the deep dive.

### Dimension 1 — Functional completeness

*Core question: Does it work?*

**What to look for**: half-built features; dead/unreachable code paths; stubs/`TODO`/`FIXME`/`not implemented` in shipped features; features claimed in docs but absent in code; endpoints that return hardcoded or empty data.

**Detection heuristics**:
- Grep for `TODO|FIXME|stub|not implemented|placeholder|coming soon` across source.
- Cross-reference the docs feature list (§2 README/docs) against the inventory — every marketed feature must have a code home.
- Trace each endpoint to a real handler (route registration → handler function → data access); flag endpoints whose handler is a stub or a hardcoded response.

### Dimension 2 — Feature↔function alignment

*Core question: Do the functions make sense for the features?*

**What to look for**: misaligned abstractions (a "feature" implemented as a scatter of unrelated functions); over-engineering (generic machinery for a single use case); under-engineering (a critical feature built as a one-off); leaky internals (DB schema or vendor quirks exposed through the feature boundary).

**Detection heuristics**:
- For each major feature, map feature → backing functions → data model and check the mapping is coherent.
- Flag features whose implementation sprawls across unrelated modules.
- Flag features whose internal naming diverges from the user-facing feature name (the code calls it `InvoiceSync`, the UI calls it "Bank Feed" — which one is the truth?).

### Dimension 3 — Enterprise-grade gaps

*Core question: Is it enterprise-grade?*

**What to look for**: missing error handling (uncaught throws, swallowed errors); missing idempotency on mutating operations; missing audit logging for sensitive actions; missing/weak multi-tenancy isolation; missing permissions/RBAC checks; missing rate limiting; missing retry/backoff on flaky external calls; missing observability (logs/metrics/traces) on critical paths.

**Detection heuristics**:
- Grep for `try`/`catch` coverage on async/external calls; flag calls outside any handler.
- Check every mutating endpoint for an authorization check before the mutation.
- Check every external call for retry/timeout configuration.
- Look for tenant-scoping in queries (multi-tenant products only): any query that can't be traced to a tenant context is a finding.

> **The "enterprise-grade bar" is product-specific.** Phase A's interview (or the target repo's own docs) should establish what "enterprise-grade" means here. If Phase A didn't run, apply a reasonable default — error handling, idempotency, RBAC, audit logging, rate limiting, retry/backoff, observability — and **flag the assumption** in the report.

### Dimension 4 — Low-hanging fruit / easy lifts

*Core question: What's a quick win for a big result?*

**What to look for**: missing DB indexes (slow queries on common filters); obvious performance issues (N+1 queries, missing pagination, unbatched loops); trivial UX gaps (missing confirmations, unclear empty states); small polish items (typo fixes, inconsistent labels).

**Detection heuristics**:
- Grep query patterns and cross-check against index definitions.
- Flag endpoints returning unbounded lists (no pagination).
- Flag UI text inconsistencies (three ways to say the same action).

Prioritize these high — they're the best ROI findings.

### Dimension 5 — Regression & supersession drift *(EMPHASIZED — most detailed heuristics)*

*Core question: Have new features created drift or regressions by superseding old ones while the old path still runs?*

**What to look for**: near-duplicate endpoints/functions (two ways to do the same thing); v1/v2 inconsistency; orphaned code (old path kept "just in case" but no longer wired); abandoned feature flags left toggled on or off; deprecated paths still receiving traffic; data written in an old format that the new path doesn't read.

**Detection heuristics**:

- **Near-duplicate detection** — grep for route/handler name variants (`v1`/`v2`, `old`/`new`, `legacy`/`current`, `_deprecated`, `bak`); cluster endpoints by path similarity to find pairs; for each pair, check whether both are still wired to real traffic.
- **Add-without-remove history** — `git log --oneline -S "<feature>" -- <dir>` to find when a feature was added; then check whether the predecessor was removed in the same or a follow-up commit. **Add-without-remove is the supersession smell** — the old path was left running when the new path shipped.
- **Marker scan** — grep for `deprecated|legacy|old|v1|TODO: remove|FIXME: remove|supersed` across source; each hit is either a real supersession to verify or a stale marker to clean.
- **Feature-flag states** — enumerate feature-flag definitions and their default/stored states; flag flags that are fully rolled out (or fully off) but still in code — they're abandoned and should be removed or flipped.
- **Stale-format data** — check migrations for incomplete backfills; grep for code paths that branch on a data-shape version (`if record.schema_version ...`) and confirm both branches are still live.

This is the dimension the user emphasized in the original brief; give it the deepest heuristics and flag its findings at **higher priority** than other dimensions' findings.

### Dimension 6 — Telemetry & usage gaps *(added)*

*Core question: Can we tell whether a feature is adopted or is dead weight?*

**What to look for**: features with no usage tracking (no event emit, no metric, no log); shipped-but-undocumented features (in the inventory but absent from docs/help).

**Detection heuristics**:
- Cross-reference the feature inventory against a grep for analytics/event/metric calls; a feature with **zero telemetry** is a finding.
- Cross-reference the inventory against docs/help text; a feature in code but not in docs is either intentional (internal) or a doc gap — flag for review.

### Dimension 7 — Feature parity across surfaces *(added)*

*Core question: Is the feature surface consistent across API / UI / mobile / desktop?*

**What to look for**: backend endpoints with no UI surface (unreachable power); UI controls with no backing endpoint (dead buttons); admin-only paths missing from the customer app (or vice versa); parity gaps between web/mobile/desktop if multiple clients exist.

**Detection heuristics**:
- Cross-reference the endpoint inventory (§2) against the UI inventory (§2); an endpoint with no caller, or a UI action with no endpoint, is a finding.
- If multiple clients exist, diff their feature surfaces row by row.

### Dimension 8 — API & data-migration drift *(added)*

*Core question: Do old and new API/data shapes agree?*

**What to look for**: v1/v2 endpoint response-shape inconsistency; incomplete data migrations leaving stale-format records (overlaps Dimension 5 but focused on data shape); abandoned feature flags (overlaps Dimension 5 but focused on the migration/flag lifecycle); breaking changes shipped without a migration path.

**Detection heuristics**:
- Diff v1/v2 response schemas for the same resource.
- Check migration directories for backfill scripts and whether they're idempotent/run-once.
- Grep for schema-version branches (`if record.schema_version ...`) and confirm both shapes are readable.

### Dimension 9 — Feature-interaction conflicts *(added)*

*Core question: Do features break or confuse when used together?*

**What to look for**: feature pairs that conflict when both are enabled (e.g. an auto-categorization rule that fights a manual override); inconsistent UX patterns across features (three different date-pickers, two different save-button conventions, inconsistent error-display styles).

**Detection heuristics**:
- For each pair of features sharing a data model or workflow, reason about whether they can both act on the same record — if yes, does one clobber the other?
- Grep for UI primitive usage to detect inconsistent component choice across features.

---

## 4. Convergence Gate

Reused verbatim from the Alignment Audit — do **not** invent a parallel mechanism. Canonical formulation: `alignment-audit.md:65`.

> **Convergence gate**: For each Critical/High finding, check whether an equivalent plan already exists in `Tasks/Code/` (pending), `Tasks/Working/` (in progress), `Tasks/Review/` (under review), or `Tasks/Complete/` (completed this cycle). Also check `git log --oneline -1 -- <affected-file>` - if a recent commit already addressed the finding, skip plan generation and log `finding-resolved-by-prior-work`.

This prevents duplicate plans for already-known/tracked issues.

---

## 5. Output — Session Plans

For each finding that survives the convergence gate, write a session plan:

```
C:\Repos\salmon-orchestrator\Tasks\Code\<date>-feature-<repo>-<iteration>-<description>.md
```

e.g. `2026-08-09-feature-currentsbk-1-fix-bank-feed-stub.md`.

- `Status: ready` (dispatchable) — this is the headless path; plans go straight to the Coder's queue.
- Follow the standard session-plan format (`Skills/Workflows/Shared/session-plan-format.md`, template `~/.salmon/Tasks/Templates/session-plan-template.md`): `Status`, `Date`, `Scope`, `Validation Rubric`, `Files`, `## Overview`, `## Task N` blocks (Why/Files/Changes/Acceptance).
- Reference the target repo by absolute path and note the cross-repo path convention (task files live in `~/.salmon/Tasks/`; paths inside the plan are relative to the target repo).
- Filename convention: `<date>-feature-<repo>-<iteration>-<description>.md` — the `feature` namespace, mirroring the other tracks' `<track>` namespace.

---

## 6. Output — Report

Write an evidence report:

```
C:\Repos\salmon-orchestrator\Tasks\Logs\Audit\feature\<date>-<repo>-feature-report.md
```

e.g. `2026-08-09-currentsbk-feature-report.md`.

Structure (mirrors the alignment report format, e.g. `Tasks/Logs/Audit/alignment/<date>-<repo>-alignment-report.md`):

1. **Header** — date, repo, git HEAD of the target repo.
2. **Phase 0 feature inventory** — the inventory from §2.
3. **Findings by Dimension** — a table:

   | Dimension | Finding | Severity | Plan (or "converged — prior work") | Evidence (file:line) |
   |-----------|---------|----------|-------------------------------------|----------------------|

4. **Summary count** — total findings, by severity, by dimension.

---

## 7. Red Lines

- **Phase B NEVER modifies source code.** Read-only — the Auditor surveys, the Coder fixes. (Mirrors all three existing tracks.)
- **All 9 dimensions MUST be checked.** Skipping any invalidates the deep dive. (Mirrors the SKILL.md "all domains must be checked" red line.)
- **The convergence gate MUST run before generating any plan** — no duplicate plans for known issues.
- **Phase B plans go to `Tasks/Code/`** (`Status: ready`, dispatchable) — **never `Tasks/Handoff/`** (that's the interactive/proposal path). Phase B is headless.

---

## 8. Completion

Terminal status: `Status: Feature Audit Deep Dive Complete`.

Confirm before terminating:

1. All 9 dimensions surveyed (each has at least a "no findings" note in the report).
2. Convergence gate applied to every finding.
3. Plans written to `Tasks/Code/` for every finding that survived the gate.
4. Report written to `Tasks/Logs/Audit/feature/<date>-<repo>-feature-report.md`.

---

## 9. Deferred Decisions

- **Per-dimension split files** — the 9 dimensions stay inline in this one file for v1. Split into separate files (the way Alignment split into `alignment-audit-domain-N-*.md`) only when a dimension grows large enough to warrant its own file. Dimension 5 (supersession drift) is the most likely first candidate for a split.
