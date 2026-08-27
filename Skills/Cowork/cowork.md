# DEPRECATED — Cowork skill moved to `Skills/Workflows/Cowork/`

This file is preserved for backward compatibility. The canonical location is now:
`Skills/Archive/workflow-cowork-cowork.md`

All scripts are at: `Skills/Workflows/Cowork/Scripts/`

# Skill: Cowork — Interactive pair-work workflow

**Type**: skill-entrypoint
**Owner**: Cowork mode
**Container**: opencode (CLI, user-invoked — NOT a fleet container)
**Loaded via**: `skill("cowork")` from the opencode CLI, or read from this file when the user invokes "cowork" / "cowork with me" / "let's cowork"

**Output locations**:
- `Tasks/Handoff/<date>-<topic>.md` — cowork-stub or final-handoff
- `Tasks/Handoff/<date>-<session-log>.md` — session log
- `Tasks/Review/<date>-<topic>-posthoc.md` — post-hoc plan (if code changed)
- `Tasks/Manual/<date>-<topic>.md` — manual task (if human action needed)
- `docs/Memory/<repo>/mem-<container>-<project>.md` — memory file (if final handoff)

**Related**:
- `Skills/Create/Skill-Authoring/workflow-primitives.md § Phase 5 — Sign Off` — standard Sign Off block format
- `Skills/Cowork/handoff.md` — Final Handoff / Cowork Stub / Plan Stub template spec
- `AGENTS.md § Cowork Workflow` — brief pointer (this file replaces the inline workflow)
- `AGENTS.md § COMPLETION CHECKLIST` — full CC step definitions
- `Skills/Cowork/fork.md` — Fork skill (parallel session forking)

---

## MCP-first rule

Before installing any tool or writing automation from scratch, check the fleet container inventory at `Skills/ORCHESTRATOR/Personas/Shared/environment.md § Fleet Container Inventory`. The fleet has containers for browser automation (`mcp_browserless`), web fetching (`mcp_web`), quality engineering (`mcp_aqe`), and more. Always use these existing services first — run scripts in throwaway Docker containers on `service_net` rather than installing on the host.

---

## Phase 0: Initialize — Read-Before-Asking

1. If a handoff file exists in `Tasks/Handoff/` matching today's topic, read it first (cowork-stub or final-handoff variant — see `Skills/Cowork/handoff.md`)
2. Read every file the handoff references (memory files, skill files, data files)
3. Summarize your understanding to the user for confirmation before proceeding
4. Only after confirmation should you ask questions
5. Record `$sessionStart = Get-Date`, persist to `Tasks/Logs/session-start-$($env:OC_STREAM_ID ?? $env:OC_RESERVATION_AGENT_ID ?? $PID).log` (lane/agent-scoped), and clear `$PWD/.session-timing.txt` for the per-file timing cache
6. **Open audit session** — Log that a Cowork session has started:
   ```powershell
   if (Get-Module SalmonRun.Audit) {
       $script:auditSession = @{ domain = "adhoc"; topic = "<topic>" }
       $null = New-Item -ItemType Directory -Path "Tasks/Logs/Audit/adhoc" -Force -ErrorAction SilentlyContinue
       Write-AuditEntry -Entry @{
           ts = [datetime]::UtcNow.ToString('o')
           agent = $script:agentId
           domain = "adhoc"
           action = "session:start"
           session = "<topic>"
       } -Domain "adhoc"
   }
   ```
7. Write a `SESSION_START` workflow event: `Write-WorkflowEvent -Type SESSION_START -Detail "Cowork session started" -Phase cowork`

The Cowork session audits all API calls made through `Invoke-ApiCall` during the session. If the session used custom scripts with bare `Invoke-RestMethod`, those calls will NOT be captured — migrate them or use `Write-AuditEntry` manually.

**Output**: User has confirmed understanding of prior session state (if any). `$sessionStart` recorded. Audit session is open.

---

## Phase 1: Prototype & Perfect

Iterative work loop with the user. Build → test → refine.

**Tools**:
- `New-LockHeader.ps1` — when creating or editing files that need chain-of-possession
- `New-MemoryEntry.ps1` — to track session state incrementally

**For any file change**: prepend a Lock Header using `New-LockHeader.ps1` (see `Skills/Create/Skill-Authoring/workflow-primitives.md § Lock Header` for format).

**Output**: Working code/files. `$sessionStart` is preserved.

---

## Phase 2: Record — What Worked, What Didn't

At session end, capture:
- Which tools/approaches succeeded? (with verification method: test pass, API response, command stdout)
- Which tools/approaches failed? (with why)
- Which skills were used? Were they adequate or did they need adaptation?
- What working pattern emerged from problem → solution?

Populate the hashtables that Phase 3 scripts consume.

**Output**: A mental or scratch-note summary. Will be folded into the Final Handoff at Phase 3.

---

## Phase 3: Handoff

