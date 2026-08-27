# Compliance Audit — Regulatory & Data-Sovereignty Survey

**Part of**: Audit mode (`Skills/Auditor/SKILL.md`)
**Siblings**: Alignment Audit (`alignment-audit.md`) — structural drift survey | Architectural Audit (`architectural-audit.md`) — security-first architecture scan | Functional Audit (`functional-audit.md`) — operational reliability survey
**Trigger**: User says "Compliance Audit" or `/audit compliance`
**Purpose**: Assess the target repo's regulatory and data-sovereignty posture against confirmed-applicable standards. Report every compliant control and every non-compliant gap with a ranked menu of remediation options. Confirm standard applicability interactively, persist the decision to .compliance-audit.yml, then support headless re-runs.

---

## Why This Exists

The other three Audit-mode tracks survey *internal* qualities of the codebase:

- **Alignment Audit** surveys *structural drift* — pattern compliance, ADR alignment, glossary consistency.
- **Functional Audit** surveys *operational reliability* — will each script actually run in production?
- **Architectural Audit** surveys *security-by-design* — trust zones, traceability, attack surface.

The Compliance Audit surveys the repo's posture against **external regulatory and sovereignty obligations**: PIPEDA, SOC 2, ISO/IEC 27001:2022, HIPAA, GDPR, and Canadian data residency. These obligations come from law, contracts, and certification programs — not from internal conventions — so the audit's applicability questions ("does this standard even apply to this repo?") must be answered deliberately, per repo, and persisted.

Three design choices distinguish this track:

