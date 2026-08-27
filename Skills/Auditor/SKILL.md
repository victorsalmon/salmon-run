---
name: opencode/workflow/audit
description: Audit Workflow — opencode mode workflow. Five tracks: Alignment Audit (9-domain drift survey), Architectural Audit (5-dimension security-first architectural scan), Functional Audit (6-domain operational reliability survey), Feature Audit (product-repo-scoped strategic audit, two phases; see feature-audit.md), Compliance Audit (regulatory & data-sovereignty survey).
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---

# Audit Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/audit"

## Purpose
Survey the codebase for drift (Alignment Audit), architecture quality (Architectural Audit), operational reliability (Functional Audit), product/niche fit (Feature Audit), or regulatory/data-sovereignty posture (Compliance Audit). Complete Audit additionally emits a terminal `post-audit-fixes` plan that `DependsOn` every prior plan and, upon `complete`, triggers the `battle-tested-qa` plugin as a follow-on to validate property/stateful coverage, mutation adequacy, and ongoing changed-code proof against the repaired tree. Generate Coder plans for every finding.

> **Note**: The standalone Security Audit track was merged into the Architectural Audit (structural security) and Functional Audit (operational security) on 2026-07-07. See `architectural-audit.md` and `functional-audit.md`.

## Trigger
- User says "Audit" → Alignment Audit (default)
- User says "Architecture Review" or "/archreview" → Architectural Audit
- User says "Functional Audit" or "/audit func" → Functional Audit
- User says "Feature Audit" or "/audit feature" → Feature Audit (product-repo-scoped strategic audit; requires `--repo <name>`). See `feature-audit.md`.
- User says "Compliance Audit" or /audit compliance → Compliance Audit
- An orchestrator dispatches audit mode

## Workflow steps
- **Alignment Audit**: See `alignment-audit.md` for the master workflow orchestration (Phases 0–4). Domain-specific procedures in domain files.
- **Architectural Audit**: See `architectural-audit.md` for the 5-dimension + Phase 5.5 unit-test build-out security-first model-driven scan (Phases 0–0.5–1–5–5.5–6). Single-pass, not parallel.
- **Functional Audit**: See `functional-audit.md` for the operational reliability survey (Phases 0–B). Script-centric failure-mode analysis across 6 domains.
- **Feature Audit**: See `feature-audit.md` for the two-phase orchestration — Phase A (interactive roadmap + competitor research) and Phase B (headless feature-completeness deep dive).
- **Compliance Audit**: See `compliance-audit.md` for the regulatory & data-sovereignty survey (Canadian data sovereignty, SOC 2, PIPEDA, ISO/IEC 27001:2022, HIPAA, GDPR). Interactive applicability gate writes `.compliance-audit.yml`; headless re-runs require it.

## Sub-skills and tools
### Alignment Audit
- `alignment-audit.md` — master workflow orchestration (Phases 0–4)
- `alignment-audit-domain-1-secrets.md` — Domain 1: Secrets + Port Registry
- `alignment-audit-domain-2-deep-analysis.md` — Domain 2: Deep Code Analysis (merged D2 + D8)
- `alignment-audit-domain-3-codebase-health.md` — Domain 3: Codebase Health & Maintenance
- `alignment-audit-domain-4-regression.md` — Domain 8: External Regression Coverage (runs last). Executes the **external-repo vitest suites for Upscale-Havens and Currents-Bookkeeping (currentsbk.ca)**. The salmon-orchestrator Pester suite has moved to `functional-audit.md` Phase B.
- `alignment-audit-domain-5-adr.md` — Domain 4: ADR Alignment
- `alignment-audit-domain-6-glossary.md` — Domain 5: Glossary Consistency
- `alignment-audit-domain-6-skills-artifacts.md` — Domain 6: Skills & Workflow Artifacts (merged D11 + D7)
- `alignment-audit-domain-9-behavioral.md` — Domain 7: Behavioral Invariants (trimmed)
- `alignment-audit-domain-9-capability-safety.md` — Domain 9: Capability Safety Drift (detect erosion of ADR-0039 capability model)
- `Invoke-AutomatedScan.ps1` — Pre-flight automated sweep (10 grep-based scan categories)
- `Invoke-AqeAuditScan.ps1` — AQE quality sweep (6 AQE tool calls: quality_assess, validation_pipeline, qe_security_url-validate, qe_mincut_analyze, qe_coherence_audit, defect_predict). Non-blocking when AQE bridge is unreachable.
- `Write-DraftPlan.ps1` — Direct draft plan writer (replaces Write-Finding.ps1)
- `name-session-plan` (shared skill) — `Write-SessionPlan.ps1` generates final session plans with correct Print naming convention
- `consistency-audit.md` — consistency-focused audit variant (deprecated)

