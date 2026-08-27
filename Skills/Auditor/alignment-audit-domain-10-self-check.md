# Domain 10: Audit Self-Check — Meta-Audit

**Purpose**: Assess the alignment audit's own files for structural quality, defragmentation, deduplication, and software architecture best practices. Generate a session plan to refactor the audit itself.

**Trigger**: This domain runs **last** (Wave 6), only after all other domains have completed their surveys. It uses the full run's output (draft plans, audit log, cross-references) to identify improvements in the audit process itself.

**Scope**: All files under `Skills/Workflows/Audit/` — the master workflow, all domain files, workflow definition, SKILL, PowerShell scripts (`Invoke-AutomatedScan.ps1`, `Write-DraftPlan.ps1`, `Write-AlignmentAuditLog.ps1`, `Export-OpenCodeSessions.ps1`), the shared `name-session-plan` skill (`Write-SessionPlan.ps1` at `Skills/Workflows/Shared/`), and the `consistency-audit.md` and `architectural-audit.md` companion files.

---

## Phase 1 — File Inventory

Catalog every file in the audit toolchain:

```powershell
$auditDir = Resolve-Path "Skills/Workflows/Audit"
Get-ChildItem -Path $auditDir -Recurse -Include "*.md", "*.ps1", "*.json" |
    Select-Object Name, Length, LastWriteTime | Sort-Object Name
```

Group by type:
- **Master workflow**: `alignment-audit.md`
- **Domain files**: `alignment-audit-domain-*.md`
- **Supporting docs**: `workflow.md`, `SKILL.md`, `tools.md`, `consistency-audit.md`, `architectural-audit.md`
- **PowerShell tools**: `Invoke-AutomatedScan.ps1`, `Write-DraftPlan.ps1`, `Write-AlignmentAuditLog.ps1`, `Write-SessionPlan.ps1` (shared), `Export-OpenCodeSessions.ps1`, `Write-Finding.ps1`, `Write-DraftPlan.ps1`

---

## Phase 2 — Cross-Reference Analysis

### 2a. Check for duplicate checks across domains

For every pair of domain `.md` files, compare their **Purpose**, **Survey procedure**, and **Scoring** sections. Flag any finding that could be handled by more than one domain (indicating poor boundary separation):

| Finding class | Potential overlap |
|---|---|
| `Write-Host` / deprecated patterns | Domain 2, Domain 3, Automated Scan 1 |
| Hard-coded assumptions (path, OS, env) | Domain 2, Domain 3 (maintenance) |
| Secret exposure in logs/scripts | Domain 1 (Secrets), Domain 2 (security), Domain 7 (behavioral invariants) |
| Documentation drift (non-code files) | Domain 3, Domain 5 (Glossary), Domain 4 (ADR) |

Flag any overlapping scope that should be consolidated. Each overlap is a medium-severity finding.

### 2b. Check for gaps

Compare the automated scan's 10 categories against what each domain covers manually. For each automated category, verify:
- Does at least one domain's manual procedure include verifying/overriding the automated finding?
- If not, the domain is missing a step that should follow the automated sweep.

Gaps are medium-severity findings.

### 2c. Check domain numbering alignment

Verify that domain file numbers in filenames, frontmatter, and the master table all agree:
- Filename `alignment-audit-domain-{N}-{name}.md` — does `{N}` match the domain number in `alignment-audit.md`'s domain table?
- Does the header inside each file state the correct domain number?
- Are any files orphaned (not referenced in the master table)?

Discrepancies are low-severity findings.

---

## Phase 3 — Structural Analysis

### 3a. Single Responsibility Principle

For each domain file, check whether it covers **more than one distinct concern**:

| Domain | Current scope | SRP concern |
|---|---|---|
| Domain 1 | Secrets + Port Registry | Two separate concerns: secrets and ports. Consider splitting or verifying they're tightly coupled. |
| Domain 2 | Deep Code Analysis (bugs + runtime + static + deprecated patterns) | Merger of 2 former domains. Verify the merged scope is cohesive, not a grab-bag. |
| Domain 3 | Codebase Health (tests + dead code + docs + type safety + archival) | Five distinct sub-concerns. Verify each has a clear procedure. |
| Domain 6 | Skills & Workflow Artifacts (defrag + topology + integrity + manifest + artifacts) | Merger of 2 former domains + 5 sub-surveys. Verify sub-surveys are logically grouped. |

