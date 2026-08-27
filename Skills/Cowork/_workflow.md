# Cowork Workflow → Script Mapping

Maps each phase of the Cowork Workflow (AGENTS.md § Cowork Workflow)
to the script(s) in `Skills/Cowork/Scripts/` that handle it.

---

## Phase 0: Initialize — Read-Before-Asking

No scripts needed. Manual read of:
- `Tasks/Handoff/<matching-topic>.md` (cowork-stub or final-handoff)
- References from the handoff

Preparation: note which scripts you'll need for Phase 3 based on session type.

---

## Phase 1: Prototype & Perfect

Build → test → refine loop.
Scripts to use during this phase:
- `New-LockHeader.ps1` — when creating or editing files that need chain-of-possession
- `New-MemoryEntry.ps1` — to track session state incrementally

### Autonomous Information Pursuit

When the user says "fetch", "retrieve", "check", or "find" something (receipts, invoices, data), treat it as an instruction to also **extract and process** the information. Do not stop at downloading — automatically parse the data, match it to the target system, and apply it.

Example: "Fetch InterServer invoices from email" means:
1. Connect to IMAP ✓
2. Download all invoice PDFs ✓
3. Extract invoice dates and amounts from each PDF ✓
4. Rename files with proper YYYY-MM-DD dates ✓
5. Match to Zoho expenses by date + vendor ✓
6. Upload receipts to Zoho ✓
7. Report what was missing and why ✓

If any step hits a blocker, report the blocker and the partial results — do not prompt for permission to proceed to the next step.

### Build Reusable Tools (Mandatory Practice)

When writing automation during a session, build standalone, reusable tools:

- **One concern per file** — the script should do one thing well (e.g., `zoho-attach-receipts.mjs` attaches receipts only, doesn't also create expenses)
- **Installable** — save the script in the appropriate `Scripts/` directory (e.g., `Skills/Bookkeeping/Scripts/`) so it's available for future sessions
- **Self-describing** — include usage comments at the top: what it does, prerequisites, invocation example, expected output
- **Resumable** — saves state (e.g., `.zoho-attach-state.json`) with circuit breaker on first error; re-run to resume
- **Dry-run mode** — `--dry-run` flag to preview without side effects
- **Document in the skill file** — reference the new tool in the relevant skill file (e.g., `upload-expenses.md`) under "Tools & Scripts" so the next agent knows it exists

**Verify:** After writing a tool, run `--dry-run` to confirm it works, then run live with a small batch before going full scale. Update the state file or add a `--resume` flag for safe restartability.

---

## Phase 2: Record — What Worked, What Didn't

Gather data for Phase 3. No scripts directly — this phase populates
the hashtables that Phase 3 scripts consume.
Reference: `prototype-skill.md` Phase 5 section for the data structure.

---

## Phase 3: Handoff

### Session End (not final)
1. `. Skills/Intake/Scripts/New-CoworkStub.ps1 -Parameters`
2. `. Skills/Cowork/Scripts/New-SessionLog.ps1 -Parameters`

### Session End (final / context capacity)
1. Update memory file: `. Skills/Cowork/Scripts/New-MemoryEntry.ps1`
2. `. Skills/Cowork/Scripts/New-FinalHandoff.ps1 -Parameters`
3. `. Skills/Cowork/Scripts/New-SessionLog.ps1 -Parameters`

### Code Changed During Session
1. `. Skills/Cowork/Scripts/New-PostHocPlan.ps1 -Parameters`
2. Write to `Tasks/Review/` per CC step 1

### Human Action Required
1. `. Skills/Cowork/Scripts/New-ManualTask.ps1 -Parameters`
2. Write to `Tasks/Manual/`

### Credential Reference Needed (any handoff)
1. `. Skills/Cowork/Scripts/New-CredentialRef.ps1 -Parameters`
2. Pipe output into the handoff doc

### Security Note
No script writes secrets. All credential references use AWS SM key names only.
See `handoff.md` General Rules §2 and §7.
