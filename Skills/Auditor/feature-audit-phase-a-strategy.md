# Skill: Feature Audit — Phase A (Strategic Roadmap Review)

**Part of**: Feature Audit (`Skills/Auditor/feature-audit.md`) <!-- doc-lint: exempt -->
<!-- master file created by faud-1 (same wave) — forward reference -->
**Trigger**: User says "Feature Audit" / `/audit feature --strategy` (or the strategy half of a full `/audit feature` run)
**Purpose**: An interactive, human-in-the-loop strategic review of a product repo's roadmap direction, competitor positioning, and commercial viability. Phase A judges *whether the roadmap is commercially sound for its niche* — not whether the code works (that is Phase B / the other tracks). It produces an enriched plan-stub handoff the user can feed into normal feature-planning or into Phase B.

> **Relationship to `feature-planning`**: Phase A reuses the *notion* of the `feature-planning` skill — the Discover → Interview → Prioritize → Print shape (`C:\Repos\.agents\skills\feature-planning\SKILL.md` §0–§4) — run at **roadmap resolution**. It does **not** invoke the detailed `feature-planning` skill; it adds competitor/market research and commercial-viability judgment that feature-planning does not perform. The shared shape is the interview-and-prioritize discipline, not a delegation.

---

## 1. Mode Declaration (interactive)

Phase A is **interactive** — it pauses for user input throughout and produces a `Status: proposal` handoff in `C:\Repos\salmon-orchestrator\Tasks\Handoff\`, which is **off the orchestrator's dispatch path** (nothing in `Tasks/Handoff/` is picked up by Coder lanes). This is deliberate and mirrors the cross-repo rule that Audit and Plan are the question-heavy phases.

Contrast with **Phase B** (`feature-audit-phase-b-deepdive.md`): headless, read-only, produces dispatchable `Tasks/Code/` session plans. Phase A is the "interactive, question-heavy" half; Phase B is the "autonomous" half.

Per `Skills/Workflows/Shared/session-plan-format.md`: interactive sessions output to `Tasks/Handoff/`; autonomous sessions output to `Tasks/Code/`. Phase A follows the interactive rule.

The Auditor **must not** continue past a question point without the user's answer. If the user is unavailable, stop and record the partial state in the handoff as `Status: proposal` with a `## Pending Questions` section rather than guessing.

---

## 2. Inputs / Scoping

Load the **target repo's** context files (the target repo is given by `--repo <name>` per the master `feature-audit.md`; if omitted, prompt the user to choose from product repos under `C:\Repos\`):

- `roadmap.md` and `implementation.md` — the strategic + build-state layers.
- `README.md` and `AGENTS.md` — stated purpose, conventions.
- `Tasks/ToDo/todo.md`, `to-do-roadmap.md`, `to-do-horizon.md` — the sprint/milestone/horizon backlog. <!-- doc-lint: exempt -->
<!-- target-repo paths — they live in the target repo, not in salmon-orchestrator -->
- Architecture docs (`docs/Reference/ARCHITECTURE.md` or equivalent), the ADR index.
- The feature/help surface: routes, endpoints, UI pages, CLI commands, and the docs feature list.

