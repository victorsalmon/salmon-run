# Domain 6: Skills & Workflow Artifacts

**Purpose**: Survey the entire `Skills/` tree for organizational health and validate workflow artifact integrity. Combines:
- Sub-Surveys A–D: Skills & Track Organization (formerly Domain 11)
- Sub-Survey E: Workflow Artifacts (formerly Domain 7, relevant steps)
- Sub-Survey F: Cross-Module Dependency Graph (formerly Domain 7 step 7)

**Trigger**: Run this survey every alignment audit cycle. Skills accumulate drift just like code does. Run after Domains 2 and 3 complete to avoid mid-audit churn on files this domain also inspects.

---

## Sub-Survey A: Skills Defragmentation

### 1. Inventory all skills with dated Lessons Learned blocks

```powershell
$results = @()
Get-ChildItem -Recurse -Filter "*.md" -Path "Skills/" | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    $matches = [regex]::Matches($content, '### Lessons Learned — \d{4}-\d{2}-\d{2}')
    if ($matches.Count -gt 0) {
        $results += [PSCustomObject]@{
            File = $_.FullName
            LessonCount = $matches.Count
            Size = $_.Length
        }
    }
}
$results | Sort-Object LessonCount -Descending | Format-Table -AutoSize
```

Categorize by defrag effort:

| Effort | Criteria |
|--------|----------|
| **High** | 3+ dated blocks OR >100 lines of lessons total |
| **Medium** | 2 dated blocks OR 1 block with >20 lines of substantive content |
| **Low** | 1 dated block with <20 lines of content that can be inline-merged |

### 2. Log findings

For each file identified, log a draft plan via `Write-DraftPlan` with effort level, block count, and recommended changes.

---

## Sub-Survey B: Track Topology

### 1. Build track inventory from skills.json

Extract every unique `track:` value from `skills.json` and group skills by track:

```powershell
$tracks = @{}
Get-Content Skills/skills.json | ConvertFrom-Json | Where-Object { $_.track -and !$_.stale } | ForEach-Object {
    $key = "$($_.domain)/$($_.track)"
    if (-not $tracks[$key]) { $tracks[$key] = @() }
    $tracks[$key] += $_
}
```

### 2. Verify every track has an entrypoint

For each track, check that at least one skill has a `type` that is an entrypoint (`skill-entrypoint`, `mode-workflow`, `pipeline-stage`). Log findings for tracks missing an entrypoint.

### 3. Detect orphan skills

Find skills with a `domain:` but no `track:` field. Log as low-severity findings.

### 4. Detect stale files still on disk

Find `stale: true` entries in `skills.json` whose path still exists on disk. Log as medium-severity findings.

### 5. Verify supersedes chains terminate

Check for stale entries whose `superseded_by` target is itself stale (broken chain). Log as high-severity findings.

---

## Sub-Survey C: Trackflow Gap Analysis

### 1. Identify workflow sequences that should be trackflows

Scan for groups of `pipeline-stage` skills within the same track that are always executed in sequence (3+ consecutive). Log candidates as info-severity findings.

### 2. Check for existing trackflows

Count existing `type: skill-trackflow` entries. If zero, log a low-severity finding encouraging at least one.

---

## Sub-Survey D: Skills.json Structural Integrity

### 1. Validate every `cross_refs` path

For every non-archived, non-stale entry in `skills.json`, verify each path in `cross_refs` exists on disk:

```powershell
$issues = @()
Get-Content Skills/skills.json | ConvertFrom-Json | Where-Object { !$_.stale -and !$_.path.StartsWith("Archived/") } | ForEach-Object {
    $entry = $_
    $entry.cross_refs | Where-Object { $_ -and !(Test-Path $_) } | ForEach-Object {
        $issues += [PSCustomObject]@{ Entry = $entry.name; Missing = $_ }
    }
}
```

### 2. Validate `container` field consistency

Check that every `container: "accountant"` skill (or any container-specific value) actually lives under a path deployed to that container.

### 3. Skill frontmatter drift (absorbed from old Domain 7)

For every `.md` file under `Skills/` (excluding `_build/`):
- Check if the file has YAML frontmatter (starts with `---` then `name:`)
- If frontmatter exists, verify the `name:` field matches the entry in `Skills/skills.json`
- If no frontmatter exists, note it as a convention gap
- Verify every skill file has a corresponding entry in `Skills/skills.json` with the correct `path`
- Run `Orchestrator/Orchestration/Invoke-SkillsRegistryGate.ps1` and treat any failure as a drift finding

### 4. Session plan template completeness (absorbed from old Domain 7)

For every plan file in `Tasks/Code/`:
- Verify `**Status:**` field (must be `ready`)
- Verify `**Files:**` field listing every file to modify
- Verify `**Connascence:**` field (can be `None`)
- Verify `**Token budget:**` field (estimated tokens under 400K)
- Verify `**Validation Rubric:**` with at least 2 named checkboxes

---

## Sub-Survey E: Workflow Artifact Integrity (absorbed from old Domain 7)

### 1. Task file cross-reference hygiene

For every plan file in `Tasks/Code/`, `Tasks/Working/*/`, and `Tasks/Review/`:
- Extract `**Files:**` field and verify each listed path exists on disk
- Extract `**Connascence:**` field and verify each referenced file path resolves
- Cross-reference `**Files:**` against `**Connascence:**` — any file listed in `Files:` but not in `Connascence:` when another plan touches the same path is a missed connascence finding

### 2. Lock Header/staleness audit

Scan `Tasks/Review/` and `Tasks/Working/*/` for plans with Lock Headers:
- Plans with `Status: locked` whose agent PID is no longer running
- Plans with `Status: locked` where the `Locked` timestamp is more than 2 hours old
- Plans in `Tasks/Review/` with `Status: locked` never moved to `Tasks/Complete/`

