# Cowork Script Registry

> **Purpose**: Quick-reference for all available Cowork utility scripts. Each script has a documented contract per the Cowork Script Schema.

## Schema Reference

`Skills/Cowork/cowork-scripts.schema.json` defines the JSON Schema (draft-07) contract for every Cowork script.

## Scripts

| Name | Synopsis | Parameters | Output |
|------|----------|------------|--------|
| `New-LockHeader.ps1` | Generate or append a Lock Header for agent chain-of-possession tracking | `-AgentId` (string, mandatory), `-Status` (locked/released, mandatory), `-DryRun` (switch), `-OutputPath` (string), `-ExistingContent` (string), `-ReleaseTimestamp` (string) | `Tasks/Working/**/*.md` or stdout with `-DryRun` |
| `New-CoworkStub.ps1` | Generate cowork-stub handoff document for non-final session endings | `-Topic`, `-AgentId`, `-Date`, `-Status`, `-CurrentState`, `-WhatWorked` (string[]), `-WhatDidntWork` (string[]), `-NextActions` (string[]), `-DryRun` (switch) | `Tasks/Handoff/<date>-<topic>.md` or stdout with `-DryRun` |
| `New-FinalHandoff.ps1` | Generate final-handoff document with completed/incomplete items, tool retrospectives, and redirect maps | `-Topic`, `-AgentId`, `-Reason`, `-CompletedItems` (hashtable[]), `-IncompleteItems` (hashtable[]), `-DryRun` (switch) | `Tasks/Handoff/<date>-<topic>.md` or stdout with `-DryRun` |
| `New-SessionLog.ps1` | Generate phase-structured session log with skills and API footprint tracking | `-Topic`, `-AgentId`, `-Phases` (hashtable[]), `-SkillsUsed` (hashtable[]), `-DryRun` (switch) | `Tasks/Handoff/<date>-session-log.md` or stdout with `-DryRun` |
| `New-PostHocPlan.ps1` | Generate post-hoc session plan for completed Cowork sessions with code changes | `-Date`, `-Topic`, `-Iteration`, `-Scope`, `-AgentId`, `-CommitHashes` (string[]), `-Tasks` (hashtable[]), `-DryRun` (switch) | `Tasks/Review/<date>-<topic>-posthoc.md` or stdout with `-DryRun` |
| `New-ManualTask.ps1` | Generate manual task file for human-required actions | `-Topic`, `-OriginatingContext`, `-Steps` (string[]), `-ExpectedOutcome`, `-FollowUp`, `-DryRun` (switch) | `Tasks/Manual/<date>-<topic>.md` or stdout with `-DryRun` |
| `New-MemoryEntry.ps1` | **DEPRECATED** — superseded by `Write-NamespaceLog`. Append or update entries in docs/Memory/ files | `-MemoryFilePath`, `-Container`, `-Project`, `-Section`, `-Entries` (hashtable[]), `-Mode` (append/update), `-DryRun` (switch) | `docs/Memory/<repo>/<file>.md` or stdout with `-DryRun` | | Also exports `Resolve-MemoryRepo -RepoName <name> [-Filename <file>]` — resolves repo paths from `_project-map.json` (kept for backward compat) |
| `New-CredentialRef.ps1` | Generate AWS SM credential reference table for handoff documents | `-AwsPath`, `-Region`, `-Credentials` (hashtable[]), `-SsoRequired`, `-OutputFormat` (markdown-table/inline), `-DryRun` (switch) | stdout (section generator) |
| `New-ForkStub.ps1` | Write Fork-Stub context-transfer document for /fork command | `-Topic`, `-Goal`, `-ContextBody`, `-Date`, `-OutputDir` (default Tasks/Handoff), `-DryRun` (switch) | `Tasks/Handoff/fork-stub-<date>-<topic>.md` or stdout with `-DryRun` |
| `Invoke-Fork.ps1` | Launch forked terminal via opencode --continue --fork, or stub-only write | `-StubPath`, `-Goal`, `-StubOnly` (switch), `-DryRun` (switch) | stdout (confirmation with stub path) |
| `Invoke-ForkFlow.ps1` | **Combined entry point** — writes Fork-Stub and launches terminal in one call | `-Topic`, `-Goal`, `-ContextFile`, `-Date`, `-OutputDir`, `-StubOnly` (switch), `-DryRun` (switch) | Resolved stub path |

## Invocation Pattern

```powershell
# Dot-source if defined as function:
. .\Skills\Workflows\Cowork\Scripts\New-LockHeader.ps1
# Or call directly:
& .\Skills\Workflows\Cowork\Scripts\New-LockHeader.ps1 -AgentId "coder-847-35" -Status locked -OutputPath "plan.md"
# Dry run:
& .\Skills\Workflows\Cowork\Scripts\New-LockHeader.ps1 -AgentId "coder-847-35" -Status locked -DryRun
```