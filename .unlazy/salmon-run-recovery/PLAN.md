# Salmon Run recovery plan

Mode: orchestrated, sequential execution

Objective: make concept-to-project planning, code review, batched project QA,
parallel scheduling, recovery, and project completion work as one verifiable
pipeline without disturbing unrelated worktree changes.

## Depth tree

1. Planning contract
   - Enforce a hard 100,000-token implementation ceiling per session plan.
   - Produce substantive session plans from a project concept or explicit children.
2. Review contract
   - Make pass/rework a machine-readable verdict independent of process exit code.
   - Persist rejection summary and feedback-file evidence and route rework safely.
3. Project quality lifecycle
   - Hold reviewed children in QA-ready state until the project batch is complete.
   - Run project QA once, track milestones, and create a complete project bundle.
4. Scheduler and recovery
   - Enforce configured pond parallelism and repository writer safety.
   - Prove orphaned claims and stale locks recover without losing plans.
5. Integration proof
   - Exercise concept-to-complete behavior in an isolated runtime.
   - Run focused mutation/property proof and the full regression suite.
   - Reconcile and smoke-test the live queue only after isolated proof is green.

## Execution order

- leaf-planning
- leaf-review
- leaf-project-qa
- leaf-scheduler
- node-integration
- root GATES.md

All leaves run sequentially because the implementation touches shared pond and
transition surfaces. Existing unrelated modifications remain outside this plan.

