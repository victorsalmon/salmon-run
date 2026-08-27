# Domain 4: ADR Alignment

**Purpose**: Survey existing Architecture Decision Records for drift against the current codebase, and gate any new ADR proposals through user approval before writing Coder session plans. ADRs that silently diverge from reality are documentation debt; new ADRs written directly into Coder tasks without user review bypass the architect's intent.

**Trigger**: Run this survey every audit cycle. In sequential mode, interleave with Domain 3 after its documentation checks. In parallel mode, this domain is independent and can run concurrently with any other read-only domain.

**Survey procedure**:

#### Part A — Existing ADR Drift Detection

1. **Enumerate all ADRs**: List `docs/Reference/Decisions/*.md` — note the count, numbering sequence, and any gaps (missing numbers indicate retired or consolidated records; verify those are intentional).

2. **Verify port assignments against `port-registry.json`**: For every ADR that references port numbers (0012 §4 port range, 0014 port allocation), cross-reference against `Infrastructure/port-registry.json`:
   - Do the ports still match current assignments?
   - Are any ADR-listed ports orphaned (service retired)?
   - Is the supersession chain correct (e.g., ADR 0012 §4 correctly marked superseded by ADR 0014)?

3. **Verify service/bundle/IAM references against manifests**: For each ADR that names Docker services, bundle types, IAM roles/policies, or secrets:
   - Check `Infrastructure/manifests/docker-manifest.json` for service existence
   - Check `Infrastructure/Policies/` for IAM policy document references
   - Check `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` for bundle references
   - **Findings**: Services that have been renamed, split, or removed but still documented under old names in an ADR.

4. **Verify file-path references**: For each ADR's "Related" section, check every referenced path still exists on disk. Referenced files that have been moved, renamed, or deleted are drift findings.

5. **Verify cross-reference integrity**: For each ADR's "Related" section, verify every referenced ADR number exists and its title matches:
   - Compare `git log --oneline --all -- docs/Reference/Decisions/<NNNN>-*.md` for any ADR that was superseded or deprecated — does the referencing ADR know?
   - **Findings**: Cross-references to retired ADRs without supersession notes; stale ADR titles.

