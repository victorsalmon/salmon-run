# Audit Workflow - Tool Configuration

> Tool baseline is at Shared/tools.md. This file documents Audit-specific deltas only.

## Audit-specific deltas

### Alignment Audit
- Standard model tier (flash or higher)
- Pre-flight automated sweep: `Invoke-AutomatedScan.ps1 -OutputFile "Tasks/Logs/automated-scan-<date>.json"`
- Cross-repo dependency sweep (npm/pip): `Invoke-PerRepoDependencySweep.ps1 -RepoRoot C:\Repos -OutputPath C:\Repos\audit-deps-report.md`
- Parallel wave dispatch up to 3 concurrent agents
- See `alignment-audit.md` Phase 0 for context budget per domain

### Architectural Audit
- **Model**: Complex-tier (Pro-level reasoning). Run with `opencode run --command audit --variant complex` or explicitly configure a Pro-tier model.
- **Timeout**: Full-codebase scans may need `-Timeout 600000` (10 minutes).
- **Context budget**:
  | Phase | Budget |
  |-------|--------|
  | Phase 0 — Orientation | ~5% |
  | Phase 1 — Static Architecture | ~20% |
  | Phase 2 — Agent-Readability | ~15% |
  | Phase 3 — Runtime Hazards | ~25% |
  | Phase 4 — Bug Hunt | ~25% |
  | Phase 5 — Consolidation | ~10% |
- **Exclusion list**: `.git/`, `node_modules/`, `Tasks/Logs/`, `Tasks/Complete/`
- **Key source dirs**: `Skills/`, `Infrastructure/`, `docs/`, `Configuration/`
