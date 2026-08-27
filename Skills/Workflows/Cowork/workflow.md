## Cowork Workflow

> **Domain redirect**: For bookkeeping, accounting, reconciliation, and receipt processing tasks, use the **Bookkeeper** workflow (`Skills/Workflows/Bookkeeping/`) instead. Say "Bookkeeper" to invoke it. This Cowork workflow is for general-purpose prototyping and non-accounting tasks.

> **MCP-first rule:** Before installing any tool or writing automation from scratch, check the fleet container inventory at `Skills/ORCHESTRATOR/Personas/Shared/environment.md § Fleet Container Inventory`. The fleet has containers for browser automation (`mcp_browserless`), web fetching (`mcp_web`), quality engineering (`mcp_aqe`), and more. Always use these existing services first — run scripts in throwaway Docker containers on `service_net` rather than installing on the host.

### Phase 0: Initialize — Read-Before-Asking
1. **Memory garbage collection**: Scan `Tasks/Handoff/` for handoff files matching the session topic. If the work is bookkeeping/accounting, move old handoffs with stale counts (lower than the current state snapshot) to `Tasks/Complete/`. See `bookkeeping/memory § Detecting Stale Handoffs`.
2. **If a handoff exists, run the Handoff Pickup Verification Protocol** (defined in `Skills/Cowork/handoff.md § Handoff Pickup Verification Protocol`) — mandatory, no exceptions:
   - a. Read the handoff
   - b. Build a verification table from every claim in the handoff, categorizing each by type (state count, file existence, blocker, tool claim, etc.)
   - c. Execute each verification against the live system
   - d. Classify each claim as Verified (✅), Stale (⚠️), Unverifiable (❓), or Erroneous (❌)
   - e. **Rewrite the handoff** with stale values corrected, resolved blockers removed, newly discovered blockers added, and a `## Verification` appendix appended. Move the original to `Tasks/Complete/`.
   - f. Block on any failed critical verification (container unreachable, API unavailable, critical file missing) — fix it or bail out. Do NOT proceed on a broken foundation.
3. Read every file the handoff references (namespace logs, skill files, data files). **For state data (counts, phase status), read the per-org `*-status.json` — NOT namespace logs.** Namespace logs are for historical context only.
4. **Cross-check the rewritten handoff against what you read in step 3** — confirm every claim you accepted now agrees with the authoritative sources.
5. Summarize your understanding to the user for confirmation, including what was stale and what was corrected
6. Only after confirmation should you ask questions

### Phase 1: Prototype & Perfect
Iterative work loop with the user. Build → test → refine.

### Phase 2: Record — What Worked, What Didn't
At session end, capture:
- Which tools/approaches succeeded? (with verification method: test pass, API response, command stdout)
- Which tools/approaches failed? (with why)
- Which skills were used? Were they adequate or did they need adaptation?
- What working pattern emerged from problem → solution?

### Phase 3: Handoff
- **Before writing handoff**: Verify the per-org `*-status.json` has accurate live counts. Archive superseded handoffs from `Tasks/Handoff/` to `Tasks/Complete/`. Keep only current state + latest handoff.
- Write a Cowork Stub to `Tasks/Handoff/` (use: `. Skills/Workflows/Cowork/Scripts/New-CoworkStub.ps1`)
- If user says "final handoff" or context is near capacity, write a Final Handoff (use: `. Skills/Workflows/Cowork/Scripts/New-FinalHandoff.ps1`)
- For Final Handoff: first write decisions via `Write-NamespaceLog -Namespace <domain> -Type MEMORY -Detail "<summary>"`, then reference the namespace log from the handoff doc
- Write a session log to `Tasks/Handoff/` (use: `. Skills/Workflows/Cowork/Scripts/New-SessionLog.ps1`)
- If code changed: write post-hoc plan to `Tasks/Review/` (use: `. Skills/Workflows/Cowork/Scripts/New-PostHocPlan.ps1`)
- If human action needed: write manual task to `Tasks/Manual/` (use: `. Skills/Workflows/Cowork/Scripts/New-ManualTask.ps1`)
- For any file change: prepend Lock Header (use: `. Skills/Cowork/Scripts/New-LockHeader.ps1`)
- Session logs are NOT handoffs — they are skill-building artifacts
- **Multi-session cowork plans** live in `Tasks/Handoff/`. When the multi-session plan is fully finished (all sessions complete and verified), move the plan file to `Tasks/Complete/`

### Phase 4: Sign Off (Final Handoff completeness check)

Before exiting, the Cowork agent double-checks the Final Handoff document is complete. Re-read the handoff doc and ask:

1. **Memory completeness** — Is there any additional memory the next agent will need that is NOT in the handoff or its referenced namespace log?
2. **Tools completeness** — Are all scripts, helpers, commands listed in "Key Files" or "Tools & Approaches"?
3. **Helpful information** — Are there upstream/downstream documents, glossary entries, ADRs to cross-link?
4. **Orphan references** — Are there files referenced in the session that are NOT cross-referenced by any other repo document?
5. **Verification evidence** — Does every completed item have a `Verification` cell?
6. **Redirects / Deprecations** — If files moved or scripts retired, is the old→new mapping recorded?

If the answer to any is "no", update the handoff/namespace log before signing off. When all six checks pass, emit:

```
=== Sign Off: cowork ===
Agent: <agent-id>
Handoff: <path-to-handoff-doc>
Namespace log: <namespace> (updated)
Verification cells: N/M populated
Orphan references: <count>
Status: Ready to Sign Off
```

…and write a `SIGN_OFF` workflow event (`Write-WorkflowEvent -Type SIGN_OFF -Detail "Ready to Sign Off" -Phase cowork`). The session ends here — do not start a new build/test cycle after signing off.
