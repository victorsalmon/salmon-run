---
name: autocode-delivery
description: Prepare a quality-approved change for review by creating a semantic commit, branch or pull-request handoff, and synchronized Asana status.
---

Use this skill when a change has a green quality record and the user asks to commit, push, open a pull request, or finish the engineering handoff.

1. Confirm the quality record is present and `Status: green-for-delivery`. If not, stop.
2. Recheck git status and diff. Stage only the intended files and associated task artifacts.
3. Create a focused semantic commit. Never include credentials, unrelated work, or generated artifacts that are not part of the change.
4. Push only to the intended non-production branch using the repository's safe git workflow.
5. If GitHub access is available, prepare or open a pull request containing the outcome, testing evidence, risks, and rollback notes. Otherwise, produce a complete handoff for manual PR creation.
6. If Asana access is available, attach the commit/PR link and move the task to the configured review section. Do not mark the task done until the human review policy permits it.

Approval is required for merging, production deployment, destructive data operations, credential changes, or any action that cannot be safely reversed.

Output the commit, branch, PR or handoff link, Asana update, and `Status: awaiting-review`.
