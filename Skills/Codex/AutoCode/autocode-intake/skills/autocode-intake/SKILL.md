---
name: autocode-intake
description: Turn an Asana engineering task or user request into a repository-aware implementation plan with acceptance criteria, risks, and explicit approval status.
---

Use this skill when the user asks to scope, triage, clarify, or plan an engineering task, especially when the task originates in Asana.

1. Locate the task in Asana when an Asana connector is available. If no task identifier or usable task context exists, ask for it or proceed only from the user-provided request.
2. Read the task description, comments, attachments, dependencies, and current status. Do not infer missing requirements.
3. Identify the target repository and inspect its `AGENTS.md`, relevant package/build files, existing tests, and nearby implementation patterns.
4. Produce a plan containing: outcome, in-scope files, out-of-scope work, acceptance criteria, test strategy, risks, dependencies, and the exact point requiring user approval.
5. If the plan is ready for implementation, record the plan in the repository's configured task workflow. For this workspace, orchestration artifacts belong under `C:\Repos\salmon-orchestrator\Tasks\`, not a target repository's `Tasks\` directory.
6. If Asana updates are available, add a concise plan summary and link to the local task artifact. Do not move a task to `Done` from intake.

Stop and ask before proceeding when the target repository, acceptance criteria, data-safety impact, production scope, or required credentials are unclear.

Output a concise plan and a `Status` of `needs-user`, `ready`, or `blocked`.
