## Audit Workflow

The Audit role (triggered by user's "Audit" command). Runs a single session and exits — no drain loop.

The Audit procedure is decomposed into a master workflow file and 8 per-domain files (defragmented from 11). Load the master file at session start, then load the relevant domain file for each survey.

### Domain Files (one per domain, for parallel multi-agent execution)

| # | Domain | File |
|---|--------|------|
| 1 | **Secrets + Port Registry** | `alignment-audit-domain-1-secrets.md` |
| 2 | **Deep Code Analysis** | `alignment-audit-domain-2-deep-analysis.md` |
| 3 | **Codebase Health & Maintenance** | `alignment-audit-domain-3-codebase-health.md` |
| 4 | **ADR Alignment** | `alignment-audit-domain-5-adr.md` |
| 5 | **Glossary Consistency** | `alignment-audit-domain-6-glossary.md` |
| 6 | **Skills & Workflow Artifacts** | `alignment-audit-domain-6-skills-artifacts.md` |
| 7 | **Behavioral Invariants** | `alignment-audit-domain-9-behavioral.md` |
| 8 | **Full Regression Coverage** | `alignment-audit-domain-4-regression.md` |

### Execution Model

- **Phase 0 (Automated Sweep)**: `Invoke-AutomatedScan.ps1` runs first, covering 10 deterministic grep patterns across all domains. Results feed into each domain agent's survey.
- **Phase 1 (Parallel)**: 3-wave dispatch — Wave 1: D1, D4, D5 (fast, independent). Wave 2: D2, D3, D6 (heavy work). Wave 3: D7 (after D2). Wave 4: D8 (regression, last).
- **Phase 2 (Consolidation)**: Load the `name-session-plan` skill and follow Phase B procedural steps in `alignment-audit.md` — read draft plans from `Tasks/Code/Drafts/`, group by file overlap, write final plans using `Write-SessionPlan.ps1` per the Print naming convention.
- **Phase 3 (Sign Off)**: Verifies audit log, session plans, working tree integrity, prompt export.

**Sign Off**: Per `alignment-audit.md § Sign Off`. The Auditor writes session plans to `Tasks/Code/` for detected drift, not code changes.