Flag any domain that has become a catch-all rather than a focused concern.

### 3b. Procedure completeness

For each domain file, verify:
- Does it have a **Purpose** section? ✅
- Does it have a **Survey procedure** with numbered steps? (prefer yes)
- Does it have a **Scoring** table? (prefer yes)
- Does it reference `Write-DraftPlan.ps1` correctly (not the deprecated `Write-Finding.ps1`)?
- Does the procedure reference any file that no longer exists on disk?

Missing or broken references are medium-severity findings.

### 3c. Connascence analysis

Compare the domain structure's declared connascence in `alignment-audit.md`'s **Updated Connascence Matrix** against actual file overlaps discovered during this audit run. If a file overlap existed between two domains that ran concurrently and produced conflicting findings, that's evidence the connascence matrix needs updating.

---

## Phase 4 — DRY Analysis

### 4a. Duplicate PowerShell code

Scan `.ps1` files in `Skills/Workflows/Audit/` for duplicated function definitions or repeated helper patterns:

```powershell
$auditDir = Resolve-Path "Skills/Workflows/Audit"
$ps1Files = Get-ChildItem -Path $auditDir -Filter "*.ps1"
foreach ($file in $ps1Files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    # Check for repo root resolution pattern (duplicated in every script)
    if ($content -match 'while \(\$repoRoot\)') {
        Write-Hint "Repo root resolution duplicated in $(Split-Path $file -Leaf)"
    }
}
```

Known duplication candidates:
- **Repo root resolution**: Present in `Invoke-AutomatedScan.ps1`, `Write-DraftPlan.ps1`, `Write-AlignmentAuditLog.ps1`, `Write-SessionPlan.ps1` — identical ~15-line while-loop. Should be extracted.
- **File path joining with `\` vs `/`**: Inconsistent separator usage across scripts.
- **Mutex usage pattern**: Duplicated in `Invoke-AutomatedScan.ps1` and `Write-AlignmentAuditLog.ps1` — similar but not identical mutex handling.

Each duplicate pattern is a medium-severity finding.

### 4b. Duplicate markdown patterns

Scan all audit `.md` files for repeated text blocks:
- Identical scoring tables across domain files
- Identical `Write-DraftPlan` invocation blocks
- Identical `Write-AlignmentAuditLog` examples
- Identical pre-flight load-blocks (automated scan loading code in multiple domains)

These are low-severity findings unless they've drifted (different copies with slight variations) — those are medium.

---

## Phase 5 — Software Architecture Best Practices

### 5a. Dependency graph analysis

Map which files depend on which within `Skills/Workflows/Audit/`:

```mermaid
graph TD
    alignment-audit.md -->|imports| domain-1.md
    alignment-audit.md -->|imports| domain-2.md
    alignment-audit.md -->|imports| domain-3.md
    alignment-audit.md -->|imports| domain-4.md
    alignment-audit.md -->|imports| domain-5.md
    alignment-audit.md -->|imports| domain-6.md
    alignment-audit.md -->|imports| domain-7.md
    alignment-audit.md -->|imports| domain-8.md
    alignment-audit.md -->|imports| domain-9.md
    alignment-audit.md -->|runs| Invoke-AutomatedScan.ps1
    domain-*.md -->|calls| Write-DraftPlan.ps1
    Write-SessionPlan.ps1 -->|writes| Tasks/Code/<date>-<ns>-<iter>-<desc>.md
    Write-DraftPlan.ps1 -->|calls| Write-AlignmentAuditLog.ps1
    workflow.md -->|references| alignment-audit.md
    SKILL.md -->|references| alignment-audit.md
