# Domain 7: Workflow Artifact Integrity (SUPERSEDED)

**This domain has been absorbed into Domain 6: Skills & Workflow Artifacts.**

All workflow artifact checks — task file cross-reference hygiene, lock header/staleness audit, FENCE protocol compliance, session plan template completeness, and skill frontmatter drift — are consolidated in:

> **`alignment-audit-domain-6-skills-artifacts.md`** (Sub-Surveys D, E)

Module parser validation was moved to the automated pre-flight sweep (`Invoke-AutomatedScan.ps1`, Scan 8).

**Reason for superseding**: Workflow artifact integrity and skills/track organization both inspect `skills.json`, task files, and skill `.md` files. Merging into a single domain agent eliminates redundant file scanning and cross-domain finding reconciliation.

See: [`alignment-audit-domain-6-skills-artifacts.md`](alignment-audit-domain-6-skills-artifacts.md)
