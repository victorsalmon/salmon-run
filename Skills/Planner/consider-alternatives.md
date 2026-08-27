# Skill: Consider Alternatives

**Purpose**: Guide the Plan mode (or any agent) through a structured Socratic interrogation — forcing deep consideration of goals, assumptions, alternative approaches, and best-practice alignment *before* writing session plans. Bridges the gap between a raw user request and a well-justified implementation plan.

**Owner**: `Skills/Planner/SKILL.md` — the Plan mode owns this skill, but any agent may invoke it.

**Prerequisites**: Write access to `Tasks/` directory, read access to `docs/Reference/Decisions/`.

**Recognition**: Invoked in two modes:
1. **Explicit** — User says "help me consider alternatives", "evaluate approaches", "weigh options", "should I do X or Y?", or similar.
2. **Heuristic (auto-detect)** — Planner detects the request involves architectural changes, security-sensitive operations, significant resource investment, conflicting stakeholder needs, or a choice between known alternatives. The Planner offers: *"This looks like it would benefit from considering alternatives — shall I run the Consider Alternatives workflow?"* and proceeds only on confirmation.

---

## Workflow

### Phase 1: Goal Clarification

Before exploring alternatives, establish the true north. Ask these questions — do not proceed until the goal is mutually understood:

- What is the ultimate outcome you want to achieve?
- What problem are you solving? Is this addressing the root cause or a symptom?
- Who is the beneficiary? What does success look like for them?
- What constraints are non-negotiable (time, budget, regulatory, technical, security)?
- What is explicitly out of scope for this effort?
- How will you know when this is done? (measurable success criteria)

If the user's request is ambiguous or contradictory, flag it. Do not proceed until the scope is mutually clear.

### Phase 2: Assumption Audit

Surface hidden assumptions that may constrain thinking. Probe each category:

**Technical assumptions**
- What technologies, frameworks, or platforms are you assuming?
- What if that technology isn't available or behaves differently?
- Are you assuming existing infrastructure will remain unchanged?

**Scale assumptions**
- What volume or load are you designing for?
- What if demand is 10x higher? What if it's 10x lower?
- How does this choice scale with team size or codebase growth?

**Timeline assumptions**
- What deadlines are driving this decision?
- What if the timeline is halved? What if it doubles?
- Is there a phased delivery path?

**Dependency assumptions**
- What external systems, APIs, or services does this depend on?
- What if a dependency fails, changes its API, or is deprecated?
- What if a team or vendor doesn't deliver on time?

**Business assumptions**
- What user or customer behaviour are you counting on?
- What revenue, adoption, or retention figures are baked in?
- What regulatory or compliance assumptions are being made?

For each assumption identified, ask: *"What would we do differently if this assumption turned out to be false?"*

### Phase 3: Alternative Generation

Generate exactly 2-4 distinct approaches. Follow these rules:

1. **Always include a baseline/null option** — keep current behaviour, do nothing, or minimal refactor. This anchors the comparison.
2. **Always include a minimal viable option** — the smallest change that achieves the core goal.
3. **Include 1-2 genuine alternatives** — structurally different approaches, not just scope variants of the same idea.
4. Each alternative must be distinct in *how* it achieves the goal. If two approaches differ only in effort, consolidate them.

Present each alternative as:

```
### Alternative A: <short title>
<1-2 sentence description of the approach>
**Key trade-off**: <one-line summary of the main cost/benefit>
```

### Phase 4: Best-Practice Alignment

Score each alternative against the ADR 0001 personality rubric (priority order: Security → Reliability → Modularity → Readability → Performance → Simplicity). For each alternative and each value:

| Score | Meaning |
|-------|---------|
| ✗ | Fails to meet minimum bar — do not accept without documented exception |
| ✓ | Meets minimum bar — adequate, no concerns |
| ✓✓ | Good — above average for this value |
| ✓✓✓ | Excellent — best-in-class for this value |

**Scoring guidance per value:**

