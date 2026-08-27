# Skill: Alignment Audit (Master Workflow) — DEFRAGMENTED

> **Note**: This file covers the **Alignment Audit** track (9-domain drift survey).
> For the **Architectural Audit** track (6-dimension model-driven architecture scan),
> see `architectural-audit.md`. The two tracks are independent variants of the same
> Audit mode — run the one that matches your goal.

**Purpose**: Audit the codebase for alignment gaps across **9 consolidated survey domains** (merging 11 originals, adding 1 for capability safety), plus a pre-flight automated sweep. Each domain is a self-contained workflow file that can be executed by a separate agent in parallel. The master workflow coordinates ordering, logging, and completion.

**What changed in the defragmentation (2026-06-19)**:
- Merged Domain 2 (Runtime Correctness) into Domain 8 → new **Domain 2: Deep Code Analysis**
- Merged Domain 7 (Workflow Artifacts) frontmatter/dep-graph checks into Domain 11 → new **Domain 6: Skills & Workflow Artifacts**
- Folded Domain 10 (Prompt Export) into the Completion Checklist
- Trimmed Domain 9 to runtime-only invariants (atomic writes, Docker tags, heading conventions → automated)
- Added **pre-flight automated sweep** (`Invoke-AutomatedScan.ps1`) covering 10 deterministic scan categories
- Made **differential mode** (git-diff scoping) the default
- Replaced `Write-Finding`/JSON manifest intermediate format with **direct draft plan files** (`Write-DraftPlan.ps1`)

**Prerequisites**: Auditor role access, write access to `Tasks/` directories, familiarity with the standard session plan format.

---