### Architectural Audit
- `architectural-audit.md` — 5-dimension + Phase 5.5 unit-test build-out security-first architecture scan (Phases 0–0.5–1–5–5.5–6)
- `architectural-audit-code-security-scan.md` — Phase 0.5 automated pre-scan for SQL/command injection, unsafe casts, unsanitized inputs, and hardcoded secrets
- Requires complex-tier model for reliable architectural judgment

### Functional Audit
- `functional-audit.md` — Master workflow orchestration (Phases 0–B)
- `functional-audit-domain-1-core-lifecycle.md` — Domain 1: Core Lifecycle (deploy, provision, secrets)
- `functional-audit-domain-2-powershell-modules.md` — Domain 2: PowerShell Modules (all Interclaw.*)
- `functional-audit-domain-3-command-layer.md` — Domain 3: Command & Orchestrator Layer
- `functional-audit-domain-4-fleet-runtime.md` — Domain 4: Fleet Runtime & Container Services
- `functional-audit-domain-5-bookkeeping.md` — Domain 5: Bookkeeping Pipeline
- `functional-audit-domain-6-automation.md` — Domain 6: Automation & External Integrations

### Feature Audit
- `feature-audit.md` — Master workflow orchestration (two phases: interactive strategy + headless deep dive)
- `feature-audit-phase-a-strategy.md` — Phase A: Strategic Roadmap Review (created in Waves 2/3)
- `feature-audit-phase-b-deepdive.md` — Phase B: Feature Completeness Deep Dive, 9 dimensions (created in Waves 2/3)

### Compliance Audit
- `compliance-audit.md` — Master workflow orchestration (interactive applicability gate + headless re-runs)
- `Invoke-ComplianceScan.ps1` — Scans for applicable standards (PIPEDA, GDPR, HIPAA, SOC 2, ISO 27001, Canadian data sovereignty)
- `ConvertFrom-ComplianceConfig.ps1` — Parses `.compliance-audit.yml` into structured controls
- `Write-ComplianceAuditConfig.ps1` — Writes the interactive applicability gate result as `.compliance-audit.yml`

### Shared
- `tools.md` — tool configuration and constraints

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Connascence, Lock Header)
- `Skills/Workflows/Shared/session-plan-format.md` — plan format spec for generated session plans
- `Skills/Auditor/alignment-audit.md` — Alignment Audit (drift survey)
- `Skills/Workflows/Audit/architectural-audit.md` — Architectural Audit (model-driven)
- `Skills/Archive/workflow-audit-functional-audit.md` — Functional Audit (operational reliability)
- `Skills/Auditor/feature-audit.md` — Feature Audit (product-repo-scoped strategic)
- `Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md` — Complete Audit Phase Q (property/stateful and mutation proof via plugin)

## Red lines
- **Never modify code** — Auditor surveys, Coder fixes. Generated plans go to `Tasks/Code/`.
- **All domains/dimensions in the selected track must be checked** — all 9 alignment domains, all 5 architectural dimensions, or all 6 functional domains. Skipping any invalidates the audit.
- **Architectural Audit requires a complex-tier model**. Running on a flash-tier model produces unreliable results.
- **Never mix tracks in a single run** — Alignment, Architectural, and Functional audits are independent. Complete Audit (`complete-audit.md`) is the exception: it orchestrates the audit tracks with cross-audit DependsOn injection, emits a terminal `post-audit-fixes` plan that `DependsOn` all prior plans, and triggers `battle-tested-qa` only after that hook reaches `complete`.
- **Feature Audit Phase B is read-only** like the other tracks; Phase A is interactive and produces a `proposal` handoff, never an auto-dispatched plan.
- **Compliance Audit requires .compliance-audit.yml to run headless.** Run it interactively first to confirm applicable standards.