**Security** — Credential surface area, least privilege, input validation, defense in depth, secret hygiene. Does this approach introduce new attack vectors? Does it follow OWASP principles?

**Reliability** — Edge case handling, safe failure modes, observability (logging, metrics), retry/backoff, transaction safety. Does it degrade gracefully?

**Modularity** — Coupling between components, single responsibility, interface clarity, testability, swapability. Can this module be rewritten without touching its callers?

**Readability** — Cognitive load, naming clarity, consistent style, flat over nested. Can a junior engineer trace a request through this design?

**Performance** — Resource bounds, concurrency model, caching strategy, bottleneck analysis. Never optimise before profiling — flag only clear performance risks.

**Simplicity** — Minimal moving parts, no framework for a one-liner, no abstraction before the third repetition. Is this the lightest solution that satisfies everything above?

**If the decision is architectural** (new containers, services, network topology, or infrastructure changes): also run the **ADR Pre-Build Checklist** (`Skills/Planner/adr-pre-build-check/SKILL.md`) and incorporate results.

### Phase 5: Trade-off Matrix + Recommendation

Present a formal scored table:

```
| Approach | Security | Reliability | Modularity | Readability | Perf | Simplicity | Effort | Risk |
|----------|----------|-------------|------------|-------------|------|------------|--------|------|
| Baseline | ✓✓       | ✓✓          | ✓          | ✓           | ✓✓   | ✓✓✓        | None   | Low  |
| Alt A    | ✓✓✓      | ✓✓          | ✓✓✓        | ✓✓          | ✓    | ✓✓         | High   | Med  |
| Alt B    | ✓✓       | ✓✓✓         | ✓✓         | ✓✓✓         | ✓✓   | ✓          | Med    | Low  |
```

**Effort**: None / Low / Med / High / Very High
**Risk**: Low / Med / High — probability of failure or unexpected cost

After the matrix, provide an explicit recommendation:

```
**Recommendation**: Alternative A because [1-2 sentence reasoning referencing
the rubric priorities and trade-off analysis].
```

Then ask the user to confirm or choose a different path:
- "Do you want to proceed with Alternative A?"
- "Would you prefer a different approach?"
- "Should I refine any alternative further?"

### Phase 6: Decision → Session Plans

Once the user confirms a direction:

1. Write standard session plans to `Tasks/` following all rules in `Skills/Workflows/Shared/session-plan-format.md`:
   - Session sizing: 2-5 tasks per session, sized for one V4 Flash run
   - Session naming: descriptive namespace, iteration number, date prefix
   - Each plan includes: Status, Date, Repair passes, Scope, Validation Rubric, Test baseline, Files, task entries with Why/Files/Changes/Acceptance
2. If the decision involves architectural changes, cross-reference the relevant ADRs in session plan descriptions.
3. If multiple sessions are needed, use distinct namespaces for parallel execution.

Do not write plans until the user has given explicit direction.

---

## Reference: Question Bank

### Goal Clarification
- What is the ultimate outcome?
- Is this a root cause fix or a symptom fix?
- What does success look like, measurable?
- What is non-negotiable vs nice-to-have?
- What is out of scope?

### Assumption Probes
- Technical: what tech stack are we locked into?
- Scale: what if demand is 10x?
- Timeline: what if the deadline moves?
- Dependency: what if an external system fails?
- Business: what if user behaviour doesn't match expectations?

### Security
- Does this approach expose new credential surfaces?
- Does it follow least privilege?
- Is input validated at every boundary?
- Are secrets handled via Swarm bundles, never env vars?

### Reliability
- What happens when this component fails?
- Is there observability (logs, metrics)?
- Does it have a HEALTHCHECK?
- Are there retry/backoff mechanisms?

### Modularity
- Can this be changed without affecting callers?
- Does it have a single responsibility?
- Is it testable in isolation?

### Performance
- What are the resource bounds?
- Is there a clear bottleneck?
- Is caching intentional or accidental?

### Simplicity
- What is the minimal version of this approach?
- Is every component justified?
- Would a junior engineer understand this design?
