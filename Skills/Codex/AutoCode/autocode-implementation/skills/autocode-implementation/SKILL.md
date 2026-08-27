---
name: autocode-implementation
description: Implement an approved AutoCode plan in the target repository, preserving local conventions and adding focused regression tests.
---

Use this skill when an approved plan is available and the user asks Codex to implement, build, or fix the scoped change.

1. Read the approved plan, repository instructions, and current git status. Preserve unrelated work already present in the working tree.
2. Reconfirm the acceptance criteria and identify the smallest coherent implementation boundary.
3. Inspect existing code and tests before editing. Reuse established abstractions and commands.
4. Make the change with focused edits. Add or update tests for the requested behavior and its important failure modes.
5. Run the repository-specific checks required by its instructions. Report commands, results, and any environmental limitation.
6. Do not deploy, rotate credentials, modify production data, or perform destructive migrations as part of implementation.

Use subagents only for independent exploration, test design, or review; the main agent owns integration and the final diff.

Stop and ask when the implementation would exceed the approved scope, acceptance criteria conflict, tests cannot establish correctness, or a production/irreversible action is required.

Output a summary of files changed, tests run, remaining risks, and `Status: ready-for-quality` or `Status: blocked`.