## Completion
- Alignment Audit: See `alignment-audit.md` inline Completion. `Status: Completed` when all 9 domains surveyed and plans written.
- Architectural Audit: See `architectural-audit.md` Phase 6. `Status: Completed` when all 5 dimensions and Phase 5.5 unit-test build-out are scanned and plans written.
- Functional Audit: See `functional-audit.md` inline Completion. `Status: Completed` when all 6 domains surveyed and plans written.
- Feature Audit: See `feature-audit.md` Completion. `Status: Feature Audit Strategy Handoff Written` (Phase A) and/or `Status: Feature Audit Deep Dive Complete` (Phase B).
- Compliance Audit: See `compliance-audit.md` inline Completion. `Status: Completed` when all applicable standards surveyed, `.compliance-audit.yml` present, and plans written.
- Complete Audit: See `complete-audit.md`. `Status: Complete Audit Complete` when all tracks (Architectural, Functional, applicable Compliance, Alignment) have written plans and the terminal `post-audit-fixes` hook has been emitted with `DependsOn: all (status: complete)`. Battle-Tested QA is the post-audit proof gate triggered after `post-audit-fixes` completes — not the completion signal itself.

## Changelog
- 2026-06-19: Added Architectural Audit track (merged from standalone ArchReview mode)
- 2026-06-28: Added Functional Audit track — script-centric operational reliability survey across 6 domains. Independent from Alignment and Architectural audits. Trigger via `/audit func`.
- 2026-06-29: Added Security Audit track — operational security survey across 4 domains (Credential Lifecycle, API Security, Key Management, IAM/Container). Added Complete Audit (`complete-audit.md`) as a meta-track that orchestrates all four audits with cross-audit DependsOn.
- 2026-07-07: Security Audit track dissolved. Structural security absorbed into Architectural Audit; operational security returned to Functional Audit. Three active tracks remain: Alignment, Architectural (5 dimensions, security-first), Functional.
- 2026-07-24: Wired AQE (Agentic Quality Engineering) into all three audit tracks. New `Invoke-AqeAuditScan.ps1` calls high-reliability AQE tools (quality_assess, validation_pipeline, qe_security_url-validate, qe_mincut_analyze, qe_coherence_audit, defect_predict) via the REST bridge. Non-blocking when bridge is unreachable. Alignment Audit Phase 0 now runs both grep + AQE scans; Phase B validates draft plans via AQE. Architectural Audit uses AQE topology + security scans. Functional Audit uses AQE defect prediction + quality scores.
- 2026-08-09: Added Feature Audit track — product-repo-scoped strategic audit. Two phases: interactive roadmap/competitor review (Phase A) and headless feature-completeness deep dive (Phase B, 9 dimensions). Independent of Complete Audit meta-track. See `feature-audit.md`.
- 2026-08-09: Added Compliance Audit track — regulatory & data-sovereignty survey (Canadian data sovereignty, SOC 2, PIPEDA, ISO/IEC 27001:2022, HIPAA, GDPR). Interactive applicability gate writes .compliance-audit.yml; headless re-runs require it. Reuses native compliance engines where present.
- 2026-08-15: Added mandatory Complete Audit Phase Q using the `battle-tested-qa` plugin. Phase Q validates property/stateful and mutation adequacy before Alignment and emits `qa-*` plans for every gap.
- 2026-08-25: Move Battle-Tested QA out of the audit — Complete Audit now ends with a terminal `post-audit-fixes` plan (`DependsOn: all`, `status: complete`) that triggers QA as a follow-on. The hook is the extension point for any work that must run after all audit fixes land and before QA re-proofs the repaired tree.
