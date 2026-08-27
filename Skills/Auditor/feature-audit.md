# Skill: Feature Audit (Master Workflow)

**Purpose**: A product-repo-scoped, strategic audit with two phases — Phase A (interactive roadmap + competitor research) and Phase B (headless feature-completeness deep dive). Unlike the orchestrator-scoped tracks (Alignment = drift, Architectural = security, Functional = ops), the Feature Audit judges commercial fit and feature completeness for a product repo under `C:\Repos\` (e.g. `currents-bookkeeping`, `upscale-havens`, `currentsbk.ca`, `clocklobster.com`). It reuses the *notion* of `feature-planning` (Discover → Interview → Prioritize → Print) at roadmap resolution but does **not** invoke the detailed `feature-planning` skill.

> **Note**: This file covers the **Feature Audit** track — product-repo-scoped and strategic. For the orchestrator-scoped tracks (Alignment = drift, Architectural = security, Functional = ops), see those files. The Feature Audit is independent of the Complete Audit meta-track (which is orchestrator-scoped).

## Trigger / Invocation

- `/audit feature` — full run: Phase A interactive, then Phase B.
- `/audit feature --deep-dive` — Phase B only (headless completeness scan).
- `/audit feature --strategy` — Phase A only (interactive handoff).
- `/audit feature --repo <name>` — **required target**. The orchestrator repo is **not** a valid target. Valid targets are product repos under `C:\Repos\` (e.g. `currents-bookkeeping`, `upscale-havens`, `currentsbk.ca`, `clocklobster.com`). If `--repo` is omitted, the Auditor prompts the user to choose.

Phase B runs **independently** of Phase A — `--deep-dive` is a valid standalone invocation. The Phase A handoff *optionally* informs Phase B's focus but is not a prerequisite.

## Scoping

1. **Target repo determination** — the `--repo` value selects the product repo under `C:\Repos\`. The orchestrator repo (`salmon-orchestrator`) is not a valid target; if `--repo` is omitted, prompt the user to choose.
2. **Repo-context files loaded** — the audit reads the target repo's `roadmap.md`, `implementation.md`, `README.md`, `AGENTS.md`, `Tasks/ToDo/`, architecture docs, and the feature/help surface (routes, endpoints, UI pages, CLI commands, docs feature list).
3. **Cross-repo path convention** — paths in the handoff/report are relative to the target repo; the audit artifacts themselves live in the central `salmon-orchestrator/Tasks/` queue — per the cross-repo task-file-location rule.

## Phase overview

| Phase | Name | Mode | Output | Procedure file |
|-------|------|------|--------|----------------|
| A | Strategic Roadmap Review | interactive | enriched plan-stub handoff in `Tasks/Handoff/` | `feature-audit-phase-a-strategy.md` (created in Waves 2/3) |
| B | Feature Completeness Deep Dive | headless, read-only | session plans in `Tasks/Code/` + report in `Tasks/Logs/Audit/feature/` | `feature-audit-phase-b-deepdive.md` (created in Waves 2/3) |

The two procedure files are created in later waves — if you land here before they exist, the phase sections below are the contract they must implement.

## Output locations

- **Phase A handoff** → `C:\Repos\salmon-orchestrator\Tasks\Handoff\<date>-feature-audit-<repo>-strategy.md` (type: `plan-stub`, `Status: proposal` — interactive, off the dispatch path).
- **Phase B session plans** → `C:\Repos\salmon-orchestrator\Tasks\Code\<date>-feature-<repo>-<iteration>-<description>.md` (`Status: ready`, dispatchable). Filename convention mirrors the other tracks' `<date>-<track>-<repo>-<iteration>-<description>.md`.
- **Phase B report** → `C:\Repos\salmon-orchestrator\Tasks\Logs\Audit\feature\<date>-<repo>-feature-report.md`.

## Convergence gate

Before generating any Phase B session plan, check `Tasks/Code|Working|Review|Complete/` for an equivalent plan and `git log --oneline -1 -- <file>` for prior resolution; if found, skip plan generation and log `finding-resolved-by-prior-work`. (Canonical formulation: `alignment-audit.md:65`.)

## Red lines

- **Phase B never modifies source code** — read-only; Auditor surveys, Coder fixes.
- **Phase A is interactive and must not auto-dispatch** — its handoff is `proposal`, lives in `Tasks/Handoff/`.
- **All 9 Phase B dimensions must be checked** — skipping any invalidates the deep dive (mirroring the SKILL.md "all domains must be checked" red line).

## Completion

- Phase A → `Status: Feature Audit Strategy Handoff Written`
- Phase B → `Status: Feature Audit Deep Dive Complete`
- Full run → both.

## Deferred decisions

- **Complete Audit integration** — the Feature Audit is **not** wired into the `complete-audit.md` meta-track: Complete Audit is orchestrator-scoped and runs all three internal tracks with cross-audit `DependsOn` injection; the Feature Audit targets a product repo, so mixing it in is muddy. Do not add it silently; revisit when Complete Audit gains multi-repo support.
- **Phase B dimension split files** — Phase B's 9 dimensions stay inline in `feature-audit-phase-b-deepdive.md` for v1; per-dimension split files are deferred until a dimension grows large (the way Alignment eventually split its domains).
- **No new handoff type** — Phase A reuses the existing `plan-stub` handoff type (see `Skills/Cowork/handoff.md`); no new type is invented.
