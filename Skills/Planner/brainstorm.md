# Skill: Brainstorm

**Purpose**: Guide the Plan mode (or any agent) through structured ideation — generate diverse ideas on a topic, present them clearly to the user, collect feedback, then write execution plans to `Tasks/Code/` based on the user's direction.

**Owner**: `Skills/Planner/SKILL.md` — the Plan mode owns this skill, but any agent may invoke it.

**Prerequisites**: Write access to `Tasks/Code/` directory.

**Recognition**: Triggered when the user asks to brainstorm, generate ideas, explore approaches, or think creatively about a problem.

---

## Workflow

### Phase 1: Clarify Scope

Before generating ideas, confirm you understand the problem:
- What is the core question or goal?
- Are there constraints (time, resources, technical limitations)?
- Any areas explicitly out of scope?
- Who is the audience or beneficiary?

Ask clarifying questions if the user's request is ambiguous. Do not proceed until the scope is mutually understood.

### Phase 2: Choose Protocol

Select a brainstorming protocol that fits the problem type. **Default to SCAMPER** for most product, feature, or strategy questions. For debugging or troubleshooting, default to Reverse Brainstorm.

If unsure, briefly suggest 2-3 options and let the user choose.

Detailed protocol descriptions are in the Protocols section below.

### Phase 3: Generate Ideas

Run the selected protocol. Generate a diverse range of ideas — aim for breadth, not depth. Do not self-censor or evaluate during generation.

**For CODE containers**: Use subagents (`@explore`, `@general`) to generate ideas in parallel across different angles, then synthesize into a single deduplicated output.

**For ORCHESTRATOR agents**: Work through the protocol systematically using the agent's own reasoning. If the topic requires research or feasibility checking, dispatch a CODE container for depth analysis before presenting.

### Phase 4: Present to User

Present the generated ideas using a consistent format. The default structure:

```
## Idea <N>: <Short Title>
<1-2 sentence description>
**Pros**: <bullet list>
**Cons**: <bullet list>
```

The numbered titles are required so the user can reference ideas by number. The rest of the structure may be adapted if the domain warrants a different format (e.g., a comparison matrix for architectural options, a timeline for phased rollout ideas).

If there are 8+ ideas, consider grouping by theme with sub-headings.

### Phase 5: Collect Feedback

Ask the user which ideas they want to explore further, combine, or refine. Use numbered references:
- "Would you like me to explore Idea 3 further?"
- "Should I combine Ideas 2 and 5?"
- "Which of these should I turn into session plans?"

Accept any feedback: refinement, combination, modification, or rejection of ideas.

### Phase 6: Write Execution Plans

Based on the user's feedback, write standard session plans to `Tasks/Code/`:
- Follow the standard session plan format (see `Skills/Workflows/Shared/session-plan-format.md`)
- One concern per plan, sized for a single V4 Flash run (2-5 tasks)
- Use a descriptive namespace like `brainstorm-<topic>-<aspect>`
- Multiple plans should use distinct namespaces for parallel execution

Do not write plans until the user has given explicit direction.

---

## Protocols

### Divergent (Generate Broadly)

**SCAMPER** — Best for product, feature, or process improvement.
- **S**ubstitute — What can be replaced?
- **C**ombine — What can be merged?
- **A**dapt — What can be modified from another context?
- **M**odify — What can be changed (scale, form, function)?
- **P**ut to another use — What else can it do?
- **E**liminate — What can be removed?
- **R**everse — What happens if we invert the process?

**Reverse Brainstorm** — Best for risk analysis, debugging, troubleshooting.
- Ask: "How could we make this problem worse or cause this system to fail?"
- Invert each finding to identify preventive measures.

**"What If"** — Best for exploring unconventional directions.
- Pick one constraint or assumption and invert it.
- Generate ideas around the inverted scenario.
- Example: "What if we had unlimited budget?" → also run "What if we had zero budget?"

### Convergent (Narrow Down)

Only use these when the user asks to evaluate or prioritize.

**Effort/Impact Matrix** — Score each idea on two axes. Present as a simple table:

| Idea | Effort | Impact | Notes |
|------|--------|--------|-------|
| 1 | Low | High | Quick win |
| 2 | High | High | Strategic bet |
| 3 | Low | Low | Deprioritize |

**Dot Voting** — Ask the user which 3 ideas they would pick from the list. Focus further work on those selections.

---

## OpenCode / Subagent Notes

When a CODE container is dispatched for depth research or feasibility analysis as part of a brainstorm:

1. **Parallel generation**: Use `@explore` and `@general` subagents to generate ideas simultaneously across different angles. Each subagent returns a structured list matching the standard output format.
2. **Synthesis**: After subagents return, deduplicate and merge their outputs into a single numbered list.
3. **Depth dive**: If an idea needs technical feasibility analysis, dispatch a follow-up CODE session focused on that single idea. Return the result as a structured section back to the dispatching ORCHESTRATOR agent.