## Table of Contents
- [Pre-Audit State Snapshot](#pre-audit-state-snapshot)
- [Deferred-Finding Re-Evaluation](#deferred-finding-re-evaluation)
- [Domain Overview (Defragmented)](#domain-overview-defragmented)
- [Phase 0 — Pre-Flight Automated Sweep (New)](#phase-0--pre-flight-automated-sweep-new)
- [Phase A — Discovery-Only Survey (Parallel)](#phase-a--discovery-only-survey-parallel)
- [Phase A Domain Survey Procedures](#phase-a-domain-survey-procedures)
- [Phase B — Consolidation and Plan Generation](#phase-b--consolidation-and-plan-generation)
- [Cross-Domain Finding Reconciliation](#cross-domain-finding-reconciliation)
- [Audit Logging — Write-AlignmentAuditLog Function](#audit-logging--write-alignmentauditlog-function)
- [End-to-End Data Flow Tracing](#end-to-end-data-flow-tracing)
- [Completion Checklist](#completion-checklist)
- [Completion Checklist Detail](#completion-checklist-detail)
- [Differential Audit Mode (Default)](#differential-audit-mode-default)
- [Sign Off](#sign-off)

---

## Pre-Audit State Snapshot

Before any domain survey begins, capture the current codebase state to a JSON file at `Tasks/Logs/audit-snapshot-<date>.json`:

1. `gitHead`: output of `git rev-parse HEAD`
2. `gitStatus`: output of `git status --porcelain`
3. `environment`: `$PSVersionTable.PSVersion`, `(Get-CimInstance Win32_OperatingSystem).Caption`, `docker version --format '{{.Server.Version}}'` (if available)

Pester results are captured by the Functional Audit (`functional-audit.md` Phase B), not the Alignment snapshot.
5. `deferredFindings`: If a prior snapshot exists at `Tasks/Logs/audit-snapshot-<prior-date>.json`, read its `deferredFindings` array and include it.

At completion, re-capture `gitHead` and `gitStatus`. If HEAD has moved or the working tree changed, log a warning: `"Mid-audit churn detected: git HEAD moved from <snapshot> to <current>. Plan <Files:> fields may be stale."`

When mid-audit churn is detected, re-read the affected domain's key files before logging completed findings to avoid stale evidence.

### Deferred-Finding Re-Evaluation

If `deferredFindings` from the prior snapshot is non-empty, each deferred item must be re-evaluated:
- Resolved by a Coder session → mark `resolved` with `action: "deferred-resolved"`
- Still unresolved → carry forward with reassessed severity
- No longer applicable → log `"deferred-stale"` with reason

**Stale-file pre-check**: Before scanning for existing plans, run the shared `Invoke-StaleFilePreCheck` from `workflow-primitives.md` § Stale-file pre-check, targeting `Tasks/Code/` (checking `Working/`, `Review/`, `Complete/` for live copies). Any file identified as stale is deleted and excluded from the convergence scan.

**Convergence gate**: For each Critical/High finding, check whether an equivalent plan already exists in `Tasks/Code/` (pending), `Tasks/Working/` (in progress), `Tasks/Review/` (under review), or `Tasks/Complete/` (completed this cycle). Also check `git log --oneline -1 -- <affected-file>` — if a recent commit already addressed the finding, skip plan generation and log `finding-resolved-by-prior-work`.

---

## Domain Overview (Defragmented)

| # | Domain | File | Purpose | Dependencies | Effort |
|---|--------|------|---------|-------------|--------|
| 1 | **Secrets + Port Registry** | [`alignment-audit-domain-1-secrets.md`](alignment-audit-domain-1-secrets.md) | Verify all sources of truth for secrets agree | None | Medium |
| 2 | **Deep Code Analysis** | [`alignment-audit-domain-2-deep-analysis.md`](alignment-audit-domain-2-deep-analysis.md) | Merged: Runtime Correctness (former D2) + Static Analysis (former D8) + deprecated patterns + 4 grep-only invariants from D9 | Loads automated scan results first | Very High |
| 3 | **Codebase Health** | [`alignment-audit-domain-3-codebase-health.md`](alignment-audit-domain-3-codebase-health.md) | Test gaps, dead code, docs, type safety, archival compliance | None | Medium |
| 4 | **ADR Alignment** | [`alignment-audit-domain-5-adr.md`](alignment-audit-domain-5-adr.md) | Survey ADRs for drift, gate new ADRs via user approval | None | Medium |
| 5 | **Glossary Consistency** | [`alignment-audit-domain-6-glossary.md`](alignment-audit-domain-6-glossary.md) | Verify glossary terms match codebase usage | None | Low |
| 6 | **Skills & Workflow Artifacts** | [`alignment-audit-domain-6-skills-artifacts.md`](alignment-audit-domain-6-skills-artifacts.md) | Merged: Skills defrag/topology/integrity (former D11) + workflow artifacts (former D7 relevant steps) + **Sub-Survey G: Skills Manifest Health** (dead paths, broken refs, index/manifest agreement) | None — but reads files D2 and D3 also inspect | High |
| 7 | **Behavioral Invariants** | [`alignment-audit-domain-9-behavioral.md`](alignment-audit-domain-9-behavioral.md) | Verify runtime-only cross-cutting guarantees (5 invariants, trimmed from 9) | 1–3 (reads files they may modify) | Medium |
| 8 | **External Regression Coverage** | [`alignment-audit-domain-4-regression.md`](alignment-audit-domain-4-regression.md) | Execute external-repo vitest suites (Upscale-Havens + Currents-Bookkeeping), document failures, generate RunFix Deploy plan | All domains 1–7 | High |
| 9 | **Capability Safety Drift** | [`alignment-audit-domain-9-capability-safety.md`](alignment-audit-domain-9-capability-safety.md) | Detect drift from ADR-0039 capability-based safety model: IAM creep, token scope, gate bypass, enforcement map integrity | None | Medium |

**Removed/superseded files** (no longer dispatched as separate agents):
| Old file | Why removed | Replacement |
|----------|-------------|-------------|
| `alignment-audit-domain-2-runtime.md` | Merged into Deep Code Analysis | `alignment-audit-domain-2-deep-analysis.md` |
| `alignment-audit-domain-7-workflow-artifacts.md` | Relevant checks absorbed into Domain 6 | `alignment-audit-domain-6-skills-artifacts.md` Sub-Surveys E–F |
| `alignment-audit-domain-8-static-analysis.md` | Merged into Deep Code Analysis | `alignment-audit-domain-2-deep-analysis.md` |
| `alignment-audit-domain-10-prompt-export.md` | Folded into CC | CC Step 2b |
| `alignment-audit-domain-11-skills-defrag.md` | Merged into Domain 6 | `alignment-audit-domain-6-skills-artifacts.md` Sub-Surveys A–D |

### Updated Connascence Matrix

| Path | Domains | Conflict risk | Resolution |
|---|---|---|---|
| `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` | 1, 3 | Medium | Annotate connascence in both plans |
| `Infrastructure/manifests/docker-manifest.json` | 1, 4, 7 | Low | Sequential dispatch preferred |
| `docs/Reference/env-var-registry.json` | 1, 3 | Low | No conflict |
| `Skills/Docker/Tests/` (test files) | 3, 8 | Medium | Domain 8 runs after Domain 3 plans land |
| `docs/Reference/Decisions/*.md` | 3, 4 | Low | No conflict |
| `Infrastructure/port-registry.json` | 4, 6 | Low | No conflict |
| `Skills/Docker/Modules/Interclaw.*/Public/*.ps1` | 2, 7 | Medium | Sequential dispatch preferred |
| Skill `.md` files under `Skills/` | 6, 2, 3 | Medium | Run Domain 6 after Domains 2,3 complete |
| `Skills/skills.json` | 6, 3 | Medium | Sequential dispatch preferred |
| `Skills/skills-index.json` | 6 | Low | Auto-rebuilt by `Build-SkillsIndex.ps1` |
| `Skills/Create/Skill-Authoring/Scripts/Build-SkillsIndex.ps1` | 6 | Low | Run after manifest changes |
| `Skills/Create/Skill-Authoring/Scripts/Invoke-SkillsManifestHealthCheck.ps1` | 6, 3 | Low | Run after skill consolidation |

**Maintenance**: Update this table when adding or removing a path from any domain's survey procedure.

---

## Phase 0 — Pre-Flight Automated Sweep (New)

**Always run before Phase A**. The automated sweep covers deterministic grep patterns that would otherwise be duplicated across multiple domains. It runs in two stages: a grep-based scan and an AQE quality scan.

### Stage 1 — Grep-based automated scan

```powershell
$sweepScript = "Skills/Workflows/Audit/Invoke-AutomatedScan.ps1"
$today = Get-Date -Format "yyyy-MM-dd"
& $sweepScript -OutputFile "Tasks/Logs/automated-scan-$today.json"
```

The sweep runs 10 scans, producing a JSON findings file at `Tasks/Logs/automated-scan-<date>.json`:

| # | Scan | Covers (former domain source) |
|---|------|-------------------------------|
| 1 | Deprecated patterns | Domain 3 (step 7): Write-Host, Select-Object -Property *, Add-Content without -Encoding |
| 2 | Concurrency hazards | Domain 2: ForEach-Object -Parallel, Start-ThreadJob, $script: access, sync primitives |
| 3 | Retry/timeout patterns | Domain 2: Start-Sleep, retry/backoff logic |
| 4 | Silent error swallowing | Domain 2: Out-Null, 2>$null, -ErrorAction SilentlyContinue, empty catch |
| 5 | Atomic file writes | Domain 9 Invariant 2: direct Set-Content/Out-File without temp-file pattern |
| 6 | Pinned Docker tags | Domain 9 Invariant 5: FROM with floating tags |
| 7 | Canonical section headings | Domain 9 Invariant 8,9: ## Constraints, ## Lessons Learned |
| 8 | Module parser validation | Domain 7: PowerShell syntax errors |
| 9 | TOCTOU on file writes | Domain 2: Test-Path then separate write |
| 10 | TOCTOU Add-Content | Domain 2: Test-Path + Add-Content |

### Stage 2 — AQE quality scan

```powershell
$aqeScript = "Skills/Workflows/Audit/Invoke-AqeAuditScan.ps1"
& $aqeScript -OutputFile "Tasks/Logs/aqe-scan-$today.json"
```

The AQE scan calls high-reliability AQE tools via the REST bridge (`http://mcp_aqe:21004`), producing a JSON findings file at `Tasks/Logs/aqe-scan-<date>.json`:

| # | AQE Tool | What it covers |
|---|----------|----------------|
| 1 | `quality_assess` | 4-pillar scorecard (coverage, complexity, maintainability, security) on key modules |
| 2 | `validation_pipeline` | 13-step doc quality checker on reference docs and AGENTS.md |
| 3 | `qe_security_url-validate` | PII/secret scanner on config manifests (more capable than grep) |
| 4 | `qe_mincut_analyze` | Fleet topology SPOF detection (structural single points of failure) |
| 5 | `qe_coherence_audit` | Cross-domain coherence check across fleet components |
| 6 | `defect_predict` | Predict defect-prone areas in PowerShell modules |

**Non-blocking**: If the AQE bridge is unreachable (e.g., running audit from host without fleet deployed), the scan writes an empty results file and the audit continues with grep-based findings only. AQE findings supplement — never replace — manual analysis.

### Loading both scan results

Domain agents **load both result sets** at the start of their survey:

```powershell
$scanDate = (Get-Date -Format "yyyy-MM-dd")
$grepScan = Join-Path $repoRoot "Tasks\Logs\automated-scan-$scanDate.json"
$aqeScan  = Join-Path $repoRoot "Tasks\Logs\aqe-scan-$scanDate.json"
if (Test-Path $grepScan) { $grepFindings = Get-Content $grepScan -Raw | ConvertFrom-Json }
if (Test-Path $aqeScan)  { $aqeFindings  = Get-Content $aqeScan -Raw | ConvertFrom-Json }
```

Domain agents only perform manual analysis for findings the automation skips (architecture decisions, logic errors, cross-cutting concerns). This eliminates redundant grep searches across all domains. AQE findings provide quality scorecards, topology analysis, and defect predictions that grep cannot produce.

---

## Phase A — Discovery-Only Survey (Parallel)

### Wave schedule (default orchestrator concurrency of 5)

The domains are dispatched in 5 waves. No `-p 8` override needed.

| Wave | Domains | Agents | Rationale |
|------|---------|--------|-----------|
| **Wave 1** | D1 (Secrets), D4 (ADR), D5 (Glossary) | 3 | Fast, independent, no file overlap |
| **Wave 2** | D2 (Deep Code), D3 (Health) | 2 | Heavy analysis in parallel — no shared files |
| **Wave 3** | D6 (Skills+Artifacts) | 1 | After D2, D3 complete to avoid mid-audit churn on shared skill files |
| **Wave 4** | D7 (Behavioral), D9 (Capability Safety) | 2 | After D2/D3 complete — D7 reads files D2 may flag; D9 checks IAM and enforcement map against D2/D3 findings |
| **Wave 5** | D8 (External Regression) | 1 | Last — runs external vitest suites after all plans filed |

### Resource Constraints

Total: 9 survey domains, 5 waves. Maximum 3 concurrent agents, well within the default orchestrator limit of 5.

If full parallelism is desired despite connascence risks (not recommended):
```powershell
# Override: dispatch all 9 domains simultaneously
./Orchestrator/Orchestration/LocalOrchestrator.ps1 -p 8
```

### Domain Claiming

When an agent picks up a domain to survey, it writes a `phase-start` entry to the audit log:
```powershell
Write-AlignmentAuditLog -Domain "domain-<N>" -Action "phase-start" -Detail "Claimed by <agent-id>"
```

Upon completion:
```powershell
Write-AlignmentAuditLog -Domain "domain-<N>" -Action "phase-complete" -Detail "Using Write-DraftPlan: <N> draft plans written"
```

---

## Phase A Domain Survey Procedures

Each domain is defined in its own file. Domain agents follow these steps:

1. **Load automated scan results** (if applicable to the domain's scope)
2. **Run the survey procedure** defined in the domain file
3. **Log findings as draft plans** using `Write-DraftPlan.ps1` (replaces old `Write-Finding.ps1`):
   ```powershell
   . ./Write-DraftPlan.ps1
   Write-DraftPlan -Domain "domain-<N>" -Severity <severity> -BlastRadius <blast> `
       -Title "<finding title>" -Detail "<finding detail>" -Files @("<affected-files>")
   ```
4. **Write phase-complete** to audit log

Domain agents write draft plans directly to `Tasks/Code/Drafts/<domain>/` rather than a shared JSON manifest. This eliminates:
- The `Write-Finding` JSON manifest intermediate format
- Cross-process mutex contention on a single manifest file
- The JSON serialization/deserialization boundary where findings could be lost

### Phase B consolidator reads all draft plans, merges overlapping ones by file path, and writes final plans.

---

## Phase B — Consolidation and Plan Generation

After Phase A completes and the user has provided scope direction, the consolidating agent runs Phase B.

### Step 1 — User Gate

Read the draft plans directory and produce a structured summary. List each Critical and High finding. Ask the user:
> The audit found N draft plans. Recommended: generate session plans for all Critical and High findings. Adjust scope?

### Step 2 — Load the `name-session-plan` skill

```powershell
. "Skills/Planner/Write-SessionPlan.ps1"
```

This shared script is the single source of truth for the Print naming convention (`<date>-<namespace>-<iteration>-<description>.md`). Both Plan mode and Audit mode use it. See `name-session-plan.md` for usage details.

### Step 3 — Consolidate findings into session plans ⚠️ CRITICAL

**Do NOT skip connascence grouping.** All plans generated without connascence analysis default to a single serial namespace, eliminating parallel dispatch and wasting fleet capacity.

1. **Read all draft plans** from `Tasks/Code/Drafts/`. Each draft has fields: `Finding ID`, `Severity`, `Blast Radius`, `Files`, `Title`, `Detail`, and a domain label extracted from the heading (`# Draft Plan: <domain> — <title>`).

2. **Categorize by severity**: Critical, High, Medium, Low. Every Critical and High finding must get a session plan. Medium/Low findings that share files with Critical/High findings are promoted; others are deferred. Use `-IncludeAll` to generate plans for every finding regardless of file overlap.

3. **Group by file path overlap** — findings that touch the same files go into the same plan. Split any group exceeding 5 findings into chunks of 5.

4. **Map each domain to its semantic namespace** using the table below. This ensures the orchestrator can dispatch independent parallel tracks.

    | Domain ID | Semantic Namespace |
    |-----------|-------------------|
    | `domain-1` | `secrets-port-registry` |
    | `domain-2` | `deep-code-analysis` |
    | `domain-3` | `codebase-health` |
    | `domain-4` | `regression-coverage` |
    | `domain-5` | `adr-alignment` |
    | `domain-6` | `skills-artifacts` |
    | `domain-7` | `workflow-artifacts` |
    | `domain-8` | `static-analysis` |
    | `domain-9` | `capability-safety` |
    | `domain-10` | `self-check` |
    | `domain-11` | `skills-defrag` |

5. **Build `$allFiles` as a string array** — draft plan `Files` fields may be a `Hashtable.KeyCollection` object (from parsing) instead of `[string[]]`. Always cast to string array before joining:
    ```powershell
    # Defensive: ensure allFiles is [string[]] even if draft parsing returns KeyCollection
    $allFiles = [string[]]$allFiles
    ```

6. **Generate a session plan for each group** using `Write-SessionPlan.ps1`:
    ```powershell
    $content = @"
    # Session Plan: $Today — $namespace — $($findings.Count) findings
    **Status**: ready
    **Date**: $Today
    **Namespace**: $namespace
    **Files**: $($allFiles -join ', ')
    **Connascence**: None
    **Token budget**: estimated ${tokenBudget}K
    **Validation Rubric**:
    1. [ ] Address all $criticalCount Critical and $highCount High severity findings
    2. [ ] Verify all modified file paths resolve on disk
    3. [ ] Estimated token budget (${tokenBudget}K) < 400,000
    4. [ ] No regression introduced in adjacent code
    "@

    Write-SessionPlan -Namespace $namespace -Iteration $planIndex `
        -Description "$($namespace)" -Content $content
    ```
    Each plan file follows the Print naming convention automatically. The `-Description` parameter ensures the description segment is populated — derive a short kebab-case description from the namespace or finding titles. Ensure finding descriptions in the session plan body are non-empty — skip or flag any draft finding with an empty `Detail` field rather than generating an empty bullet.

7. **Detect cross-namespace file conflicts** — after all plans are written, read every plan's `**Files:**` field. If two different namespaces MODIFY the same file, inject `**DependsOn**:` into the later namespace's plans referencing the earlier namespace's plan.

8. **AQE draft plan validation** — if the AQE bridge was available during Phase 0, run `validation_pipeline` on each generated session plan to catch doc quality issues before Coder dispatch:
   ```powershell
   $aqeScan = Join-Path $repoRoot "Tasks\Logs\aqe-scan-$today.json"
   if ((Test-Path $aqeScan) -and ((Get-Content $aqeScan -Raw | ConvertFrom-Json).available)) {
       Get-ChildItem "Tasks/Code/$Today-*.md" | ForEach-Object {
           $planContent = Get-Content $_.FullName -Raw
           try {
               $result = Invoke-RestMethod -Uri "http://mcp_aqe:21004/tools/validation_pipeline" `
                   -Method POST -Body (@{ pipeline = "requirements"; target = $_.FullName; continueOnFailure = $true } | ConvertTo-Json) `
                   -ContentType "application/json" -TimeoutSec 60
               if ($result.issues -and $result.issues.Count -gt 0) {
                   Write-Host "AQE doc issues in $($_.Name): $($result.issues.Count)" -ForegroundColor Yellow
               }
           } catch { Write-Host "AQE validation skipped for $($_.Name)" -ForegroundColor Gray }
       }
   }
   ```
   This is advisory only — plans with doc quality issues are still dispatched, but the consolidating agent should fix obvious gaps (missing `**Files:**`, empty `Detail` fields) before proceeding.

9. **Clean up the draft directory** after successful consolidation:
    ```powershell
    Remove-Item "Tasks/Code/Drafts" -Recurse -Force -ErrorAction SilentlyContinue
    ```

Log: `Write-AlignmentAuditLog -Domain master -Action session-create -Detail "N plans in K namespaces generated from M draft plans. X cross-namespace DependsOn injected."`

### Step 4 — Verify Namespace Topology

After consolidation, verify the namespace breakdown:
```powershell
$plans = Get-ChildItem "Tasks/Code/$Today-*.md"
$plans | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($c -match '\*\*Namespace\*\*: (.+)') { $matches[1].Trim() }
} | Group-Object | Sort-Object Count -Descending | Format-Table Name, Count
```

Every distinct namespace is an independent parallel track. Plans within the same namespace are sequential by iteration. Cross-namespace `DependsOn` ensures correct ordering for shared-file conflicts.

**Naming rule**: Namespace values must be **semantic kebab-case words** reflecting what the plan addresses (e.g., `secrets-port-registry`, `deep-code-analysis`, `codebase-health`, `skills-artifacts`), NOT numeric labels like `domain-1`. The filename convention follows the **name-session-plan** skill — see `Skills/Planner/name-session-plan.md` and `session-plan-format.md`.

**Checklist:**
- [ ] 2+ namespaces exist (not all under a single `audit` namespace)
- [ ] Each namespace is a coherent parallel track (no unrelated concerns merged)
- [ ] All namespace names are semantic kebab-case words (no `domain-N` labels)
- [ ] Cross-namespace DependsOn exists for any shared-file conflicts
- [ ] All filenames match `<date>-<namespace>-<iteration>-<description>.md` (the description segment is present)
- [ ] The redeploy plan has `**Namespace**: redeploy` and `**DependsOn**:` listing all other namespaces

If all plans share a single namespace, or use generic `domain-N` labels instead of semantic names, or lack the description segment — **stop and fix before proceeding.** This is a blocking check — do not proceed to review until namespaces and naming are correct.

### Step 5 — Generate Redeploy Plan

The RunFix Deploy session plan (`redeploy` namespace) lists every other session plan from this cycle in its `**DependsOn:**` field. Its **content is driven by `~/.salmon/` configuration** (see `Skills/Auditor/Get-SalmonConfig.ps1` and `.salmon/README.md`).

**Config resolution** (first match wins):

1. Machine-specific — `$HOME/.salmon/audit/redeploy.json` (`$env:USERPROFILE\.salmon\audit\redeploy.json` on Windows)
2. Public-repo — `<repo>/.salmon/audit/redeploy.json` (tracked in git)
3. Built-in defaults — hard-coded fallback

Generate it using `Write-SessionPlan.ps1` with the resolved config:

```powershell
. "Skills/Planner/Write-SessionPlan.ps1"
$cfg = & (Resolve-Path "Skills/Auditor/Get-SalmonConfig.ps1") -PlanName "redeploy"
if ($null -eq $cfg) {
    # Built-in fallback matches .salmon/audit/redeploy.json defaults
    $cfg = @{
        namespace = "redeploy"; description = "runfix-deploy"
        fileTargets = @("Tasks/Logs/Audit/redeploy.md")
        tokenBudget = "5K"
        validationRubric = @(
            "Every audit plan is listed in DependsOn with (status: complete)"
            "Generated Plans table lists every plan with namespace / scope / files"
            "Estimated token budget (5K) < 250,000"
        )
        overview = "Terminal Alignment Audit plan. Validates fleet health after all audit fixes land via RunFix Deploy."
        tasks = @(@{
            title = "Validate fleet health after audit fixes"
            why = "Confirm the repaired tree still deploys and fleet services are healthy."
            files = @("Tasks/Logs/Audit/redeploy.md")
            changes = @("Run the repo's standard gates: typecheck, Pester, deploy checks."; "Record results to Tasks/Logs/Audit/redeploy.md.")
            acceptance = "All gates pass or failures are waivers with owner/expiry."
            verification = "Get-Content Tasks/Logs/Audit/redeploy.md | Select-String -Pattern 'pass|fail|waiver'"
        })
        hookTasks = @()
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}
Write-Host "redeploy config source: $($cfg._source ?? 'built-in fallback')"

# Build DependsOn: all from DependsOn injection is the set of alignment plans already written
# (computed earlier in Step 3/4). Re-derive here for the redeploy header:
$allPlans = Get-ChildItem "Tasks/Code/$Today-*.md" | Where-Object { $_.BaseName -notmatch 'redeploy|post-audit-fixes' }
function Get-AuditPlanIdentifier([System.IO.FileInfo]$File) {
    if ($File.BaseName -notmatch '^\d{4}[-.]\d{2}[-.]\d{2}-(.+)-(\d+)-.+$') { throw "Cannot extract namespace-iteration from $($File.Name)" }
    return "$($matches[1])-$($matches[2])"
}
$allPrereqs = $allPlans | ForEach-Object { Get-AuditPlanIdentifier $_ } | Sort-Object -Unique
$dependsBlock = ($allPrereqs | ForEach-Object { "$_ (status: complete)" }) -join "`n             "

# Render tasks + hookTasks from config
$taskSections = @()
$idx = 1
foreach ($t in @($cfg.tasks + $cfg.hookTasks)) {
    $taskSections += @"
## Task $idx`: $($t.title)
**Why**: $($t.why)
**Files**: $($t.files -join ', ')
**Changes**:
$(($t.changes | ForEach-Object { "- $_" }) -join "`n")
**Acceptance**: $($t.acceptance)
**Verification**: $($t.verification)
"@
    $idx++
}

$validationLines = ($cfg.validationRubric | ForEach-Object { "1. [ ] $_" }) -join "`n"
# Replace the leading "1." numbering with correct sequence
$validationLines = ($cfg.validationRubric | ForEach-Object -Begin { $n=1 } -Process { "$n. [ ] $_"; $n++ }) -join "`n"

$redeployContent = @"
**Status**: ready
**Date**: $Today
**Namespace**: $($cfg.namespace)
**DependsOn**: $dependsBlock
**Files**: $($cfg.fileTargets -join ', ')
**Connascence**: None
**Token budget**: estimated $($cfg.tokenBudget)
**Validation Rubric**:
$validationLines

---

## Overview
$($cfg.overview)

---

$($taskSections -join "`n`n---`n`n")

---

## Generated Plans
| # | Plan | Namespace | Scope | Files |
|---|------|-----------|-------|-------|
| _populated at generation time from Get-ChildItem Tasks/Code/$Today-*.md_ | | | | |
"@

Write-SessionPlan -Namespace $cfg.namespace -Iteration "0" -Description $cfg.description -Content $redeployContent
```

**Print requirement**: The redeploy plan must include a `## Generated Plans` section with a formatted Markdown table showing every plan this audit produced, with columns: Plan filename, Namespace, Scope (severity/finding count), and Files. This follows the name-session-plan convention — the table is a human-readable digest, not a bare file dump. The table is populated at generation time from the actual `Tasks/Code/<date>-*.md` set; the template above is filled by the script. Machine-specific overrides live in `~/.salmon/audit/redeploy.json` (`hookTasks[]` is the extension point); public defaults live in `.salmon/audit/redeploy.json`.

### Step 6 — Review and Adjust

Verify each generated plan has required fields, files exist on disk, token budget < 400K, no contradictory tasks, and every filename includes the description segment. Fix issues directly.

Log: `Write-AlignmentAuditLog -Domain master -Action progress-update -Detail "Phase B review: N plans checked, M issues corrected. Namespaces: K parallel tracks."`

---

## Cross-Domain Finding Reconciliation

### 1. Retraction
Any domain can retract a finding from a prior domain via audit log:
```powershell
Write-AlignmentAuditLog -Domain "domain-4" -Action "finding-retraction" `
    -Detail "Retracting D2-CRITICAL-1: env-var-registry.json passes validation"
```

### 2. Cross-reference
```powershell
Write-AlignmentAuditLog -Domain "domain-2" -Action "finding-crossref" `
    -Detail "Domain 1 finding D1-HIGH-2 (legacy key name) also observed in bundle-manifest.ps1"
```

### 3. Cross-referencing Pester regression tests
```powershell
$regressionResults = Invoke-Pester -Path Skills/Docker/Tests/ -PassThru
```
If a test fails for an issue the audit already logged, the finding is independently confirmed. If a test fails for an unlogged issue, add a new finding. If a test passes for an issue the audit flagged, re-examine the finding.

---

## Audit Logging — Write-AlignmentAuditLog Function

Every alignment audit produces a structured JSONL log at `Tasks/Logs/alignment-audit-<date>.jsonl`. Entries use a SHA-256 hash chain linking each entry to its predecessor, providing tamper-evident audit trail.

### `Write-AlignmentAuditLog`
Defined in `Write-AlignmentAuditLog.ps1`. Dot-source before any domain work:
```powershell
. ./Write-AlignmentAuditLog.ps1
```

**Parameters**: `-Domain` (required), `-Action` (required), `-Detail`, `-Severity`, `-SessionFile`, `-Stage`, `-StageDurationMs`.

**Example**:
```powershell
Write-AlignmentAuditLog -Domain "domain-2" -Action "phase-start" -Detail "Claimed by auditor-001"
Write-AlignmentAuditLog -Domain "domain-2" -Action "phase-complete" -Detail "8 draft plans written"
```

### Pre-flight verification
Before the first domain begins surveying, verify the resolved log path is inside the repo tree:
```powershell
$logDir = Resolve-Path "Tasks/Logs"
if (-not $logDir.StartsWith($repoRoot)) { throw "Audit log path outside repo tree" }
```

---

## End-to-End Data Flow Tracing

Some bugs — especially race conditions — are invisible to line-by-line static analysis. When a finding involves shared state across a call chain, use end-to-end data flow tracing:

1. Start at the **origin** — where data is produced or modified
2. Trace to the **consumer** — where data is read
3. Identify the **execution boundary** — where scope, thread, or process changes
4. Verify the data crosses the boundary correctly

**Key questions at each boundary**:
- Is the data serialized? Serialized copies are snapshots — modifications don't propagate back.
- Is the data in module scope (across `ForEach-Object -Parallel`)? Each runspace gets its own copy.
- Is the data behind a mutex/semaphore that actually spans the boundary? Named primitives do; unnamed ones don't.
- Is there a partial synchronization gap?

---

## Completion Checklist

After surveying all 9 domains and writing session plans, the auditor runs the CC. The CC is enforced by the audit log's `close-out` action — the auditor MUST emit exactly one `close-out` entry after the final `phase-complete`.

### Step-by-step

1. **Verify audit log completeness** — all 9 domains have entries (phase-complete for each). Domain 6 must have at least one entry per sub-survey (A/B/C/D/E/F). Hash chain intact.

2. **Verify session plans** — all generated plans in `Tasks/Code/` with `**Status**: ready`, all required fields populated. Every Critical/High finding has a corresponding plan.

2b. **Prompt export check (was Domain 10)**:
    ```powershell
    # Check 1: Export script exists
    if (-not (Test-Path "Skills/Workflows/Audit/Export-OpenCodeSessions.ps1")) {
        Write-Warning "Export-OpenCodeSessions.ps1 is missing — prompt export will fail"
    }
    # Check 2: /export command registered
    $ocConfig = Get-Content "opencode.json" -Raw | ConvertFrom-Json
    $hasExport = $ocConfig.commands | Where-Object { $_.name -eq "export" }
    if (-not $hasExport) {
        Write-Warning "/export command missing from opencode.json"
    }
    # Generate session plan to run export
    Write-DraftPlan -Domain "domain-10" -Severity info -BlastRadius low `
        -Title "Export opencode session history" `
        -Detail "Run Export-OpenCodeSessions.ps1 to export prompts/responses to Tasks/Complete/Prompts/" `
        -Files @("Tasks/Complete/Prompts/")
    ```

3. **Verify no retracted findings are counted** — check checklist items against retractions.

4. **Verify Medium/Low coverage** — every finding is either covered by a plan or has a documented deferral rationale.

5. **Re-capture pre-audit snapshot** — compare HEAD and working tree against the pre-audit snapshot. Log warning if mid-audit churn detected.

6. **Update documentation** — for any drift finding, ensure glossaries, ADRs, and diagrams are consistent.

7. **Stage task files and commit** — per-file `git add`, modular commits with semantic messages.

8. **Verify clean tree** — `git status --porcelain` returns empty.

9. **Push** — `& (Resolve-Path "Skills/DevOps/Git/Invoke-GitPullSafe.ps1") && git push` with git lock.

10. **Report elapsed time** — output total + per-domain breakdown.

11. **Emit `close-out` log entry**:
    ```powershell
    Write-AlignmentAuditLog -Domain "master" -Action "close-out" `
        -Detail "CC complete: <N>/9 domains surveyed, <N> draft plans, <N> final plans generated" `
        -Severity "info"
    ```

### Detailed Checklist

- [ ] All 9 survey domains have entries in the audit log (phase-complete for each)
- [ ] Audit log written to `Tasks/Logs/alignment-audit-<date>.jsonl`
- [ ] Hash chain intact — last entry's `prev` matches second-to-last entry's `hash`
- [ ] All generated session plans in `Tasks/Code/` with `**Status**: ready`
- [ ] Every plan has `**Files:**`, `**Connascence:**`, `**Token budget:**`, `**Validation Rubric:**` with ≥ 2 named checkboxes
- [ ] Every Critical/High finding has a corresponding session plan
- [ ] Verify no retracted findings are counted as `Critical/High findings covered`
- [ ] Every Medium/Low finding is either covered by a session plan or has documented deferral rationale
- [ ] Pre-audit snapshot re-captured; no mid-audit churn detected, or warning logged
- [ ] Prompt export script check performed (CC Step 2b)
- [ ] Every Critical-blast-radius finding has a session plan
- [ ] **Plan conflict scan**: For every pair of session plans sharing a file in `**Files:**`, verify tasks are not contradictory
- [ ] **Semantic naming compliance**: Every plan's `**Namespace**:` is a semantic kebab-case word (e.g., `secrets-port-registry`, not `domain-1`). If any plan fails this check, STOP and fix before proceeding.
- [ ] **Redeploy plan prints formatted summary**: The RunFix Deploy plan includes a **Generated Plans** table with each plan's namespace, scope, findings count, and files — matching the Plan > Print formatted output convention.
- [ ] **Archival policy compliance**: If `Tasks/Logs/alignment-audit-*.jsonl` count > 10, verify Domain 3 archive plan exists
- [ ] **Deferred finding continuity**: Carry forward unresolved items with reassessed severity
- [ ] Plan staleness: Check `git log --oneline -3 -- <file>` for each plan's files
- [ ] **RunFix Deploy plan present**: A RunFix Deploy session plan exists in `Tasks/Code/` with `**Dependencies:**` listing every other session plan
- [ ] Working tree clean (`git status --porcelain` empty)
- [ ] Final push succeeded (`Invoke-GitPullSafe` + `git push`)
- [ ] **Convergence check**: Count plans vs prior audit snapshot. Flag divergence if `plans_generated >= prior_plans_generated + 1`
- [ ] **Honesty check**: Re-read every checkbox. If any is unchecked, write manual task, STOP.

---

## Differential Audit Mode (Default)

**Differential mode is now the default.** Only perform a full audit when explicitly requested.

When a prior audit snapshot exists at `Tasks/Logs/audit-snapshot-<prior-date>.json`, scope the audit to changed files:

```powershell
$priorSnapshot = Get-Content "Tasks/Logs/audit-snapshot-<prior-date>.json" -Raw | ConvertFrom-Json
$priorHead = $priorSnapshot.gitHead
```

### Automated scoping

1. **Scope the automated sweep**: `Invoke-AutomatedScan.ps1 -PriorAuditHead <prior-head>` only scans files changed since the prior audit.
2. **Scope domain surveys**: Each domain agent runs `git diff --name-only <prior-head>..HEAD`. If no files in its scope changed, log `finding: "no changed files in scope — survey compressed"` and skip.
3. **The sweep script** produces a differential findings file. Domain agents load it and only add findings for newly introduced issues.

### Metric comparisons

| Metric | Prior | Current | Delta |
|--------|-------|---------|-------|
| Total findings | 45 | 38 | -7 ✅ |
| Critical findings | 2 | 0 | -2 ✅ |
| Session plans written | 4 | 3 | -1 ✅ |

Flag regressions: Any metric that worsens gets `⚠️ Regressed: <metric> degraded from <prior> to <current>`.

### No prior snapshot

If no prior snapshot exists, run a full audit and seed the snapshot for the next run.

---

## Sign Off

> **Prerequisite**: The CC must have completed and the `close-out` log action must be present.

Emit the terminal message:
```
Status: Ready to Sign Off
```

Then write a `SIGN_OFF` workflow event:
```powershell
Write-WorkflowEvent -Type SIGN_OFF -Detail "Completed" -Phase auditor
```

The session ends after the terminal message. Do NOT start a new build/test cycle after completing.

---

## Troubleshooting

### Invoke-AutomatedScan.ps1 produces 0 findings with 0 files scanned

**Root cause**: The `In-Scope` function compared Windows backslash paths (`Skills\Docker\...`) against git's forward-slash paths (`Skills/Docker/...`). No path matched, so all files were skipped.

**Fix**: `In-Scope` now normalizes backslashes to forward slashes before lookup (`$path -replace '\\', '/'`).

### Invoke-AutomatedScan.ps1 parser error on `\$script:`

**Root cause**: The scan detail strings used `\$script:` to escape the dollar sign. In PowerShell, the escape character is backtick (`` ` ``), not backslash (`\`). The `\` was treated as a literal character, causing a parser error.

**Fix**: Changed `\$script:` to `` `$script: `` (backtick escape) in all double-quoted strings.

### Phase B grouping produces 0 session plans from N draft plans

**Root cause**: The severity classification must match case-insensitively. If draft plans use unexpected casing or the gathering step fails to parse them, all findings are skipped.

**Fix**: Normalize severity to lowercase during grouping. Validate at least one finding was parsed before proceeding. If 0 plans are generated, re-check the draft plan format against `Write-DraftPlan.ps1`.

### name-session-plan / Write-SessionPlan.ps1 produces wrong filename format

**Root cause**: The `Write-SessionPlan.ps1` script is the single source of truth for naming. If the filename is wrong, the script logic is wrong — fix it there, not in callers.

**Fix**: Read `Skills/Workflows/Shared/session-plan-format.md` for the canonical filename pattern `<date>-<namespace>-<iteration>-<description>.md`. Ensure all four segments are present. Update `Write-SessionPlan.ps1` if the pattern has changed.

**Prevention**: Both Plan mode and Audit mode call the same script. A fix in one place fixes both.

### Invoke-AutomatedScan.ps1 produces 0 findings with 0 files scanned

**Root cause**: The `In-Scope` function compared Windows backslash paths (`Skills\Docker\...`) against git's forward-slash paths (`Skills/Docker/...`). No path matched, so all files were skipped.

**Fix**: `In-Scope` now normalizes backslashes to forward slashes before lookup (`$path -replace '\\', '/'`).

### Invoke-AutomatedScan.ps1 parser error on `\$script:`

**Root cause**: The scan detail strings used `\$script:` to escape the dollar sign. In PowerShell, the escape character is backtick (`` ` ``), not backslash (`\`). The `\` was treated as a literal character, causing a parser error.

**Fix**: Changed `\$script:` to `` `$script: `` (backtick escape) in all double-quoted strings.

### Invoke-AutomatedScan.ps1 produces 263 [ref] parser-validation false positives

**Root cause**: On PowerShell 7.6.2, `[System.Management.Automation.Language.Parser]::ParseInput()` throws exceptions for valid `[ref]` parameter references in module code, rather than returning them through the `$errors` parameter. The original filter only checked the `$errors` path with a narrow regex (`'\[ref\] cannot be applied'`) and assumed all PS versions return errors the same way.

**Fix**: Broadened the filter from `'\[ref\] cannot be applied'` to `'\[ref\]'` in both the `$errors`-path and the `catch`-path, so it catches any `[ref]`-related message regardless of the PS version's error phrasing. Added diagnostic logging to the catch block so the count is visible at a glance during scan output.

### Invoke-AutomatedScan.ps1 parser error on `—` (em-dash) or non-ASCII characters

**Root cause**: UTF-8 without BOM on PowerShell 7.6.2: the parser mishandles non-ASCII characters (em-dash U+2014, curly quotes, etc.) when the file lacks a BOM, producing spurious `Unexpected token` errors. The existing `inside — each` string on line 114 broke the entire parse, cascading into 5+ phantom errors across the remainder of the file.

**Fix**: Re-saved the file with UTF-8 BOM (`239, 187, 191`). Also replaced the em-dash character with a regular hyphen (`-`) as defense-in-depth. The file now parses cleanly on PS 7.6.2.

**Prevention**: Save all `.ps1` files with UTF-8 BOM encoding when they contain non-ASCII characters. Avoid em-dashes, curly quotes, and other typographic characters in PowerShell string literals — they are valid in PowerShell but trigger parser bugs on some PS 7.x versions when combined with BOM-less UTF-8.

---

## Changelog

- 2026-06-19: **Defragmentation release** — merged 11 domains into 8. Added automated sweep, differential default, draft-plan workflow. Folded D10 into CC. See master workflow header for full changelog.
- 2026-06-20: Fixed `Invoke-AutomatedScan.ps1` path separator bug (git uses `/`, Windows uses `\` — `In-Scope` now normalizes). Fixed `\$script:` escape (should be `` `$script: `` — backtick not backslash). Fixed `Convert-FindingsToPlans.ps1` Windows `\r\n` trimming and em-dash vs hyphen parsing. Added `-IncludeAll` switch for full-scope consolidation. Added Namespace as Parallel Track convention to `session-plan-format.md` and `workflow-primitives.md` — namespaces are parallel tracks, cross-namespace MODIFIES conflicts use DependsOn, REFERENCES do not create conflicts.
- 2026-06-20: Purged 26 stale/archived entries from `skills.json`. Added two-tier index/manifest system: `skills-index.json` (agent discovery) + `skills.json` (full manifest). Added Sub-Survey G to Domain 6 (Skills Manifest Health) with automated checks. New tools: `Build-SkillsIndex.ps1`, `Invoke-SkillsManifestHealthCheck.ps1`.
- 2026-06-21: **Fixed connascence-blind plan generation.** `Convert-FindingsToPlans.ps1` was hardcoding all plans under a single `audit` namespace (serial execution). Fixed to use `domain-<N>` namespaces per survey domain (parallel tracks). Added Phase 5 (connascence analysis) that detects cross-namespace file MODIFIES conflicts and injects per-plan `DependsOn` entries. Updated `alignment-audit.md` Phase B to mandate Step 3 (Verify Namespace Topology) as a blocking check — no plan cycle may proceed past Phase B without evidence of proper namespace grouping. See `alignment-audit.md` § Step 2 — Connascence-Grouped Consolidation and § Step 3 — Verify Namespace Topology.
- 2026-06-22: **Semantic namespace convention + script bugfixes.** Updated namespace rule from `domain-<N>` to semantic kebab-case (e.g., `secrets-registry`, `code-quality`, `skills-manifest`) matching the Plan > Print skill convention. Fixed `Invoke-AutomatedScan.ps1` [ref] filter to catch exception-path false positives. Fixed `Convert-FindingsToPlans.ps1` `$planName:` parser error and hashtable-enumeration crash. See Troubleshooting for root cause details.
- 2026-06-23: **Replaced `Convert-FindingsToPlans.ps1` with shared `name-session-plan` skill.** The new `Write-SessionPlan.ps1` at `Skills/Workflows/Shared/` is the single source of truth for the Print naming convention. Phase B now uses procedural steps + `Write-SessionPlan.ps1` instead of the standalone script. Both Plan mode and Audit mode reference the same shared skill. See `Skills/Planner/name-session-plan.md`.
- 2026-06-27: Documented UTF-8 BOM + em-dash parser bug in Troubleshooting for Invoke-AutomatedScan.ps1 on PS 7.6.2.