### 3. Orphan file sweep — task directories

Scan all task directories (`Tasks/Code/`, `Tasks/Review/`, `Tasks/Working/`, `Tasks/Complete/`) for files that don't belong — specifically:

- `stream-*.log` files left in `Tasks/Code/` or `Tasks/Review/` by crashed streams
- `.session-*.txt`, `.agent-*.txt`, or other dotfiles that are not `.gitkeep`
- Stale `.py`, `.json`, or other non-markdown files in `Tasks/Working/`
- Any file matching `*.log` or `*.txt` in task directories that isn't a recognized task artifact

```powershell
$dirs = @("Tasks/Code", "Tasks/Review", "Tasks/Working", "Tasks/Complete")
$orphans = @()
foreach ($d in $dirs) {
    $orphans += Get-ChildItem "$d/stream-*.log" -ErrorAction SilentlyContinue
    $orphans += Get-ChildItem "$d/*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }
    $orphans += Get-ChildItem "$d/.session-*" -ErrorAction SilentlyContinue
    $orphans += Get-ChildItem "$d/*.py" -ErrorAction SilentlyContinue
}
$orphans | Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
```

Log each orphan as a finding via `Write-DraftPlan` with severity Low (cosmetic/cleanup), recommending the file be deleted or moved to an appropriate logs directory.

### 4. FENCE protocol compliance

Scan all plans in `Tasks/Working/*/` and `Tasks/Review/` modifying files under `Skills/Workflows/Shared/`:
- Verify `try-before-rewrite` was executed
- Verify the plan has a rollback section
- Verify the plan cross-references the Shared Spec Change Protocol

---

## Sub-Survey F: Cross-Module Dependency Graph (absorbed from old Domain 7)

Compare actual module dependencies against documented ones:
- For each module under `Skills/Docker/Modules/Interclaw.*/`, extract all `Import-Module`, `.` (dot-source), and `using module` statements
- Build an actual dependency graph
- Compare against `docs/Reference/Diagrams.md` module dependency graph
- Compare against the AGENTS.md "PowerShell Modules" table

---

## Sub-Survey G: Skills Manifest Health

Run the skills manifest health check script. This validates the manifest after any optimization (deduplication, merging) and ensures the agent-facing index stays in sync:

```powershell
& "Skills/Create/Skill-Authoring/Scripts/Invoke-SkillsManifestHealthCheck.ps1" -PassThru
```

### Checks performed:

1. **Dead paths** — every `path` in `skills.json` must resolve to an existing file on disk
2. **Broken cross_refs** — every entry in `cross_refs` must resolve to an existing file
3. **Orphaned files** — `.md` skill files under `Skills/` not registered in the manifest (excluding `_build/`, `_deprecated/`, `node_modules/`, `Tests/`, `Scripts/`, `_organizations/`)
4. **Index/manifest agreement** — every active manifest entry must have a corresponding entry in `skills-index.json`; every index entry must have an active manifest entry
5. **Supersedes chain termination** — every `superseded_by` target must exist in the manifest; chains must not terminate at a stale entry
6. **Stale files on disk** — files under `Skills/_deprecated/` are flagged as informational

### Post-optimization gate

After any skill consolidation, deduplication, or re-organization:

1. Run `Invoke-SkillsManifestHealthCheck.ps1` — must exit 0 (no issues)
2. Rebuild index: `Build-SkillsIndex.ps1`
3. Re-run manifest health check to verify index/manifest agreement passes
4. If any step fails, do not commit — fix the root cause first

### Logging

Log violations via `Write-DraftPlan` with:
- **Sub-survey**: G
- **File path(s)**: the affected `skills.json` and/or `skills-index.json`
- **Severity**: High for dead paths and broken chains, Medium for orphaned files and index drift
- **Recommended action**: Specific fix for each issue type

---

## Output

Log findings from each sub-survey via `Write-DraftPlan`. Each finding includes:
- **Sub-survey** (A/B/C/D/E/F) for grouping
- **File path(s)** for connascence tracking
- **Severity** and **blast radius**
- **Recommended action**

Phase B generates session plans grouped by sub-survey:
- Sub-Survey A → consolidation session plans (one per High-effort skill file)
- Sub-Survey B → track topology fixes
- Sub-Survey C → trackflow definitions
- Sub-Survey D → cross-ref and metadata fixes
- Sub-Survey E → artifact fixes (stale locks, FENCE gaps, template gaps)
- Sub-Survey F → dependency graph alignment
- Sub-Survey G → manifest fixes (dead paths, broken refs, index drift)

## Cross-references

- `Skills/Auditor/alignment-audit.md` — Master alignment audit workflow
- `Skills/skills.json` — Central skill registry
- `Skills/skills-index.json` — Agent-facing skill discovery index
- `Skills/Create/Skill-Authoring/Scripts/Build-SkillsIndex.ps1` — Index generator from manifest
- `Skills/Create/Skill-Authoring/Scripts/Invoke-SkillsManifestHealthCheck.ps1` — Manifest integrity checker

## Changelog

- 2026-06-19: Created as merger of old Domain 11 (Skills & Track) and old Domain 7 (Workflow Artifacts). Sub-Surveys A–D from Domain 11; Sub-Surveys E–F from Domain 7.
- 2026-06-20: Added Sub-Survey G (Skills Manifest Health) — dead paths, broken cross_refs, orphaned files, index/manifest agreement. New tools: `Build-SkillsIndex.ps1`, `Invoke-SkillsManifestHealthCheck.ps1`.