1. **Interactive applicability gate + config file**. A Compliance Audit runs *interactively* the first time to confirm which standards apply, writes `.compliance-audit.yml` at the repo root, and thereafter runs **headless** by reading that config. This turns an interactive judgment into an automatable, re-runnable audit.
2. **Reuse-first policy**. If the target repo ships its own static compliance engine (currents-bookkeeping's `scripts/compliance-audit/` family), the Compliance Audit **runs the native engine and ingests its findings** rather than duplicating checks. Net-new checks are written only where no native engine exists (Canadian data sovereignty, HIPAA, GDPR).
3. **Options-menu findings**. Every non-compliant finding is reported with a ranked menu of ≥2 remediation options (effort + impact per option), so the plan consumer sees "what all the options are", not a single prescribed fix.

---

## Standards Overview

| # | Standard | Scope | Applicability test | Native engine? |
|---|----------|-------|--------------------|----------------|
| 1 | Canadian data sovereignty | All data stores + processing remain in `ca-central-1`; cross-border transfers documented | Any repo storing/processing data in AWS | No (doc/ADR only — e.g. `C:/Repos/currents-bookkeeping/docs/business-reference/0045-pipeda-data-sovereignty.md`) |
| 2 | SOC 2 | Access control, auth, encryption, monitoring, change mgmt, incident response (CC6.1–8.1) | Any service handling customer data | currents-bookkeeping `soc2.mjs` (SOC2-CC6.1/6.2/6.3/7.1/7.2/8.1) |
| 3 | PIPEDA | 10 fair-information principles, breach notification (s.10.9), retention | Any repo handling personal info of Canadian individuals | currents-bookkeeping `pipeda.mjs` (PIPEDA-01..07,11) |
| 4 | ISO/IEC 27001:2022 | Annex A controls (A.5.15/5.17/6.3/8.5/8.15/8.16), ICT readiness (A.5.30) | Any repo seeking/maintaining ISMS certification | currents-bookkeeping `iso27001.mjs` |
| 5 | HIPAA | PHI encryption, access controls, audit controls, BAAs, breach notification (≤60 days) | Handles PHI OR is a covered entity / business associate | None (new checks) |
| 6 | GDPR | Lawful basis, data-subject rights, DPAs, 72-hr breach notice, SCCs | Processes EU/EEA data-subject data | None (new checks) |

---

## Config file contract

The config file is the mechanism that turns an interactive run into an automatable one. Path: **`.compliance-audit.yml` at the repo root of the audited repo** (NOT salmon-orchestrator). It is:

- **Written** by the interactive User Gate (Phase B) after standard confirmation.
- **Required** by headless mode — the slash command exits 1 with a clear message if it is absent.
- **The canonical schema spec** — `ConvertFrom-ComplianceConfig.ps1` and `Write-ComplianceAuditConfig.ps1` (complscripts-0) implement exactly this; field names and allowed values below are the contract.

### Schema (canonical — downstream scripts must match exactly)

```yaml
version: 1
target_repo: currents-bookkeeping          # leaf name of the repo this config governs
region_required: ca-central-1              # default ca-central-1; the data-sovereignty check enforces this
standards:
  canadian_data_sovereignty:
    status: required                       # allowed: required | not_applicable
    rationale: "Client financial data must stay in Canada (ADR-0045)."
  pipeda:
    status: required
    rationale: "Handles client financial PII."
  soc2:
    status: required
  iso_27001:
    status: required
  hipaa:
    status: not_applicable
    rationale: "No PHI; no covered entities."
  gdpr:
    status: not_applicable
    rationale: "No EU/EEA data subjects; Canada-only product."
run_native_engine: true                    # default true; run the repo's own compliance engine if detected
last_confirmed: 2026-08-09                 # ISO date; stamped by the interactive gate
reconfirm_after_days: 365                  # default 365; headless runs older than this warn that reconfirmation is due
```

### Rules

- `status` MUST be `required` or `not_applicable`. Any other value is a config error.
- `rationale` is **REQUIRED** when `status: not_applicable` — a standard marked N/A with no rationale is itself a finding (the auditor must be able to re-derive why it was excluded).
- `version` is currently `1`. Future versions bump it; parsers must reject unknown versions.
- Unknown top-level keys are **ignored** (forward-compat).
- The `standards` map uses the six canonical keys: `canadian_data_sovereignty`, `pipeda`, `soc2`, `iso_27001`, `hipaa`, `gdpr`. A missing standard key defaults to `required` with an empty rationale — the interactive gate always writes all six.

---

## Modes

| Mode | When | Behaviour |
|------|------|-----------|
| **Interactive** | Config absent OR `-Interactive` flag | Full survey (Phases 0 → A → B → C). The User Gate confirms each standard and writes/merges `.compliance-audit.yml`. |
| **Headless** | Config present + slash command | Read config, skip `not_applicable` standards, auto-generate plans (Phase A → C, no Phase B). |

**Banner contract**: the `/audit-compliance` template (complwire-0) carries the same **UNATTENDED MODE** banner as `/audit-align` and the other audit slash commands, so agents recognize whether they may stop and ask questions.

---

## Phase 0 — Repo Orientation & Native Engine Detection

1. Record `$sessionStart`, set agent ID, write PID + heartbeat (per `workflow-primitives.md`).
2. Load this file (`compliance-audit.md`) for methodology.
3. **Detect stack**: package.json scripts, IaC directory (CDK/Terraform/SAM), data-store inventory.
4. **Detect native compliance engine** — check in order:
   - `Test-Path scripts/compliance-audit/audit.mjs` (currents-bookkeeping family)
   - an npm script named `audit` or `audit:compliance` in package.json
   - `scripts/compliance-audit.mjs` (upscale-havens family)
   Record the detection result (engine path + framework IDs exposed).
5. **Run the compliance scan**:
   ```powershell
   Invoke-ComplianceScan.ps1 -RepoRoot <target-repo> -OutputFile "Tasks/Logs/compliance-scan-$(Get-Date -Format yyyy-MM-dd).json"
   ```
   (provided by complscripts-0) — this performs the grep-based checks (region scan, cross-border service inventory, doc-vs-IaC residency cross-check).
6. **Run the native engine** if detected AND `run_native_engine: true`:
   ```powershell
   npm run audit -- --json --quiet
   # or
   node scripts/compliance-audit.mjs --json
   ```
   Capture stdout JSON + exit code. **Exit code policy** (match `audit.mjs`): `0` = no critical/high findings, `1` = ≥1 critical/high finding, `2` = engine error (report as an audit-log finding, not a compliance finding).
7. **Tier-classify the repo's data sensitivity**: PII? PHI? financial? EU data subjects? This classification informs the applicability answers and the severity of findings.

---

## Phase A — Per-Standard Survey

For each of the 6 standards (skipped if headless AND config marks it `not_applicable`), run the standard's control checklist (Tasks 4–9 sections below) against the repo. Log every finding via:

```powershell
. ./Write-DraftPlan.ps1
Write-DraftPlan -Domain "compliance-<standard>" -Severity <severity> -BlastRadius <blast> `
    -Title "<control-id>: <brief>" -Detail "<compliant|non-compliant> — <evidence>" `
    -Files @("<affected-file-path>")
```

Drafts land in `Tasks/Code/Drafts/compliance-<standard>/`. One draft per control result; every non-compliant draft must carry the standard's remediation options (see Finding Format).

---

## Standard 1 — Canadian Data Sovereignty

### What it is

All data stores and processing must remain in `ca-central-1` per `C:\Repos\currents-bookkeeping\docs\business-reference\0045-pipeda-data-sovereignty.md` (ADR-0045). Cross-border transfers are permitted only with a documented, sanctioned exception (QBO, Stripe, and similar US-hosted services are the known examples).

### Applicability test

Any repo that stores or processes data in AWS (has CDK/TF/SAM IaC). Applies unless the repo stores no data at all.

### Control checklist

- **SOV-1** — grep all IaC (`backend/cdk/**/*.ts`, `**/*.tf`, `**/template.yaml`) for AWS region strings; every data-store or compute region MUST be `ca-central-1`. Any other region is a finding. *(This is the check `Invoke-ComplianceScan.ps1` performs.)*
- **SOV-2** — for every foreign/US service invoked (QBO, Stripe, Firecrawl, OpenRouter, etc.), verify a sanctioned-exception doc exists (ADR-0045-style 6-criteria assessment). An undocumented cross-border transfer is a finding.
- **SOV-3** — data residency claims in docs must match IaC reality (no doc says "Canada-only" while code deploys to `us-east-1`).

### Compliant signals

- All IaC regions are `ca-central-1`.
- Every foreign service has a documented, sanctioned exception.

### Non-compliant signals

- Any `us-east-1` / `us-west-2` / `eu-*` region in a data path.
- Foreign service with no exception doc.

### Remediation options menu

1. **Move the resource to `ca-central-1`** (effort: medium; impact: full compliance; preferred when a Canadian equivalent exists).
2. **Document a sanctioned exception** via the ADR-0045 6-criteria assessment (effort: low; impact: acceptable-with-justification; use when no Canadian alternative exists, e.g. QBO/Stripe).
3. **Replace the service with a Canadian-hosted alternative** (effort: high; impact: full compliance; use when alternatives exist and the workload allows migration).

---

## Standard 2 — SOC 2

### What it is

AICPA trust-services framework. This audit covers the security category controls relevant to a software repo: logical access, authentication, encryption (CC6.1/6.2/6.3), system monitoring + anomaly detection (CC7.1/7.2), and change management (CC8.1).

### Applicability test

Any service handling customer data.

### Control checklist (native check IDs)

- CC6.1 — logical and physical access controls: least privilege, reviews.
- CC6.2 — user access provisioning/de-provisioning.
- CC6.3 — authentication (MFA where applicable) and encryption of credentials in transit.
- CC7.1 — system monitoring for anomalies.
- CC7.2 — incident response / anomaly escalation.
- CC8.1 — change management: authorization, testing, approval.

Native: `soc2.mjs`.

### Compliant / non-compliant signals

- **Compliant**: native engine reports no CC6/CC7/CC8 failures; access control and change-management evidence exists in code/config.
- **Non-compliant**: any CC6.1–8.1 failure from `soc2.mjs`; missing auth on admin paths; no change-management gate in the deploy pipeline.

### Remediation options menu

1. **Fix the control in code** — e.g. add MFA, enforce least-privilege IAM, add deploy approval gate (effort: medium; impact: full compliance for that control).
2. **Document a compensating control** — formalize an existing process (review cadence, manual sign-off) into the control evidence (effort: low; impact: evidence-complete).
3. **Accept the gap with a signed risk acceptance** (effort: low; impact: non-compliant but tracked; only for low-severity gaps).

---

## Standard 3 — PIPEDA

### What it is

Canada's federal private-sector privacy law: 10 fair-information principles, mandatory breach reporting (s.10.9), and retention limits (CRA 7-year financial-record retention for bookkeeping data).

### Applicability test

Any repo handling personal information of Canadian individuals.

### Control checklist (native check IDs)

- PIPEDA-01..07 — the fair-information principles: accountability, identifying purposes, consent, limiting collection, limiting use/disclosure/retention, accuracy, safeguards.
- PIPEDA-11 — openness / individual access.
- **s.10.9 breach-notification-must-never-be-automated** — the rule that breach notification to the Privacy Commissioner and affected individuals must be a deliberate, human-reviewed workflow. Cite the load-bearing `sendDeletion*` vs `sendBreach*` naming convention from currents-bookkeeping: an automated path named/behaving like `sendBreach*` is itself a PIPEDA finding.
- **CRA 7-year retention** — financial records retained per CRA schedule; enforcement must be in code where records are deleted.

Native: `pipeda.mjs`.

### Compliant / non-compliant signals

- **Compliant**: native engine reports no failures; deletion vs breach flows are distinctly named and never conflated; retention window enforced in code.
- **Non-compliant**: any PIPEDA-01..07/11 failure; a `sendBreach*` path that fires without human review; deletion logic that can drop financial records before 7 years.

### Remediation options menu

1. **Fix the check failure in code** — consent capture, retention enforcement, access path (effort: medium; impact: full compliance for that principle).
2. **Split/rename the automated flows** — ensure `sendDeletion*` (automated) and `sendBreach*` (human-gated) can never collide (effort: low; impact: closes the s.10.9 hazard).
3. **Document a manual procedure** for the automated-ineligible step (effort: low; impact: acceptable-with-justification).

---

## Standard 4 — ISO/IEC 27001:2022

### What it is

International ISMS standard. This audit covers the repo-relevant Annex A controls: A.5.15 (access control), A.5.17 (asset management), A.6.3 (NDA), A.8.5 (secure authentication), A.8.15 (logging), A.8.16 (monitoring), plus A.5.30 ICT readiness for business continuity (cite `currents-bookkeeping/docs/ict-readiness-runbook.md` RPO/RTO).

### Applicability test

Any repo seeking or maintaining ISMS certification (or intending to).

### Control checklist (native check IDs)

- A.5.15 — access control policy and enforcement.
- A.5.17 — asset inventory and ownership.
- A.6.3 — confidentiality/NDA obligations.
- A.8.5 — secure authentication (MFA, credential hygiene).
- A.8.15 — logging of privileged access and security-relevant events.
- A.8.16 — monitoring of logs/alerts.
- A.5.30 — ICT readiness: documented RPO/RTO and tested recovery (cite the ICT readiness runbook).

Native: `iso27001.mjs`.

### Compliant / non-compliant signals

- **Compliant**: native engine reports no failures; logging and monitoring wired; ICT readiness runbook exists with concrete RPO/RTO.
- **Non-compliant**: any A.* failure; no asset inventory; missing security logging; ICT readiness doc absent or RPO/RTO undefined.

### Remediation options menu

1. **Implement the control** — logging pipeline, monitoring alert, access policy (effort: medium/high; impact: full compliance for that control).
2. **Create the evidence artifact** — asset inventory, access-control policy doc, readiness runbook (effort: low; impact: certifiable evidence).
3. **Defer with a gap-acceptance record** in the ISMS risk register (effort: low; impact: tracked gap).

---

## Standard 5 — HIPAA

### What it is

US health-data regulation. This audit covers PHI protections: encryption, access controls, audit controls, business associate agreements, minimum necessary disclosure, and breach notification (≤60 days, never fully automated).

### Applicability test

Handles Protected Health Information (PHI), OR is a HIPAA covered entity, OR is a business associate of one.

### Control checklist (new IDs)

- **HIPAA-1** — PHI encrypted at rest AND in transit (45 CFR §164.312(a)(2)(iv) and (e)(2)(ii)). Grep for encryption on PHI fields/columns/storage.
- **HIPAA-2** — unique user identification & access controls (§164.312(a)(2)(i)) — every PHI access tied to a unique authenticated identity.
- **HIPAA-3** — audit controls (§164.312(b)) — PHI access/disposal logged.
- **HIPAA-4** — Business Associate Agreements (BAAs) executed with every subprocessor that touches PHI.
- **HIPAA-5** — minimum-necessary disclosure (§164.502(b)).
- **HIPAA-6** — breach notification workflow (§164.400–414), ≤60 days, never fully automated.

### Compliant / non-compliant signals

- **Compliant**: no PHI in the repo, or all six controls present and evidenced.
- **Non-compliant**: PHI unencrypted; shared/anonymous access; no PHI audit log; subprocessors without BAAs; automated breach notification.

### Remediation options menu

1. **Encrypt PHI fields/storage** and enforce per-user access (effort: high; impact: full compliance).
2. **Execute BAAs** with every PHI-touching subprocessor (effort: low; impact: full compliance for HIPAA-4).
3. **Implement PHI audit logging + the human-gated breach workflow** (effort: medium; impact: full compliance for HIPAA-3/6).
4. **Formally confirm `not_applicable`** — document no PHI, no covered entity/BA status, with rationale (effort: low; impact: removes the standard from scope).

---

## Standard 6 — GDPR

### What it is

EU/EEA data-protection regulation. This audit covers lawful processing, data-subject rights, processor agreements, records of processing, breach notice, DPO, privacy by design, and transfer safeguards.

### Applicability test

Processes personal data of EU/EEA data subjects — including via a `.eu` presence, EU customers, or EU monitoring of behaviour.

### Control checklist (new IDs)

- **GDPR-1** — lawful basis + consent capture for each processing purpose (Art. 6).
- **GDPR-2** — data-subject rights: access, rectification, erasure, portability, objection (Arts. 15–21). A DSAR handler must exist.
- **GDPR-3** — Data Processing Agreements (DPAs) with every processor (Art. 28).
- **GDPR-4** — Records of Processing Activities (Art. 30).
- **GDPR-5** — 72-hour breach notification to the supervisory authority (Art. 33).
- **GDPR-6** — Data Protection Officer designated if required (Art. 37).
- **GDPR-7** — privacy-by-design and by-default (Art. 25).
- **GDPR-8** — Standard Contractual Clauses (or equivalent) for any non-EU transfer (Art. 46).

### Compliant / non-compliant signals

- **Compliant**: no EU/EEA data subjects, or all eight controls present.
- **Non-compliant**: EU data processed without lawful basis; no DSAR handler; no DPAs; no RoPA; automated breach path without 72-hour human workflow.

### Remediation options menu

1. **Implement the missing control** — consent capture, DSAR handler, DPAs, RoPA (effort: medium/high; impact: full compliance for that article).
2. **Add SCCs / transfer safeguards** for any non-EU transfer (effort: medium; impact: GDPR-8 compliance).
3. **Formally confirm `not_applicable`** — document no EU/EEA data subjects (the expected outcome for Canada-only repos), with rationale (effort: low; impact: removes the standard from scope).

---

### Applicability-first framing (HIPAA + GDPR)

Both net-new standards are most likely **not applicable** to this ecosystem's repos (Canada-only, no PHI). The right answer for such a repo is `not_applicable` with a written rationale — NOT building controls for a standard that doesn't apply. The interactive gate exists precisely to confirm this; a repo that builds HIPAA/GDPR controls without an applicability basis has mis-scoped its compliance program.

---

## Native-engine ingestion (SOC 2 / PIPEDA / ISO 27001)

When the native engine is present AND `run_native_engine: true`, the Compliance Audit **ingests the native findings** and does NOT re-derive them. Map the native `FRAMEWORKS` enum (`types.mjs`) to this track's standard keys:

| Native framework | Compliance standard |
|------------------|---------------------|
| `PIPEDA` | `pipeda` |
| `SOC2` | `soc2` |
| `ISO 27001` | `iso_27001` |
| `CRA Bookkeeping` | `canadian_data_sovereignty` (retention-related controls) / note as adjacent |
| `Best Practice` | Advisory — surfaced as `Low`-severity notes, not standard findings |

When the native engine is **absent**, the auditor performs a model-driven assessment against the same control IDs (SOV-*, CC6.1–8.1, PIPEDA-01..07/11, A.5.15–8.16, HIPAA-1..6, GDPR-1..8).

---

## Phase B — Interactive Standard Confirmation Gate

*(Interactive mode only; headless mode skips this phase entirely.)*

For each of the 6 standards, present to the user:

- **Applicability evidence** — the tier-classification result + the standard's applicability test.
- **Compliant findings** — controls that passed.
- **Non-compliant findings** — controls that failed, each with its remediation options menu.

Ask the user to confirm `required | not_applicable` for the standard and capture a rationale (**REQUIRED** for `not_applicable`). After all six standards are confirmed, call:

```powershell
Write-ComplianceAuditConfig.ps1 -RepoRoot <target-repo> -Standards <confirmed-map> -Force
```

(complscripts-0) to write/merge `.compliance-audit.yml` at the repo root, stamping `last_confirmed: <today>`.

---

## Phase C — Consolidation and Plan Generation

1. Group drafts by standard (from `Tasks/Code/Drafts/compliance-<standard>/`).
2. Generate session plans with namespaces:
   - `compliance-data-sovereignty-`
   - `compliance-soc2-`
   - `compliance-pipeda-`
   - `compliance-iso27001-`
   - `compliance-hipaa-`
   - `compliance-gdpr-`
3. **Every non-compliant finding's plan MUST embed the full remediation-options menu in its Overview** (per the user's "what all the options are" requirement) — the plan consumer must see the ranked options without opening this methodology doc.
4. Follow `alignment-audit.md § Phase B` for consolidation mechanics (user gate → Write-SessionPlan → namespace topology verification).
5. Output to `Tasks/Code/` (or `~/.salmon/Tasks/Code/` in multi-repo Complete-Audit mode).