### Close audit session (all session ends)
0. **Close audit session** — Log session end:
   ```powershell
   if (Get-Module SalmonRun.Audit -ErrorAction SilentlyContinue) {
       Write-AuditEntry -Entry @{
           ts = [datetime]::UtcNow.ToString('o')
           agent = $script:agentId
           domain = "adhoc"
           action = "session:end"
           session = "<topic>"
       } -Domain "adhoc"
   }
   ```

### Session End (not final)
1. `. Skills/Intake/Scripts/New-CoworkStub.ps1 -Parameters` → `Tasks/Handoff/<date>-<topic>.md`
2. `. Skills/Cowork/Scripts/New-SessionLog.ps1 -Parameters` → `Tasks/Handoff/<date>-session-log.md`

### Session End (final / context capacity)
1. Write decision log: `Write-NamespaceLog -Namespace <domain> -Type MEMORY -Detail "<summary of key state changes>"`
2. `. Skills/Cowork/Scripts/New-FinalHandoff.ps1 -Parameters` → `Tasks/Handoff/<date>-<topic>.md`
3. `. Skills/Cowork/Scripts/New-SessionLog.ps1 -Parameters` → `Tasks/Handoff/<date>-session-log.md`

### Code Changed During Session
1. `. Skills/Cowork/Scripts/New-PostHocPlan.ps1 -Parameters` → `Tasks/Review/<date>-<topic>-posthoc.md`
2. Per CC step 1, write a Post-Hoc Session Plan to `Tasks/Review/`. Post-hoc is mandatory when codebase files were changed.

### Human Action Required
1. `. Skills/Cowork/Scripts/New-ManualTask.ps1 -Parameters` → `Tasks/Manual/<date>-<topic>.md`

### Credential Reference Needed (any handoff)
1. `. Skills/Cowork/Scripts/New-CredentialRef.ps1 -Parameters` — stdout (include in handoff doc)
2. Pipe output into the handoff doc

### Multi-Session Cowork Plans

<!-- doc-lint: exempt -->
Multi-session cowork plans live in `Tasks/Handoff/`. When a multi-session plan is fully finished (all sessions complete and verified), move the plan file to `Tasks/Complete/` under a namespace sub-folder (e.g. `Tasks/Complete/2026-06-15-cowork-bookkeeping-phase3/2026.05.30-bookkeeping-phase3.md`). Cowork plans often span multiple sessions — that is why they live in `Tasks/Handoff/` rather than only in agent memory, so that subsequent sessions can pick up the plan state and resume work.

When resuming a multi-session plan: read the prior handoff, read the namespace log it references via `Get-NamespaceLog`, and confirm with the user which session is in-progress before continuing.

### Security Note

No script writes secrets. All credential references use AWS SM key names only. See `Skills/Cowork/handoff.md` General Rules §2 and §7.

**Output**: One or more handoff documents on disk. Namespace log updated if final (via `Write-NamespaceLog`).

---

## Phase 4: Sign Off (Final Handoff Completeness Check)

Before exiting, the Cowork agent double-checks the Final Handoff document is complete. The Cowork cannot report `Ready to Sign Off` with an incomplete handoff — that strands the next agent. Re-read the handoff doc and ask:

1. **Memory completeness** — Is there any additional memory (project state, gotchas, working patterns, dead-ends) the next agent will need that is NOT in the handoff or its referenced namespace log? If yes, write it via `Write-NamespaceLog` first, then re-reference it from the handoff.
2. **Tools completeness** — Are all scripts, helpers, commands, or shell one-liners the next agent will need listed in "Key Files" or "Tools & Approaches — What Worked"? Are the entry points (e.g., `. Skills/Cowork/Scripts/New-X.ps1`) included?
3. **Helpful information** — Are there upstream/downstream documents, glossary entries, ADRs, or memory files the next agent should know about? Cross-link them.
4. **Orphan references** — Are there files referenced in the session that are NOT cross-referenced by any other repo document? Add them to "Orphan notes".
5. **Verification evidence** — Does every completed item have a `Verification` cell? (test pass / API output / command stdout / screenshot)
6. **Redirects / Deprecations** — If files moved or scripts retired during the session, is the old→new mapping recorded?

If the answer to any of these is "no", update the handoff/memory file before signing off.

When all six checks pass, emit the **standard Sign Off block** (see "Sign Off block" below) and proceed to the Completion Checklist.

---

## Sign Off block

Use the standard format from `Skills/Create/Skill-Authoring/workflow-primitives.md § Phase 5 — Sign Off`:

```
=== Sign Off: cowork ===
Agent: <agent-id>
Session: <session-start ISO-8601> → <now ISO-8601>
Closure artifact(s) verified: <list — e.g. "Tasks/Handoff/<file>.md, Tasks/Logs/<namespace>.log">
Outstanding items: <none | list with file paths>
Working tree: <clean | dirty — see git status>
Status: Ready to Sign Off
```

The terminal line `Status: Ready to Sign Off` is mandatory.

After emitting the block, write a `SIGN_OFF` workflow event:
```powershell
Write-WorkflowEvent -Type SIGN_OFF -Detail "Ready to Sign Off" -Phase cowork
```

