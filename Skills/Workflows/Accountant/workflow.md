## Accountant Workflow

> **MCP-first rule:** Before installing any tool or writing automation from scratch, check the fleet container inventory at `Skills/ORCHESTRATOR/Personas/Shared/environment.md § Fleet Container Inventory`. The fleet has containers for browser automation (`mcp_browserless`), web fetching (`mcp_web`), quality engineering (`mcp_aqe`), and more. Always use these existing services first — run scripts in throwaway Docker containers on `service_net` rather than installing on the host.

> **Zoho automation prerequisites:** Before any Zoho Books API work, ensure the Zoho credentials are available. Use `resolve-zoho-creds.mjs` which reads credentials from the proxy container's Docker secrets bundle (`FRAD_api-proxy` must be running), or falls back to AWS Secrets Manager directly when Docker is unavailable. See `tools.md § Credential resolution` for usage.

### Phase 0 — Initialize (Verify, Then Trust)

**Core principle**: No handoff claim, state snapshot, or status file is accepted without independent verification. Every count, phase status, and blocker assertion must be checked against the live system before proceeding. Stale context compounds — verify early, verify thoroughly.

1. **Memory garbage collection**: Before reading any state, archive stale handoffs from `Tasks/Handoff/`:
   - List handoff files in `Tasks/Handoff/` matching `*bookkeeping*`, `*intersite*`, `*mc6258*`, `*receipt*`, `*accountant*`
   - For each, check if its state counts are lower than the current snapshot or superseded by a later handoff
   - Move stale handoffs to `Tasks/Complete/` — see `accountant/memory § Detecting Stale Handoffs`

2. **If a handoff exists in `Tasks/Handoff/`**, run the **Handoff Pickup Verification Protocol** (defined in `Skills/Cowork/handoff.md § Handoff Pickup Verification Protocol`) — mandatory, no exceptions:
   - a. Read the handoff
   - b. Build a verification table from every claim — state counts, file paths, blocker assertions, tool references
   - c. Execute each verification against the live system
   - d. Classify each claim as Verified (✅), Stale (⚠️), Unverifiable (❓), or Erroneous (❌)
   - e. **Rewrite the handoff** with stale values corrected, resolved blockers removed, and a `## Verification` appendix appended. Move the original to `Tasks/Complete/`.
   - f. Block on any failed critical verification — do NOT proceed with a broken foundation

3. Read the **live state snapshot**: `{repo}/docs/Memory/mem-{entity}-bookkeeping-state.md` (resolve `{repo}` via `_project-map.json`)
   - Note the `Last verified` timestamp
   - Regardless of age, **verify snapshot freshness**: Run `node Skills/Accountant/Scripts/categorization/_list-unattached.mjs` (or equivalent) against the live system to get real current counts.
   - If live counts differ from snapshot, flag staleness and rewrite the snapshot **before** treating any count as accurate.

4. **Cross-check the verified handoff against the snapshot** — confirm every claim now agrees with the authoritative sources. Any discrepancy between the rewritten handoff and the snapshot means one of the verifications was incomplete.