---

## Finding Format

Mirrors `architectural-audit.md` Finding Format with one addition — an `**Options**:` block:

```markdown
**Options**:
1. <option> (effort: <low|medium|high>, impact: <description>)
2. <option> (effort: ..., impact: ...)
```

≥2 options are REQUIRED for any non-compliant finding. Compliant findings need no options block.

---

## Severity Scoring

| Severity | Definition |
|----------|-----------|
| **Critical** | Active regulatory breach; unprotected PII/PHI at rest or in transit; data left the sovereignty zone without a sanctioned exception; missing mandatory breach workflow. |
| **High** | A required control is missing entirely (no encryption, no access logging, no DSAR handler, no BAAs/DPAs). |
| **Medium** | Partial control or documentation gap (control exists but is undocumented; retention window not enforced in code). |
| **Low** | Advisory / hardening suggestion. |

---

## Completion Checklist

1. **All applicable standards surveyed** — every standard not marked `not_applicable` in config has a completed Phase A pass.
2. **Every non-compliant finding has ≥2 options** — no finding is released without its remediation options menu.
3. **Interactive run wrote `.compliance-audit.yml`** — file exists at repo root with all six standard keys, `last_confirmed` stamped.
4. **Headless run read config and skipped N/A** — `not_applicable` standards have no draft plans, and a stale-config warning was emitted if `last_confirmed` is older than `reconfirm_after_days`.
5. **Plans generated with correct namespaces** — `compliance-<standard>-` prefixes verified.
6. **Hash-chained log written** — the audit log (`Write-AlignmentAuditLog` or equivalent) is intact with `phase-complete` entries per standard.
7. **Stage, commit, push** — per standard protocol.
8. **Report elapsed time** — total + per-standard breakdown.

