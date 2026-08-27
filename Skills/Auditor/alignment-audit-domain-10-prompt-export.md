# Domain 10: Prompt History Export (FOLDED INTO CC)

**This domain has been folded into the Completion Checklist (CC) step of the master alignment audit workflow.**

Rationale: The survey consisted of exactly two existence checks:
1. Does `Export-OpenCodeSessions.ps1` exist?
2. Is the `/export` command registered in `opencode.json`?

These checks are not complex enough to justify a dedicated domain agent. They are now performed as part of CC Step 2 (Verify session plans) in the master workflow:

> **CC Step 2b — Prompt export check**:
> ```powershell
> # Check 1: Export script exists
> if (-not (Test-Path "Skills/Workflows/Audit/Export-OpenCodeSessions.ps1")) {
>     Write-Warning "Export-OpenCodeSessions.ps1 is missing — prompt export will fail"
> }
> # Check 2: /export command registered
> $ocConfig = Get-Content "opencode.json" -Raw | ConvertFrom-Json
> $hasExport = $ocConfig.commands | Where-Object { $_.name -eq "export" }
> if (-not $hasExport) {
>     Write-Warning "/export command missing from opencode.json"
> }
> # Generate session plan to run export
> Write-DraftPlan -Domain "domain-10" -Severity info -BlastRadius low `
>     -Title "Export opencode session history" `
>     -Detail "Run Export-OpenCodeSessions.ps1 to export prompts/responses to Tasks/Complete/Prompts/" `
>     -Files @("Tasks/Complete/Prompts/")
> ```

**Historical reference**: See `Export-OpenCodeSessions.ps1` in this directory for the canonical export script.