**Cross-repo path convention**: paths inside the handoff are relative to the **target repo**; the handoff file itself lives in the central `C:\Repos\salmon-orchestrator\Tasks\Handoff\` queue (per the cross-repo task-file-location rule — task files live in `salmon-orchestrator/Tasks/` only).

Scope check before starting: confirm with the user which repo is the target and that Phase A is a strategic review (no code changes).

---

## 3. Discover — Roadmap Currency & Direction *(strategic angle 1)*

Adapt `feature-planning` SKILL.md §0 (lines 38-63) into a **roadmap-currency check** for the target repo:

1. Read the roadmap layers (`roadmap.md`, `implementation.md`, `Tasks/ToDo/` horizon files).
2. Check whether every roadmap phase has corresponding `Tasks/Code/` or `Tasks/Complete/` work in the target repo. Flag any phase that is:
   - **Unplanned** — promised on the roadmap but no plan or completed work exists.
   - **Stale** — built but deprecated / superseded, still listed as current.
   - **Blocked** — in flight but stuck (no recent activity, pending dependencies).
3. Assess **directional coherence**: do the stated themes/phases hang together as a product? Are there gaps (promised-but-unbuilt) or stale phases (built-but-deprecated)?
4. **Surface findings to the user before interviewing** — this frames the rest of Phase A. Present the currency check as a short list: current / unplanned / stale / blocked phases, plus your first-pass read on coherence.

This step answers: *is the roadmap a live, honest representation of the product's direction?*

---

## 4. Competitor Feature Matrix *(strategic angle 2)*

This is the procedure that makes "what will be commercially successful" concrete — the roadmap cannot be judged in a vacuum.

1. **Confirm the competitor list with the user first** (in the Interview step) — never score features against a guessed competitor set.
2. Research the 3-6 confirmed competitors using **WebSearch** and **WebFetch** (the session's read-only web tools). For each competitor, gather their public feature list, pricing page, and positioning.
3. Produce an explicit **competitor × feature grid** with a "gap" column:

   | Feature | `<Competitor1>` | `<Competitor2>` | ... | `<OurProduct>` | Gap (Y/N) | Notes |
   |---------|-----------------|-----------------|-----|----------------|-----------|-------|

   Cells use: `✓` (has it) / `✗` (lacks it) / `~` (partial) / `?` (unknown).

4. The **"Gap" column** flags:
   - **Competitive gap** — features competitors have that the product lacks.
   - **Defensive gap** — features the product has that are differentiators (competitors lack them).
5. Capture the grid as a markdown table in the handoff — it is the referenceable artifact that justifies later prioritization. Do not edit it during Prioritize; add new rows there if the interview surfaces more features.

---

## 5. Pricing & Paywall Alignment *(strategic angle 3)*

1. Identify which features are **premium/differentiating** vs **commodity** (using the competitor matrix as evidence).
2. Check whether premium features sit behind the right pricing tier, and whether the packaging is defensible against the matrix — e.g. a competitor offers a key feature free that this product gates behind a paid tier, or vice versa.
3. Where the product has **no pricing model yet**, flag that as a finding: "commercially successful" cannot be assessed without one. Note it in the handoff's `## Pricing & Paywall Assessment` and raise it in the Interview (pricing-model question).

---

## 6. Onboarding & Time-to-Value *(strategic angle 4)*

1. Trace the **first-run / empty-state / activation path** for the product's core loop (sign-up → first real value).
2. Flag features with the worst **activation friction**. Enterprise products win or lose on time-to-first-value.
3. Where the product is **multi-tenant**, check tenant provisioning/onboarding separately from end-user onboarding (tenant-level activation is often a hidden bottleneck).

---

## 7. Build-vs-Buy Assessment *(strategic angle 5)*

For each proposed or gap feature, flag whether an **off-the-shelf integration** would beat building it in-house:

- Examples: Stripe (payments), a bookkeeping API (ledger sync), an auth provider (SSO), a hosted search service (full-text), etc.
- Trade axes: **cost, time-to-ship, maintenance burden**.
- Goal: avoid sunk-cost on commodity features that a vendor already does better. Cite the specific vendor where relevant.

---

## 8. Interview

The interactive, question-heavy step (consistent with the cross-repo rule: *Audit and Plan are the question-heavy phases*). Run as a dialogue, not a form — ask one question at a time, record answers into `## Resolved Decisions` in the handoff.

**Standard question bank**:

- **Niche & buyer**: Who is the ideal customer? What job are they hiring this product to do? What's the willingness to pay?
- **Competitors**: Who are the real competitors (confirm the matrix shortlist)? Are there adjacent/substitute products that aren't direct competitors but solve the same job?
- **Pricing model**: Per-seat? Tiered? Usage? Freemium? What's the thesis behind the current or intended model?
- **Enterprise-grade bar**: For *this* product, what does "done" / "enterprise-grade" mean? (RBAC? audit logging? SSO? SLAs? on-prem?) — this directly informs Phase B dimension 3.
- **Prioritization signals**: What's burning? What's the next milestone? What would move the needle most for the business right now?

