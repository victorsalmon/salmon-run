# Skill: Output Compression

**Type**: skill-entrypoint
**Container**: opencode
**Domain**: ops

Hybrid output compression skill for opencode agents. Compresses by section type, not by post-processing. No global toggle — always-on per section profile. Override per-response with `+full` or `+one-liner`.

---

## Section Map

Every response is split into named sections at generation time. The agent tags each section and applies its compression profile.

| Section | Compression | Fidelity | Notes |
|---------|------------|----------|-------|
| **Background / context** | Always compressed | Confidence-tagged | Max 2 sentences. Stripped filler. |
| **Explanation / rationale** | Hierarchical | Confidence-tagged | Default 1-line summary. User expands via `?` or `+detail`. |
| **Code / config / commands** | Uncompressed (verbatim) | Full | Code blocks, diffs, CLI — never touched. |
| **Decisions / action items** | Uncompressed | Citation-based (Bookkeeper) / Confidence-tagged (default) | "Use X because Y." Citations link to source. |
| **Delta** | Diff-only | Full | Suppressed unless topic repeated. Then `Δ:` + only new/changed info. No background. |

---

## Compression Profiles

### Background / context — always compressed
- Strip articles, filler, pleasantries, hedging
- Max 2 sentences, fragments OK
- Confidence tag per claim: `[95%]`, `[60%]`, `[flagged: estimate]`
- Low-confidence info included but flagged

### Explanation / rationale — hierarchical
- Default: 1-line summary
- User expands via `?` or `+detail`
- When expanded, full reasoned explanation with confidence-tagged claims

### Code / config / commands — verbatim
- Code blocks, diffs, CLI commands, config values: never compressed or modified
- Surrounding narrative still compressed per section rules

### Decisions / action items — uncompressed
- Default: confidence-tagged
- Bookkeeping Domain: citation-based (`[src: Zoho TB line 42]`, `[src: rent-register.csv:2026-03]`)
- Citations activate when `SalmonRun.Bookkeeping` module loaded or `Skills/Bookkeeping/` path in context

---

## Delta Detection

- Before generating, check whether the topic was addressed in the prior turn (same session)
- If yes: drop background section, start with `Δ:`, emit only new/changed info
- If nothing changed: emit `Δ: No new information`

### Topic shift handling
- Agent detects when the conversation topic has shifted mid-stream
- Prompts user: *"Prev topic still open — save stub, fork, or revisit now?"*
  - **Save stub** → write `Tasks/Handoff/<date>-<topic>-stub.md`
  - **Fork** → open new terminal with `opencode --continue --fork`
  - **Revisit** → continue in session

---

## Activation

Always-on per section map. No global toggle. Override per-response:
- `+full` — uncompress all sections
- `+one-liner` — compress everything to single line

---

## Differentiation from Caveman

| Axis | Caveman | This skill |
|------|---------|------------|
| Compression strategy | Word-category stripping | Section-type aware (per-section profiles) |
| Activation | Explicit command + sticky | Always-on per section map |
| Fidelity | "All technical substance stay" (trust-based) | Confidence-tagged (default) + Citation-based (Bookkeeper) |
| Domain focus | General-purpose | Ops/development focus with domain-specific citation tier |

---

## Compliance

All technical substance retained. Errors quoted exact. Code blocks unchanged. Citations accurate to source.