---

## Sign Off

```
Status: Compliance Audit Complete
```

Write a `SIGN_OFF` workflow event.

---

## Cross-References

- `Skills/Auditor/SKILL.md` — Audit mode parent catalog (this track registers into it)
- `Skills/Archive/workflow-audit-complete-audit.md` — Complete Audit orchestrator (Compliance track integration)
- `Skills/Auditor/alignment-audit.md` — sibling; § Phase B is the consolidation mechanics reference
- `Skills/Workflows/Audit/architectural-audit.md` — sibling; Finding Format template
- `Skills/Archive/workflow-audit-functional-audit.md` — sibling; track-master skeleton template
- `Skills/Workflows/Shared/session-plan-format.md` — plan format for generated sessions
- `Skills/Workflows/Audit/Write-DraftPlan.ps1` — draft-plan writer used in Phase A
- complscripts-0 (sibling plan) — `Invoke-ComplianceScan.ps1`, `ConvertFrom-ComplianceConfig.ps1`, `Write-ComplianceAuditConfig.ps1`
- complwire-0 (sibling plan) — `/audit-compliance` slash command + Complete-Audit integration
- `C:/Repos/currents-bookkeeping/scripts/compliance-audit/types.mjs` — `FRAMEWORKS`/`SEVERITY` enums for native-engine ingestion
- `C:/Repos/currents-bookkeeping/scripts/compliance-audit/checks/{pipeda,soc2,iso27001}.mjs` — native check IDs
- `C:/Repos/currents-bookkeeping/docs/business-reference/0045-pipeda-data-sovereignty.md` — data-sovereignty ADR
- `C:/Repos/currents-bookkeeping/docs/PIPEDA-breach-runbook.md` — s.10.9 breach-never-automated rule + `sendDeletion*`/`sendBreach*` naming
- `C:/Repos/currents-bookkeeping/docs/ict-readiness-runbook.md` — A.5.30 RPO/RTO

## Changelog
- 2026-08-09: Initial release. Fourth Audit-mode track covering Canadian data sovereignty, SOC 2, PIPEDA, ISO/IEC 27001:2022, HIPAA, GDPR. Interactive applicability gate writes .compliance-audit.yml for headless automation. Reuses native compliance engines where present.