The session ends here — do NOT enter a Drain Queue loop (CC step 11 is Coder/Reviewer only) and do NOT start a new build/test cycle after signing off.

---

## Completion Checklist (Cowork Adaptation)

The full CC is defined in `AGENTS.md § COMPLETION CHECKLIST` (steps 1-12). This section makes explicit what Cowork does at each step, so the agent cannot forget any of them. **Do not skip any step that says "must" below.**

| CC step | What Cowork does |
| :--- | :--- |
| 1. Post hoc print / Verify plan | **MUST run.** Read CC step 1's three Cowork branches. If a plan file existed, verify every listed task. If no plan and no code changes, write `Tasks/Review/cowork-<date>.md`. If no plan but code changes were made, write a Post-Hoc Session Plan to `Tasks/Review/`. |
| 2. Pester tests | **SKIP.** No Pester tests are run during Cowork sessions. Replace with manual verification: re-run the commands that proved each completed item works (test pass / API response / command stdout). |
| 3. Update documentation and cross-references | **MUST run.** Update any `docs/` guides or `AGENTS.md` sections affected by the changes. Cross-reference consistency check: for every file modified, grep the codebase for files that reference it and verify references still match. |
| 4. Update agent templates | **MUST run if the change impacts an opencode role.** Update `Skills/<role>.md` or `Personas/<role>/agents.md` for any role whose behaviour or surface area changed. Container roles (ORCH/VERI/BASE) have their own `Skills/ORCHESTRATOR/Personas/<ROLE>/agents.md`; opencode roles (Audit/Code/Review/Cowork) have skill files. |
| 5. Bug & Confusion Log | **MUST run.** Re-read the Bug & Confusion Log. For each entry, if fixable, fix it in the working tree; if it's a point of confusion, create a manual task in `Tasks/Manual/`. Mark each entry `✓ fixed` or `→ manual task`. |
| 6. Stage task files with code | **MUST run if files changed.** Use `git add <file>` per-file — never `git add -A` or `git commit -a`. Task files in `Tasks/Working/`, `Tasks/Code/`, `Tasks/Review/`, `Tasks/Complete/` are first-class commit citizens. |
| 7. Modular commits | **MUST run if files changed.** One concern per commit, semantic messages (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`). NEVER commit secrets or credentials. NEVER update git config, skip hooks, force push to main, rebase/amend pushed commits. |
| 8. Verify clean working tree | **MUST run.** `git status --porcelain` must return zero untracked or modified files. Stage and commit stragglers (or add to `.gitignore` if intentional). |
| 9. Push to repository | **MUST run if files changed.** `& (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push` to resolve non-fast-forward conflicts without restoring stale deleted files. |
| 10. Report elapsed time | **MUST run.** Output total wall-clock time since Phase 0 step 5 (`$sessionStart`) in seconds + minutes:seconds, followed by per-file breakdown from `.session-timing.txt`. |
| 11. Route to Drain Queue | **SKIP.** CC step 11 is Coder/Reviewer only. Cowork exits after CC step 10. |
| 12. Phase 5 — Sign Off | **MUST run.** Emit the standard Sign Off block (see "Sign Off block" section above). The terminal line `Status: Ready to Sign Off` is mandatory. Write the `SIGN_OFF` workflow event. |

**Bias**: Cowork is biased towards recording what worked, what didn't work, and detailing the sum of working skills used to get from problem to solution. The goal is to build a robust set of skills that reduces completion time and increases quality of agentic tasks.

**Test-Before-Report**: Every completed item in a Final Handoff must include how it was verified (test pass, API response, command output, screenshot). Narrative-only claims are unreliable — agents can experience Taskbleed.

---

## Cowork Scripts (Quick Reference)

All scripts live in `Skills/Cowork/Scripts/`. Each conforms to `Skills/Cowork/cowork-scripts.schema.json`. Dry-run with `-DryRun` to preview before writing.

| Script | When | Output |
| :--- | :--- | :--- |
| `New-LockHeader.ps1` | Any file change | The file being modified |
| `New-CoworkStub.ps1` | Session ends, not final | `Tasks/Handoff/<date>-<topic>.md` |
| `New-FinalHandoff.ps1` | Session ends, final | `Tasks/Handoff/<date>-<topic>.md` |
| `New-SessionLog.ps1` | Session ends (always) | `Tasks/Handoff/<date>-session-log.md` |
| `New-PostHocPlan.ps1` | Code changed in Cowork | `Tasks/Review/<date>-<topic>-posthoc.md` |
| `New-ManualTask.ps1` | Human action needed | `Tasks/Manual/<date>-<topic>.md` |
| `New-MemoryEntry.ps1` | **DEPRECATED** — use `Write-NamespaceLog` instead | `docs/Memory/<repo>/<file>.md` |
| `New-CredentialRef.ps1` | Security section | stdout (include in handoff doc) |
| `New-ForkStub.ps1` | Fork session — write context-transfer document | `Tasks/Handoff/fork-stub-<date>-<topic>.md` |
| `Invoke-Fork.ps1` | Fork session — launch forked terminal | Confirmation with stub path |
