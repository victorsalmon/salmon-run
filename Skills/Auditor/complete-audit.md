# Complete Audit — `complete-audit.md` (meta-track orchestration)

**Type**: mode-workflow (meta-track)
**Part of**: Audit mode (`Skills/Auditor/SKILL.md`)
**Purpose**: Orchestrate the audit tracks, emit a terminal `post-audit-fixes` plan that `DependsOn` every prior plan and signals the end of the audit, then trigger the mandatory `battle-tested-qa` Phase Q as a follow-on. This is the only audit variant that mixes tracks. The post-audit-fixes hook is the extension point for any tasks that must run after all audit-found repairs land and before QA re-proofs them.

> **Wiring note (2026-08-24)**: This file previously did not exist on disk even though
> `Skills/Auditor/SKILL.md` referenced `complete-audit.md` as the Phase Q orchestrator.
> Without it, "Complete Audit" could not actually dispatch Phase Q. Creating this file
> wires Phase Q in: every Complete Audit MUST run the alignment survey and then the
> mandatory `battle-tested-qa` Phase Q below.
>
> **Update (2026-08-25)**: Phase Q no longer runs *inside* the Complete Audit as a
> sibling to Alignment. The Complete Audit now ends with a terminal `post-audit-fixes`
> plan (`DependsOn: all`); when that plan reaches `complete` it triggers Phase Q via
> `Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md` / `$battle-tested-qa`.
> This makes QA validate the *repaired* codebase (all audit fixes landed) rather than
> the pre-fix baseline, and gives the audit a single hook (`post-audit-fixes`) where
> future follow-on work can be hung without editing every alignment plan's `DependsOn`.

## Trigger

- User says "Complete Audit" / "complete audit" / "audit complete" → this meta-track.
- `Refactor` mode (`opencode run --command runfix refactor-pipeline`) runs Complete Audit (RunFix).

## What runs

1. **Alignment Audit** — `Skills/Auditor/alignment-audit.md` (Phases 0–4, 9 domains).
   Produces draft plans consolidated into `Tasks/Code/<date>-<namespace>-*.md` plus the
   `redeploy` (`runfix-deploy`) plan that already `DependsOn` every alignment namespace.
