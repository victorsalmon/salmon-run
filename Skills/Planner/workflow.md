# Plan Workflow

<!-- markdownlint-disable MD005 MD051 -->

The Plan mode (triggered by user's "Plan" / "I'd like you to plan" / "please plan" / "print" command). Runs a single session and exits — no drain loop. The Planner writes session plans at `~/.salmon/Tasks/Code/<date>-<namespace>-<iteration>-<description>.md` with `**Status**: proposal` (interactive) or `**Status**: ready` (autonomous, pre-approved); see AGENTS.md § Plan output location. The Code mode executes them, the Review mode audits, the next Code run picks up feedback.

Interactive ZCode plans (ExitPlanMode) also land in `~/.salmon/Tasks/Code/` with `Status: proposal`; ExitPlanMode is the in-session approval gate, the file is the durable artifact. See AGENTS.md § Plan output location.

The mode overview lives at `Skills/Planner/SKILL.md`. The format spec (template, field reference, stub-mode shape) lives at `Skills/Workflows/Shared/session-plan-format.md`.

1. **Register** — per [Agent identity and registration](#agent-identity-and-registration) (use `planner-<random(1-1000001)>-<filetime>` per the orchestrator's ID format)
2. **Phase 1 — Discover**:
   - Scan `Tasks/Handoff/*.md` for `**Type**: plan-stub` files; mention any to the user
    - Load the `grill-me` skill at `Skills/Planner/grill-me.md`
   - Load the `handoff` skill at `Skills/Cowork/handoff.md`

   - Read `AGENTS.md` for project-wide conventions, connascence rules, and naming
    - Run the **Complexity Self-Check** (9 signals — see `Skills/Workflows/Shared/session-plan-format.md § Complexity Self-Check`, plus dependency-graph signal below). ≥2 firing signals (or 1 strong signal) means full Planner engagement; otherwise, suggest direct Coder dispatch to the user
    - **Dependency-graph signal** (complements the 8-signal list): A plan batch with 5+ sessions, depth > 2 in the dep DAG, or a fan-in node (3+ sessions depend on a single session) indicates coordination overhead that merits full Planner engagement.
   - If 0–1 signals fire and no greenfield/architectural-decision, ask the user: "This looks like a direct Coder dispatch — should I skip the full plan and let the Coder handle it?"
3. **Phase 2 — Write (grill, then write)**:
   - **Grilling Protocol** — Use the `grill-me` skill. The goal is for the Coder to function semi-autonomously on the resulting plan. The Coder is still encouraged to ask questions, but the *baseline* expectation is that all design decisions are resolved before the plan is written.
      - **Skill** — `Skills/Planner/grill-me.md`. Prompt: *"Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer. Ask the questions one at a time. If a question can be answered by exploring the codebase, explore the codebase instead."*
     - **Operational rules** — 8-turn budget, 2-streak convergence check (full rules in the skill's SKILL.md)
     - **What to ask** — full decision tree (scope, architecture, file ownership, connascence, validation criteria, test baseline, rollback/safety), ambiguous file paths, conflicting conventions, unknown side effects, missing user preferences, plan shape (sessions, dependencies, validation)
     - **What NOT to ask** — questions the codebase can answer, redundant questions, open-ended brainstorming, decisions another Planner already locked in
     - **How to record** — embed `## Resolved Decisions` near the top of the plan with `**Q:** <question> | **A:** <answer>` entries
     - **Self-check before plan-write** — ask: *"Could the Coder execute this plan without asking me a single follow-up question?"* If "no" or "probably", go back to grilling
     - **Edge cases**:
       - *Time pressure / "just plan it"* — confirm explicitly: "I'd rather grill you for 2 minutes than have the Coder block on a question for 20 minutes. Can I ask 3-5 questions first?" The directive defaults to grilling
       - *Recurring plans* — reference the locked decision set in `Tasks/Complete/` rather than re-asking. Add `**Decision provenance**: <prior-plan.md>` to each resolved Q&A
       - *Plan Stubs* — Plan Stubs in `Tasks/Handoff/` (`type: plan-stub`) are deliberately ungrilled. Grilling happens at the Plan-Stub-to-Plan transition
     - **2a. Pre-code Questionnaire** (mandatory for Complexity Self-Check ≥2):
         1. **Complexity gate**: Only runs when Complexity Self-Check scores ≥2 signals (skip for 0–1 signal plans, stub-mode plans, and direct Coder dispatches)
         2. **Research pass**: Before generating questions, check the codebase (grep/glob) for relevant files, existing ADRs, prior plans in `Tasks/Complete/`, and docs in `docs/`. No more than 3 reads. Collect all findings for the plan's `## References` section.
         3. **Question generation**: Generate 3–5 architectural questions, each with explicit pros/cons and a recommended answer. Questions MUST be answerable from the user's knowledge — no questions the codebase can answer.
         4. **Questionnaire**: Present one question at a time. After each answer, optionally adjust remaining questions based on new information.
         5. **Requirement mapping**: After all questions answered, extract MUST/SHOULD/MAY requirements from the answers. Write these into the plan's `## Requirements (RFC 2119)` section.
         6. **Recording**: All Q&A pairs go into `## Resolved Decisions` in the plan (see session-plan-format.md for the table format). Each entry includes the question, the user's answer, and the mapped requirements.
        - If the Questionnaire reveals a fundamental design ambiguity that cannot be resolved, write a `## Deferred Decisions` block and create a manual task for follow-up.
        - When the `grill-me` skill's 8-turn budget is insufficient, the Pre-code Questionnaire extends the budget to 12 turns.
        - The existing `grill-me` skill remains available for zero-config sessions. Pre-code Questionnaire is a superset with structured framing.
    - For batches of 3+ sessions, review the **Dependency Matrix Pattern** in `workflow-primitives.md § Connascence → Dependency Matrix Pattern` before writing individual plans. This ensures consistent namespace assignment and valid DependsOn chains across the batch.
    - **Coupling-Aware Plan Splitting** — when the work touches shared files across multiple concerns, use this method to maximize parallelism:
      1. List all files the work touches.
      2. Identify **coupling points** — files touched by multiple concerns (shared modules, config, AGENTS.md).
      3. For each coupling point, decide: (a) isolate it into its own plan (sequential prerequisite for all consumers), or (b) batch all consumers into one namespace (sequential within the namespace). Prefer (a) when the coupling point is a stable interface; prefer (b) when the consumers are tightly interdependent.
      4. Assign namespaces by file-overlap: disjoint file sets → different namespaces (parallel). Overlapping files → same namespace (sequential) OR split via `DependsOn` (one plan modifies the shared file first, others reference it).
      5. Use `ConnascenceScope` to declare fine-grained coupling — even within the same namespace, if two plans touch disjoint files, the extractor can split them into parallel subgroups, but only if `ConnascenceScope` is populated.
      6. **Prefer equal-size slices over minimizing connascence.** Two 3-task plans that share a file are better than one 6-task plan, IF the shared file is isolated into a prerequisite.
      7. **Worked example**: A feature touches `provider.mjs` (shared interface), `lambda-a.mjs` (consumer A), `lambda-b.mjs` (consumer B), and `portal.mjs` (UI). Split into:
         - `provider-01` (modifies `provider.mjs`) — root, all others depend on it
         - `lambda-a-01` (modifies `lambda-a.mjs`) — `DependsOn: provider-01 (status: complete)`
         - `lambda-b-01` (modifies `lambda-b.mjs`) — `DependsOn: provider-01 (status: complete)`
         - `portal-01` (modifies `portal.mjs`) — `DependsOn: provider-01 (status: complete)`
         All three consumers run in parallel after `provider-01` completes.
      8. Model how `Get-ConnascenceGroups.ps1` will group the plans — ensure `Files:` + `ConnascenceScope` produce the intended grouping.
    - **Token Estimation Heuristic** — estimate the token budget using:
      > `estimated_tokens = plan_text + file_reads + reasoning + output`
      >
      > | Component | Estimation |
      > | --- | --- |
      > | `plan_text` | ~1.5K tokens per task in the plan (a 4-task plan ≈ 6K) |
      > | `file_reads` | ~3K tokens per file the coder will read (target file + referenced files). A 400-line `.ps1` ≈ 3K; a 1000-line `.psm1` ≈ 8K. Multiply by 1.5× if the coder needs to read tests too. |
      > | `reasoning` | ~10K tokens per non-trivial task (algorithmic work, new patterns). ~3K for mechanical tasks (rename, add field, update config). |
      > | `output` | ~2K tokens per file modified (the diff the coder writes). |
      >
      > **Example**: A 4-task plan modifying 3 `.ps1` files (avg 300 lines) + 1 `.md` doc:
      > - `plan_text` = 4 × 1.5K = 6K
      > - `file_reads` = 4 × 3K × 1.5 (with tests) = 18K
      > - `reasoning` = 4 × 8K (mixed) = 32K
      > - `output` = 4 × 2K = 8K
      > - **Total ≈ 64K** → set `Token budget: 70000`
      >
      > **Cap**: If the estimate exceeds 200K, split the plan. The 250K cap is a hard ceiling; the 200K soft target leaves room for context drift and compaction overhead. DeepSeek V4 Flash Max quality degrades above ~250K — size plans so the coder can complete and exit before hitting 250K.
    - **Write the plan** — load the `name-session-plan` skill and use `Write-SessionPlan.ps1` to generate the filename:

         ```powershell
         . "Skills/Planner/Write-SessionPlan.ps1"
         Write-SessionPlan -Namespace $namespace -Iteration $iteration `
             -Description $description -Content $content
         ```

        The script produces `<date>-<namespace>-<iteration>-<description>.md` following the Print naming convention (see `Skills/Planner/name-session-plan.md` and `session-plan-format.md`). Set `**Status**: proposal` for interactive plans (default); flip to `ready` on explicit user approval for autonomous dispatch. Embed `## Resolved Decisions`, `## Post-Implementation Audit`, `## Tasks`.

        If the plan specifies `**Overrides**` instead of `default`, show the user the fully resolved harness, provider, model, and effort and obtain an explicit confirmation during this interactive session. Only then write `**Overrides confirmation**: confirmed by user`; otherwise leave the plan as a proposal with the confirmation field unconfirmed. The dispatcher refuses unconfirmed Overrides.
       **Mandatory: populate the `## References` section** — every plan must include a References block (see session-plan-format.md) listing all relevant ADRs, prior plans, documentation, key codebase files, and other resources the Coder needs. The research pass in step 2a.2 feeds this section. For stub-mode or trivial plans, write `None — self-contained plan` rather than omitting the section.
4. **Phase 3 — Complete (self-check, commit, sign off)**:
    - **Planner Self-Check** — run this 9-box checklist immediately before `git add`. Every box must be checkable:
      - [ ] All grilling-blocking questions resolved (`## Resolved Decisions` non-empty)
      - [ ] `**Files:**` enumerates every file the plan touches
      - [ ] `**Connascence:**` populated or `None` with justification
      - [ ] `**Token budget:**` < 250,000
      - [ ] `**Validation Rubric:**` has ≥ 2 named checkboxes
      - [ ] Self-check question answered YES: *"Could the Coder execute this plan without asking me a single follow-up question?"*
       - [ ] `## Post-Implementation Audit` section embedded (grooming, docs/Mermaid/agent libraries, other audits)
       - [ ] `## References` section populated (ADRs, see-also plans, docs, key files, other resources)
       - [ ] Plan committed or referenced from `Tasks/Handoff/`
       - [ ] `**DependsOn:**` field is valid: (a) all refs resolve to real plans, (b) no self-references or cycles, (c) status gates are `complete` or `reviewed`
    - **Step: Dependency Graph Validation** — Before committing, run three manual checks on the current session plan batch:
      1. **Refs exist**: Every `**DependsOn**:` value references a file that exists in `Tasks/Code/`, `Tasks/Working/`, `Tasks/Review/`, or `Tasks/Complete/`. The namespace-iteration portion must match a file prefix.
      2. **No cycles**: Trace each dep chain. No session may directly or transitively depend on itself.
      3. **Filenames match**: The `Namespace-Iteration` portion of each DependsOn ref must match the file-prefix convention `<date>-<Namespace>-<Iteration>-`. A mismatch means the ref points to a non-existent session.
      - If any check fails, do NOT commit. Fix the DependsOn field(s) and re-verify.
      - > The orchestrator-level validation (`Invoke-ValidateDependencyGraph.ps1`, see session E-8) will catch these too, but fixing at Plan time avoids context-switching for the Coder.
    - **Commit (but do NOT push)** — acquire git lock (`Get-ORCHESTRATORGitLock -TimeoutMs 60000`; if $null returned, exit 12), `git add <plan-file>` (per-file, never `-A`), `git commit -m "<semantic message>"` inside `try {} finally { Remove-ORCHESTRATORGitLock }`. The Coder is responsible for `git push`
   - **Emit the Planner Sign-Off Report**:

     ```text
     === Sign Off: planner ===
     Agent: <planner-agent-id>
     Plan: <path-to-plan>
     Grilling: complete (N decisions resolved)
     Files: <count> listed
      Connascence: <None | list>
      Token budget: <N> (under 250,000)
      Post-Implementation Audit: embedded
      Dependency Graph: Mermaid flowchart included (session nodes + DependsOn edges)
      Status: Ready to Sign Off
     ```

   - **Write a `SIGN_OFF` workflow event**:

     ```powershell
     Write-WorkflowEvent -Type SIGN_OFF -Detail "Ready to Sign Off" -Phase plan
     ```

5. **Exit** — do NOT enter a drain/poll loop. The Planner is single-pass. The Post-Implementation Audit Hook for what the Coder/Reviewer should run after implementation lands is in [Planner Sign-Off: Post-Implementation Audit Hook](#planner-sign-off-post-implementation-audit-hook) below.