6. **Check Status field accuracy**: Read the `**Status:**` line of every ADR. Flag any whose decision is known to be partially or fully superseded by a later change but still marked "Accepted". Look for:
   - Implicit supersession (a later PR or later ADR contradicts an earlier decision without updating the earlier ADR's status)
   - Decisions that were temporarily adopted but later abandoned in practice

7. **Log findings**: Log each inconsistency to the Findings Manifest via `Write-Finding`. Use `adr://<NNNN>` as the prefix in the title for per-ADR findings.

7b. **Survey tool inventory against ADR 0031 (Tool Consolidation Over Proliferation)**: Scan the codebase's script inventory to assess alignment with the four co-principles of ADR 0031 (flag-driven consolidation, shared module extraction, split-only-for-connascence, idempotency+help). This is a new check type — verifying the codebase against a specific ADR's design philosophy, not verifying the ADR document itself.

    **Scope**: All executable scripts across the project:
    - `Skills/Bookkeeping/Scripts/*.ps1` and `Skills/Bookkeeping/Scripts/*.py`
    - `Skills/Docker/*.ps1` and `Skills/Docker/Modules/*/`
    - `Orchestrator/Orchestration/*.ps1`
    - `Infrastructure/*/entrypoint*.sh`, `Infrastructure/*/*.ps1`
    - Any other directory where single-purpose scripts accumulate

    **Survey criteria**:

    a. **Consolidation candidates**: Identify groups of single-purpose scripts in the same directory whose logic could be merged into a single flag-driven script. Use the `Invoke-Zoho*` family in `Skills/Bookkeeping/Scripts/` as the canonical pattern: 4 PowerShell wrappers over 8 JS helpers, all sharing auth/session logic.

    b. **Duplicated helper logic**: Scan for repeated patterns across scripts (token refresh, CSV/JSON parsing, file validation, API auth flow). Flag any helper logic that appears in ≥ 2 files without being extracted to a shared module.

    c. **Missing documentation/help**: Check whether each script provides help output (`-?`, `-Help`, `--help`, or a documentation header block). Scripts without any discoverable help are findings.

    d. **Non-idempotent defaults**: Flag scripts whose default behaviour mutates state without a read-back assertion or guard (per ADR 0015).

    **Severity**:
    - **High**: A group of ≥ 3 single-purpose scripts with clearly overlapping scope and no consolidation parent — actionable consolidation that would meaningfully reduce agent discovery surface
    - **Medium**: Shared helper logic duplicated across ≥ 2 scripts without module extraction
    - **Low**: A single-purpose script that exists alongside a consolidation parent already (redundant but not harmful)
    - **Info**: Missing help output on an otherwise well-structured script

    **Log findings**: Log each finding to the Findings Manifest via `Write-Finding`. Use `adr://0031` as the prefix in the title, including the file paths and which criterion (a/b/c/d) was violated.

    **Coder session plans**: Plan generation for actionable findings is handled by Phase B consolidation, which groups findings by file path (ADR files) to produce one plan per affected ADR. Consolidation candidates (severity High) always get a session plan. Medium and Low findings get a plan only if remediation is unambiguous. Info findings are logged but typically do not generate plans.

8. **Log findings for drift remediation**: Log each drift discrepancy as a finding to the Findings Manifest via `Write-Finding`. Include the ADR number, the type of drift (outdated/violates/ambiguous/stale), and the remediation direction in the detail field. Phase B consolidation groups findings by ADR for plan generation.

   - **ADR outdated (codebase correct)**: `Write-Finding -Domain domain-5 -Severity <severity> -Title "[adr://<NNNN>] ADR outdated — <brief description>" -Detail "ADR is documentation debt, not a code defect. See remediation direction below." -Files @("docs/Reference/Decisions/<NNNN>-*.md")`
   - **Codebase violates ADR (ADR correct)**: `Write-Finding -Domain domain-5 -Severity <severity> -Title "[adr://<NNNN>] Codebase violates ADR — <brief description>" -Detail "ADR intent correct; codebase needs alignment." -Files @("<file(s)-needing-change>")`
   - **Ambiguous or superseded**: `Write-Finding -Domain domain-5 -Severity <severity> -Title "[adr://<NNNN>] ADR ambiguous or superseded — <brief description>" -Detail "Both ADR status and codebase need updating." -Files @("docs/Reference/Decisions/<NNNN>-*.md", "<file(s)-needing-change>")`
   - **Cross-reference stale**: `Write-Finding -Domain domain-5 -Severity <severity> -Title "[adr://<NNNN>] ADR cross-reference stale — <brief description>" -Detail "Referencing ADR needs updated Related section." -Files @("docs/Reference/Decisions/<NNNN>-*.md")`

   > **Note**: Drift remediation plan generation is handled by Phase B consolidation, which groups findings by file path (ADR files) to produce one plan per affected ADR.

   **Exception — no fix needed**: If the finding severity is `"info"` (cosmetic, no reader confusion risk) and no actionable change improves clarity, skip the finding and note in the audit log: `"ADR <NNNN> — info-level finding, no finding logged"`.

#### Part B — New ADR User-Vetting Gate

When any audit domain (1–5) uncovers a change that should be formalised as a new ADR — or when the Auditor determines that implementing a session plan requires an architectural decision that should be recorded — follow this protocol:

1. **Draft the proposed ADR decision**: Before writing any Coder session plans, produce a structured proposal inline in the audit conversation containing:
   ```
   ### Proposed ADR <NNNN> — <Title>

   **Context**: Why is this decision needed? What problem does it solve?
   **Proposal**: Briefly state the recommended approach.
   **Alternatives considered**: List 2–3 alternatives with trade-offs (reference `Skills/Planner/consider-alternatives.md` rubric if architectural).
   **Impact**: Which existing ADRs, manifests, scripts, or services would this affect?
   ```
   Keep it to 3–5 sentences per section — enough for the user to evaluate, not a full ADR document.

2. **Present to user for approval**: Ask the user explicitly — do not proceed to Coder session plans without confirmation. Format:
   ```
   **ADR gate**: The audit found [situation requiring ADR]. Proposed ADR <NNNN> — <Title> above recommends [approach]. Do you approve this direction so I can write Coder session plans?
   ```
   Include an explicit rejection path: if the user declines, log the rejected proposal to the audit trail and stop. Do not write plans.

3. **On approval, log finding**: Log an approved ADR finding to the Findings Manifest:
   ```powershell
   Write-Finding -Domain domain-5 -Severity info -BlastRadius <assessed> -Title "New ADR <NNNN>: <title> (user-approved)" -Detail "..." -Files @("docs/Reference/Decisions/<NNNN>-<title>.md")
   ```
   Phase B generates the session plan that drafts the ADR document and implements any code changes.

4. **On rejection, log**: Write a finding to the audit log with domain `"domain-5"`, severity `"info"`, detail `"ADR <NNNN> proposal rejected by user — no action taken"`.

**Scoring** (Part A findings):
- **High**: An ADR Status is "Accepted" but the decision is materially violated by current codebase or infrastructure — deployers relying on the ADR will make incorrect assumptions
- **Medium**: A file path or cross-reference in an ADR is stale — the ADR's intent is still valid but its navigability is broken
- **Low**: A minor port or naming discrepancy that doesn't affect understanding of the decision
- **Info** (Part B): A proposed ADR was gated — either approved (proceed) or rejected (logged)