2. **Post-Audit-Fixes — terminal hook** (MANDATORY, last plan emitted) — namespace
   `post-audit-fixes` (single plan, iteration `0`). `DependsOn` every plan emitted in
   step 1 and signals "Complete Audit fixes are done". See [Post-Audit-Fixes plan](#post-audit-fixes-plan-terminal-hook) below.
3. **Post-Audit Trigger — Battle-Tested QA** — *outside* the Complete Audit, launched
   only after `post-audit-fixes` reaches `complete`. Runs
   `Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md` using the
   `$battle-tested-qa` plugin (`Skills/Plugins/battle-tested-qa/skills/battle-tested-qa/SKILL.md`).
   Validates property/stateful coverage, mutation adequacy, and ongoing changed-code
   proof against the repaired tree. Emits `qa-<repo>` session plans and a report at
   `Tasks/Logs/Audit/qa/<date>-<repo>-qa-report.md`. This is the success gate that
   replaces the former in-audit Phase Q.

## Orchestration order (cross-audit DependsOn)

```text
Alignment Audit (all 9 domains + redeploy)
        │
        ▼
post-audit-fixes (DependsOn: every alignment plan)
        │
        ▼  (upon status: complete)
Battle-Tested QA — triggered, not emitted, by Complete Audit
  (reads the repaired tree, emits qa-* plans + qa-report)
```

- The Alignment `redeploy` plan `DependsOn` all other alignment namespaces (per
  `alignment-audit.md` Phase B Step 5). `post-audit-fixes` in turn `DependsOn` the
  `redeploy` plan *and* every other alignment plan, so it is strictly last — Coders
  cannot start it until every audit-found repair is committed.
- `post-audit-fixes` is the *only* plan in the Complete Audit that is allowed to
  list *all* prior namespaces in `DependsOn`. No alignment plan should list
  `post-audit-fixes`.
- Battle-Tested QA is **not** a `DependsOn` target inside the audit. It is a
  follow-on workflow launched after `post-audit-fixes` is marked `complete` (by the
  Coder lane, orchestrator hook, or operator). For non-salmon-orchestrator targets,
  plans AND the report still live in `salmon-orchestrator/Tasks/` (the audit is always
  authored from the orchestrator repo). Set `$env:AUDIT_TARGET_REPO` to the target
  repo root before triggering Phase Q.

## Post-Audit-Fixes plan (terminal hook)

The Complete Audit MUST emit exactly one `post-audit-fixes` plan as its final write.
It is the hook where any work that must run after all audit fixes land — but before
QA re-proof — is hung. Add tasks there rather than editing every alignment plan.
**Content is driven by `~/.salmon/` configuration** (see `Skills/Auditor/Get-SalmonConfig.ps1` and `.salmon/README.md`).

**Config resolution** (first match wins):

1. Machine-specific — `$HOME/.salmon/audit/post-audit-fixes.json` (`$env:USERPROFILE\.salmon\audit\post-audit-fixes.json` on Windows)
2. Public-repo — `<repo>/.salmon/audit/post-audit-fixes.json` (tracked in git)
3. Built-in defaults — hard-coded fallback (matches `.salmon/audit/post-audit-fixes.json`)

**Filename**: `<date>-post-audit-fixes-0-<slug>.md` via `Write-SessionPlan.ps1`
(e.g. `2026-08-25-post-audit-fixes-0-complete-audit-hook.md`).

**Header skeleton** is rendered from the resolved JSON (`namespace`, `fileTargets`, `validationRubric`, `tokenBudget`):

```markdown
**Status**: ready
**Date**: <date>
**Namespace**: post-audit-fixes
**DependsOn**: <every-audit-namespace-iteration> (status: complete)
             redeploy-0 (status: complete)
**Files**: Tasks/Logs/Audit/post-audit-fixes.md
**Connascence**: None
**Token budget**: estimated 5K
**Validation Rubric**:
1. [ ] Every audit plan is listed in DependsOn with (status: complete)
2. [ ] Completion triggers Battle-Tested QA per Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md
3. [ ] Estimated token budget (5K) < 250,000
```

**Body** is rendered from `tasks[]` + `hookTasks[]` in the resolved JSON. The public default
`.salmon/audit/post-audit-fixes.json` ships with:

1. `## Overview` — terminal hook description
2. `tasks[0]` — *Verify all audit fixes landed*
3. `tasks[1]` — *Trigger Battle-Tested QA* (loads `$battle-tested-qa`, follows `opencode-audit-battle-tested-qa.md` steps 1–9, emits `qa-<repo>` plans + mandatory report even on zero findings; `blocked` if plugin missing)
4. `hookTasks[]` — empty by default (`None — add follow-on work here when needed`). Future audits append tasks here without touching `DependsOn` topology. Machine-specific `~/.salmon/audit/post-audit-fixes.json` may add entries to `hookTasks[]` that run after all audit fixes and before QA.

**Generation script** (run after Alignment Phase B has written all alignment plans, including `redeploy`):

```powershell
. "Skills/Planner/Write-SessionPlan.ps1"
$cfg = & (Resolve-Path "Skills/Auditor/Get-SalmonConfig.ps1") -PlanName "post-audit-fixes"
if ($null -eq $cfg) {
    $cfg = Get-Content ".salmon/audit/post-audit-fixes.json" -Raw | ConvertFrom-Json
    if ($null -eq $cfg) { throw "Get-SalmonConfig: no post-audit-fixes config found and no fallback" }
}
Write-Host "post-audit-fixes config source: $($cfg._source ?? '.salmon/audit/post-audit-fixes.json')"

$allPlans = Get-ChildItem "Tasks/Code/*.md" | Where-Object { $_.BaseName -notmatch 'post-audit-fixes' }
function Get-AuditPlanIdentifier([System.IO.FileInfo]$File) {
    if ($File.BaseName -notmatch '^\d{4}[-.]\d{2}[-.]\d{2}-(.+)-(\d+)-.+$') { throw "Cannot extract namespace-iteration from $($File.Name)" }
    return "$($matches[1])-$($matches[2])"
}
$allPrereqs = $allPlans | ForEach-Object { Get-AuditPlanIdentifier $_ } | Sort-Object -Unique
$dependsBlock = ($allPrereqs | ForEach-Object { "$_ (status: complete)" }) -join "`n             "

$taskSections = @()
$idx = 1
foreach ($t in @($cfg.tasks + $cfg.hookTasks)) {
    $hookTag = if ($idx -gt $cfg.tasks.Count) { " (hook)" } else { "" }
    $taskSections += @"
## Task $idx$hookTag`: $($t.title)
**Why**: $($t.why)
**Files**: $($t.files -join ', ')
**Changes**:
$(($t.changes | ForEach-Object { "- $_" }) -join "`n")
**Acceptance**: $($t.acceptance)
**Verification**: $($t.verification)
"@
    $idx++
}
if ($cfg.hookTasks.Count -eq 0) {
    $taskSections += @"
## Hook tasks
None — add follow-on work here when needed. Machine-specific tasks from ~/.salmon/audit/post-audit-fixes.json appear here; public tasks from .salmon/audit/post-audit-fixes.json appear here.
"@
}
$validationLines = ($cfg.validationRubric | ForEach-Object -Begin { $n=1 } -Process { "$n. [ ] $_"; $n++ }) -join "`n"

$content = @"
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
"@

Write-SessionPlan -Namespace $cfg.namespace -Iteration "0" -Description $cfg.description -Content $content
```

## Post-Audit Trigger — Battle-Tested QA (mandatory follow-on)

Load `Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md` and follow it in full
**only after `post-audit-fixes` is `complete`**:

1. Load `$battle-tested-qa` from `Skills/Plugins/battle-tested-qa/skills/battle-tested-qa/SKILL.md`
   (fallback `$env:USERPROFILE\plugins\battle-tested-qa/...`); stop as blocked if neither exists.
2. Establish the exact baseline for every layer (unit, integration/contract, property/stateful,
   E2E, security, route/behavior, mutation). Never infer success from an aggregate wrapper.
3. Build a risk-ranked behavior inventory: every public route/page/command/job and every financial,
   authorization, tenant-isolation, destructive, transactional, idempotent, and audit-log invariant.
4. Run mutation testing against the current suite BEFORE proposing new tests (Stryker for JS/TS repos,
   the repo's PowerShell mutation harness / TEETH fault-injection for salmon-orchestrator).
   Record killed / survived / no-coverage / timeout / compile-error / equivalent separately.
5. Assess property generators, shrinking, deterministic seeds, boundary bias, stateful/model testing.
6. Assess harness hermeticity, skips, flakes, retries, shared mutable state, port/process ownership.
7. Verify the ongoing change gate mandates behavior-inventory updates, layered tests, changed-code
   mutation, full regression, and evidence refresh per change.
8. Write one autonomous `qa-<repo>` session plan per verified gap (do NOT cap findings).
9. Write the report even with zero plans: commands, counts, seeds, mutation scope/results,
   survivor dispositions, skips/flakes, unmapped behaviors, waivers, and pass/fail/blocked.

This trigger replaces the former in-audit Phase Q. The Complete Audit itself is `complete`
when `post-audit-fixes` is `complete`; the QA report's `pass`/`fail`/`blocked` is the
post-audit proof gate.

## Pass contract (from Battle-Tested QA)

Phase Q (now post-audit) passes only when: all critical/public behaviors mapped to executable proof; required
properties/model tests exist and replay; mutation adequacy meets plugin thresholds with no untriaged
critical survivors or no-coverage mutants; required suites pass without unexplained skips/flakes; the
ongoing change gate mandates changed-code mutation + evidence refresh; every gap has an orchestrator-ready plan.
An unavailable browser/DB/credential/mutation runner/external service makes that layer `blocked` — emit a plan
or manual action with the exact prerequisite (this is not a pass).

## Completion Checklist

- [ ] Alignment Audit: all 9 domains surveyed; session plans written to `Tasks/Code/` (including `redeploy`).
- [ ] Post-Audit-Fixes: terminal `post-audit-fixes-0` plan written; `DependsOn` lists every alignment plan with `(status: complete)`.
- [ ] Post-Audit-Fixes is the last plan emitted by the Complete Audit (no plan has `DependsOn: post-audit-fixes`).
- [ ] Every Critical/High alignment finding has a corresponding plan.
- [ ] Audit log `close-out` entry written (reuse `Write-AlignmentAuditLog` convention; tag Post-Audit-Fixes under `master`).
- [ ] Battle-Tested QA trigger: `post-audit-fixes` completion launches Phase Q per `Skills/AQE/4C-Bugfix/opencode-audit-battle-tested-qa.md`; `qa-<repo>` plans + report at `Tasks/Logs/Audit/qa/<date>-<repo>-qa-report.md` are the post-audit proof (report exists even with zero plans).
- [ ] Task artifacts committed and pushed; working tree clean of audit-only files.

## Changelog

- 2026-08-25: Move Battle-Tested QA out of the audit — Complete Audit now ends with a terminal `post-audit-fixes` plan (DependsOn: all) that triggers QA on completion (hook for future follow-on work).
- 2026-08-24: Authored this file to wire Phase Q into the Complete Audit (previously referenced but missing on disk).