Capture answers in a `## Resolved Decisions` table in the handoff:

| # | Question | Answer | Implication |
|---|----------|--------|-------------|

---

## 9. Prioritize

Adapt `feature-planning` §3 (default priority stack) to the **strategic level**:

1. Rank the recommended phases by **(commercial impact × gap severity × effort)**, informed by the competitor matrix (§4) and build-vs-buy assessment (§7).
2. Produce a **recommended coarse phase list** — phase name + one-line goal each. This is the roadmap-resolution output, mirroring `feature-planning` §0 Mode A's "confirm the coarse phase list with the user first": present the list, get user sign-off, then write it into the handoff.

Default priority stack (adapted from feature-planning §3):

1. Foundation (dev env, auth, data model).
2. Core user loop (onboarding, categorization, upload, reconciliation).
3. Revenue/integrations (billing, exports, API).
4. Polish & operations (brand, admin, support, runbooks).

Strategic additions to consider: closing a **competitive gap** can outrank a polish item; a **build-vs-buy flag** can move a feature down (buy it, don't build it).

---

## 10. Print / Output — the enriched plan-stub handoff

**Location** (naming convention — do not improvise):

```
C:\Repos\salmon-orchestrator\Tasks\Handoff\<date>-feature-audit-<repo>-strategy.md
```

e.g. `2026-08-09-feature-audit-currentsbk-strategy.md`.

**Base type**: `plan-stub` (per `Skills/Cowork/handoff.md` lines 32-54):

```markdown
# Plan Stub: <topic>

**Type**: plan-stub
**Date**: <date>
**Source**: Feature Audit Phase A
```

**`Status: proposal`** — interactive output, **NOT** auto-dispatched.

**Enriched sections appended** to the plan-stub base (each maps to a strategic angle above):

- `## Validated Direction` — the coherence assessment from angle 1 (§3).
- `## Competitor Feature Matrix` — the grid from angle 2 (§4).
- `## Gap Analysis` — what's missing, what's differentiating (derived from §4).
- `## Pricing & Paywall Assessment` — from angle 3 (§5).
- `## Onboarding & Time-to-Value` — from angle 4 (§6).
- `## Build-vs-Buy Flags` — from angle 5 (§7).
- `## Recommended Phase List` — the prioritized coarse phases (§9).
- `## Resolved Decisions` — interview answers (§8).
- `## Suggested Next Step` — either "feed into feature-planning for detailed plans" or "trigger Phase B deep dive with this handoff as focus context."

---

## 11. Red Lines

- **Phase A must NOT auto-dispatch.** Its handoff is `proposal` in `Tasks/Handoff/`; it moves to `Tasks/Code/` only when a human approves and flips `Status: ready`. No orchestrator lane, Coder, or automated process may pick it up earlier.
- **Phase A does NOT modify source code in the target repo** — strategic review only. (Phase B plans drive fixes; this phase only drives direction.)
- **Phase A does NOT invoke the detailed `feature-planning` skill** — it reuses the notion, adds the strategic angles. Delegating would lose the competitor/market research.
- **Competitor research must confirm the competitor list with the user before scoring features** — do not score against a guessed competitor set.
- **No pricing model = flagged finding**, not a skipped assessment.

---

## 12. Completion

Terminal status: `Status: Feature Audit Strategy Handoff Written`.

The handoff file in `Tasks/Handoff/` is the deliverable. Confirm before terminating:

1. The handoff exists at the naming-convention location with `Status: proposal`.
2. All five strategic angles have a section (or an explicit "not assessed — deferred" note).
3. `## Resolved Decisions` reflects the interview answers.
4. `## Suggested Next Step` is filled.
