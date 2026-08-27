---
name: accountant/workflow
description: Accountant role workflow — interactive bookkeeping pipeline with milestone-aware phase progression and completion rubric verification. Use when told to perform accounting, bookkeeping, reconciliation, or receipt processing tasks.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Accountant Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "accountant/workflow"

## Purpose
Interactive bookkeeping pipeline with milestone-aware phase progression and completion rubric verification. Run the full bookkeeping lifecycle from source data gathering through remote reconciliation and accountant handoff.

## Trigger
- User says "Accountant"
- Task involves bookkeeping, accounting, reconciliation, receipt processing, or Zoho Books operations
- Cowork workflow would redirect here for accounting tasks

## Workflow steps
See `workflow.md` (this folder) for the full Phase 0–5 procedure (Initialize → Execute Current Phase → Verify Milestone → Record → Handoff → Complete).

## Sub-skills and tools
- `workflow.md` — full Accountant Workflow (Phase 0–5)
- `tools.md` — tool configuration and constraints
- `Skills/Accountant/_accountant.md` <!-- doc-lint: exempt --> — master pipeline overview and universal rules
- `Skills/Accountant/sources/` — source data gathering (gather, check-email, reconcile)
- `Skills/Accountant/processing/` — receipt processing (process-receipts, find-missing, enrich, upload)
- `Skills/Accountant/books/` — bookkeeping phases (reconcile-remote, journal-entries, confirm-account-balances)
- `Skills/Accountant/books/zoho/` — Zoho-specific operations (expenses, auth-ref, reconciliation)
- `Skills/Accountant/milestone/` — completion rubrics (ready-for-manual-review, ready-for-accountant)
- `Skills/Marketing/CRM/` — CRM integration (attio, moved from Skills/Accountant/CRM/)
- `Skills/Accountant/books/ingest/` — invoice ingestion (invoices)
- `Skills/Workflows/Cowork/Scripts/` — shared handoff artifact generation (New-CoworkStub, New-FinalHandoff, New-SessionLog, New-PostHocPlan, New-ManualTask, New-MemoryEntry, New-CredentialRef, New-LockHeader)
- `Skills/Accountant/Scripts/` — 20+ accounting utility scripts

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Lock Header, shared code snippets)
- `Skills/Cowork/handoff.md` — handoff document generation
- `AGENTS.md` — role definitions and Accountant entry
- `~/intersite-docs/Documentation/Memory/mem-accountant-intersite.md` — pipeline state memory (resolve path via `_project-map.json`)

## Red lines
- **READ before WRITE** — never import/upload without checking existing state (`_accountant.md` rule)
- **Circuit break on failure** — stop batch on first API error, fix root cause
- **CC payments are transfers, not expenses** — use `POST /banktransactions` with `transaction_type: transfer_fund`
- **Cache the OAuth token** — one token per session, reuse for all Zoho API calls
- **Sweep CR+DR duplicates after every `POST /expenses` batch**
- **Sidecar CSVs are authoritative for transaction direction** — bank portal CSV sign may disagree
- **Receipts over $5** must have a receipt or qualify for exemption
- **AWS SSO auth: run `aws sso login --profile intersite`** when token expired

## Completion
Milestone & Handoff Completeness check per Accountant/workflow.md inline Completion section. `Status: Completed` when verified.