5. Read `{repo}/docs/Memory/mem-accountant-sessions.md` for historical context (what worked/didn't, protocol changes). Read newest entries first. Resolve `{repo}` via `_project-map.json`.

6. Read `Skills/Accountant/_accountant.md` <!-- doc-lint: exempt --> for master pipeline overview and universal rules

7. **Assess current pipeline phase** by checking milestone completion state files (live, not cached):
   - Books track phases:
     - Phase 0 (Preparation): `accountant/books/preparation-complete` — all source data gathered
     - Phase 1 (Local Reconciliation): `accountant/books/local-reconciliation-complete` — annual CSVs match monthly PDFs
     - Phase 2 (Remote Annual): `accountant/books/remote-annual-complete` — remote mirrors local
      - Phase 3 (Monthly): `accountant/books/reconcile-remote` — per-statement reconciliation
      - Phase 4 (Confirm Balances): `accountant/books/confirm-account-balances` — year-end cleanup
    - Receipt track phases:
      - All phases: `accountant/processing/receipt-status` — consolidated completion check

8. Summarize verified state and planned next actions to user for confirmation, including what was stale and corrected

### Phase 1 — Execute Current Phase

Work on the current bookkeeping phase, following the appropriate sub-skill(s):

- `accountant/ingest/ingest-statement` — consolidated data gathering (email, CSVs, PDFs, validation)
- `accountant/ingest/ingest-images` — extract receipt images and run gap analysis
- `accountant/processing/find-missing` — retrieve missing receipts from vendors
- `accountant/books/reconciliation/pre-recon/categorization/categorize` — consolidated categorization (income, expense, transactions)
- `accountant/books/reconciliation/pre-recon/categorization/enrichment` — enrichment + category assignment
- `accountant/processing/enrich` — DEPRECATED — use `accountant/books/reconciliation/pre-recon/categorization/enrichment`
- `accountant/processing/upload` — upload receipts to remote books
- `accountant/books/reconcile-remote` — consolidated remote reconciliation (monthly or annual)
- `accountant/books/confirm-account-balances` — year-end cleanup
- `accountant/zoho/expenses` — Zoho expense operations (categorize, ingest, reclassify, upload)
- `accountant/zoho/reconciliation` — Zoho bank and CC reconciliation
- `accountant/zoho/auth-ref` — Zoho auth, account IDs, known issues

**Build Reusable Tools** (from Cowork `_workflow.md`):
- One concern per file
- Dry-run mode before mutating operations
- Resumable (idempotent) design
- Self-describing parameters
- Installable in `Skills/Accountant/Scripts/`

**Universal rules** (from `Skills/Accountant/_accountant.md` <!-- doc-lint: exempt -->):
1. READ before WRITE — check existing remote state before creating
2. Circuit break on first API error, fix root cause before retrying
3. CC payments are transfers — use `POST /banktransactions` with `transaction_type: transfer_fund`
4. Cache OAuth token — one per session, reuse
5. Sweep CR+DR duplicates after every `POST /expenses` batch
6. Sidecar CSVs are authoritative for transaction direction
7. Receipts over $5 must have a receipt or qualify for exemption
8. AWS SSO auth when token expired

### Phase 2 — Verify Milestone

Before moving to the next phase, verify the current phase's completion rubric:

- `accountant/books/preparation-complete` — all source data gathered and reconciled
- `accountant/books/local-reconciliation-complete` — annual CSVs match monthly PDFs
- `accountant/books/remote-annual-complete` — remote mirrors local
- `accountant/processing/receipt-status` — consolidated pipeline completion check
- `accountant/milestone/ready-for-manual-review` — 4-point rubric
- `accountant/milestone/ready-for-accountant` — final handoff check

**Memory GC on phase advancement**: Run external verification to get real current counts (e.g. `categorization/_list-unattached.mjs`). Rewrite the state snapshot (`mem-{entity}-bookkeeping-state.md`) with: new counts, verified status, today's date. Log the advancement in the session log.

If rubric does not pass, return to Phase 1. If rubric passes, proceed to Phase 3.

### Phase 3 — Record

Record what worked and what didn't:
- Which tools/approaches succeeded? (with verification method: test pass, API response, command stdout)
- Which tools/approaches failed? (with why)
- API footprint: number of calls, errors, rate limit headroom
- Utility scripts created or modified
- Which skills were used? Were they adequate or did they need adaptation?
- What working pattern emerged from problem → solution?

Record pipeline state advancement in `mem-accountant-intersite.md`.

### Phase 4 — Handoff

Before writing handoff artifacts:

1. **Rewrite the state snapshot** (`mem-{entity}-bookkeeping-state.md`) with verified live counts — this is the canonical handoff artifact
2. **Archive superseded handoffs**: Move old handoff files from `Tasks/Handoff/` to `Tasks/Complete/` if their data is older than the current snapshot
3. **Keep only**: The current state snapshot, the current session log entry, and the latest handoff that references them
Write handoff artifacts using `Skills/Workflows/Cowork/Scripts/`:

- Write a Cowork Stub or Final Handoff to `Tasks/Handoff/` (use: `. Skills/Workflows/Cowork/Scripts/New-CoworkStub.ps1` or `New-FinalHandoff.ps1`)
- Write a session log to `Tasks/Handoff/` (use: `. Skills/Workflows/Cowork/Scripts/New-SessionLog.ps1`)
- If code changed: write post-hoc plan to `Tasks/Review/` (use: `. Skills/Workflows/Cowork/Scripts/New-PostHocPlan.ps1`)
- If human action needed: write manual task to `Tasks/Manual/` (use: `. Skills/Workflows/Cowork/Scripts/New-ManualTask.ps1`)
- For any file change: prepend Lock Header (use: `. Skills/Cowork/Scripts/New-LockHeader.ps1`)

Include pipeline state snapshot (current phase, next phase, verified milestones) in the handoff doc. Include credential references via `New-CredentialRef.ps1`.

### Phase 5 — Sign Off (Milestone & Handoff Completeness Check)

Before exiting, double-check:

1. **Memory completeness** — Is there any additional memory the next agent will need that is NOT in the handoff or its referenced memory file?
2. **Tools completeness** — Are all scripts, helpers, commands listed in "Key Files" or "Tools & Approaches"?
3. **Helpful information** — Are there upstream/downstream documents, glossary entries, ADRs to cross-link?
4. **Orphan references** — Are there files referenced in the session that are NOT cross-referenced by any other repo document?
5. **Verification evidence** — Does every completed item have a `Verification` cell?
6. **Redirects / Deprecations** — If files moved or scripts retired, is the old→new mapping recorded?
7. **Milestone rubric** — Verify the current phase's milestone rubric passes (re-check `accountant/*/*-complete.md` if applicable)

If the answer to any is "no", update the handoff/memory file before signing off. When all checks pass, emit:

```
=== Sign Off: accountant ===
Agent: <agent-id>
Handoff: <path-to-handoff-doc>
Memory file: <path-to-memory-file> (updated)
Pipeline phase: <current-phase> → <next-phase>
Verification cells: N/M populated
Orphan references: <count>
Status: Ready to Sign Off
```

Write a `SIGN_OFF` workflow event (`Write-WorkflowEvent -Type SIGN_OFF -Detail "Ready to Sign Off" -Phase accountant`). The session ends here — do not start a new build/test cycle after signing off.
