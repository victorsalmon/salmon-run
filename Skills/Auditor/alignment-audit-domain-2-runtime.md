# Domain 2: Runtime Correctness (SUPERSEDED)

**This domain has been merged into Domain 8 (Deep Code Analysis).**

All content — concurrency hazards, retry/timeout/backoff analysis, error-propagation tracing, static-analysis blind spots, resource-lifecycle hygiene, and canned grep searches — is now part of the consolidated **Domain 2: Deep Code Analysis** in `alignment-audit-domain-2-deep-analysis.md`.

See:
- [`alignment-audit-domain-2-deep-analysis.md`](alignment-audit-domain-2-deep-analysis.md) — the merged domain
- [`Skills/Workflows/Audit/Invoke-AutomatedScan.ps1`](Skills/Workflows/Audit/Invoke-AutomatedScan.ps1) — pre-flight automated sweep that covers all canned grep searches

**Reason for superseding**: Domain 2's survey procedure was a subset of Domain 8's 16-category line-by-line bug hunt. The canned grep searches (concurrency, TOCTOU, retry, error swallowing) are now automated by the pre-flight sweep. Merging eliminates redundant file scanning across two domain agents.