```

Check for:
- **Circular dependencies**: Does any domain `.md` file reference the master workflow? (It should not — domains should be independent.)
- **Hidden dependencies**: Does any domain depend on another domain's output (beyond the declared wave schedule)?
- **Missing abstraction layer**: Is there an interface or contract that domain files implement? If not, new domains require editing the master file — that's tight coupling.

### 5b. Cohesion assessment

For each file, compute a cohesion score based on:
- Does the file have a single, clear topic?
- Can you describe the file's responsibility in one sentence?
- Would a reader know which file to modify for a given change?

Score per file: ✅ (focused), ⚠️ (sprawling but coherent), ❌ (catch-all). Any ❌ is a high-severity finding.

### 5c. Coupling assessment

Evaluate how changes propagate:
- Adding a new domain requires editing: `alignment-audit.md` (5+ sections), `workflow.md`, `SKILL.md`. That's 3+ files.
- Changing the draft plan format requires editing: `Write-DraftPlan.ps1`, all 9 domains that call it, and the Phase B procedural steps in `alignment-audit.md`. The final plan format is generated by the agent following `session-plan-format.md` — no script to update on the output side.
- Changing the audit log format requires editing: `Write-AlignmentAuditLog.ps1` and all consuming tools.

High coupling in the format layer is a medium-severity finding.

### 5d. Testability assessment

Verify:
- Are audit scripts testable? `Write-SessionPlan.ps1` has `-DryRun` — ✅
- Does `Invoke-AutomatedScan.ps1` have `-DryRun`? Yes — ✅
- Can domain procedures be verified without running the full audit? If not, low-severity finding.
- Are there Pester tests for any audit script? Check `Skills/Docker/Tests/` for audit-related tests. Missing tests are low-severity.

---

## Phase 6 — This Run's Artifact Assessment

### 6a. Audit log analysis

Read `Tasks/Logs/alignment-audit-<date>.jsonl` and analyze:
- **Elapsed time per domain**: Which domains took longest? (Potential scope-creep signal)
- **Finding count per domain**: Are some domains producing disproportionately many findings? (Potential scope-creep or over-filing)
- **Retraction count**: How many findings were retracted by later domains? (Cross-domain check quality signal)
- **Error entries**: Any domains that failed or produced errors?

### 6b. Draft plan analysis

Count draft plans per domain from `Tasks/Code/Drafts/`. Compare:
- Which domains produced the most plans?
- Which severities dominate?
- Was any domain's output empty (no findings)? If skipping is legitimate, document the reason in the self-check finding.

---

## Phase 7 — Generate Refactoring Plan

Using all findings from Phases 2–6, produce a consolidated refactoring session plan. The plan should address:

1. **Defragmentation**: Merge overlapping domains, split catch-all domains
2. **Deduplication**: Extract shared patterns (repo root resolution, mutex handling) into a shared module
3. **Architecture improvements**: Reduce coupling, formalize domain interface, add test coverage
4. **Process improvements**: Fix any issues discovered in this run's cross-referencing, connascence, or wave scheduling

```powershell
. ./Write-DraftPlan.ps1
Write-DraftPlan -Domain "domain-10" -Severity info -BlastRadius high `
    -Title "Refactor alignment audit: defragment, deduplicate, decouple" `
    -Detail "<consolidated finding summary>" `
    -Files @(
        "Skills/Auditor/alignment-audit.md",
        "Skills/Workflows/Audit/workflow.md",
        "Skills/Auditor/SKILL.md",
        "Skills/Workflows/Audit/Invoke-AutomatedScan.ps1",
        "Skills/Workflows/Audit/Write-DraftPlan.ps1",
        "Skills/Workflows/Audit/Write-AlignmentAuditLog.ps1",
        "Skills/Planner/Write-SessionPlan.ps1"
    )
```

Write separate findings for each refactoring category discovered:

```powershell
Write-DraftPlan -Domain "domain-10" -Severity <severity> -BlastRadius <blast> `
    -Title "<category>: <specific finding>" `
    -Detail "<details>" `
    -Files @("<affected-files>")
```

---

## Phase 8 — Log Completion

```powershell
Write-AlignmentAuditLog -Domain "domain-10" -Action "phase-complete" `
    -Detail "Self-check complete: <N> findings logged, refactoring plan generated"
```

---

## Scoring

| Severity | Description |
|----------|-------------|
| **Critical** | Hard failure in the audit process — domain can't execute, script crashes, hash chain broken |
| **High** | Structural issue that causes real problems: duplicate effort across domains, missing coverage, broken cross-references that cause incorrect findings |
| **Medium** | Defragmentation opportunity, duplicated code, unclear domain boundaries, procedure gaps |
| **Low** | Style, conventions, minor doc drift, missing tests for audit scripts |
