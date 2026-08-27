# Domain 3: Codebase Health & Maintenance

**Purpose**: Scan the codebase for general maintenance gaps — missing tests, dead code, undocumented public surfaces, type safety lapses, and documentation coverage. This domain ensures session plans include health-preserving work alongside structural fixes.

> **Note**: Deprecated pattern scanning (Write-Host, `Select-Object -Property *`, `Add-Content` without `-Encoding`) has been moved to the automated pre-flight sweep (`Invoke-AutomatedScan.ps1`, Scan 1) and is no longer part of this domain. Load automated scan results and cross-reference findings rather than re-scanning.

**Trigger**: Run this survey every alignment audit cycle, regardless of other domains. Cumulative health debt should be addressed iteratively — each pass produces targeted session plans, not an exhaustive cleanup.

**Survey procedure**:

### Phase 0 — Automated pre-sweep (test-refactor-coverage + AQE)

Before manual survey work, invoke the automated test-refactor-coverage script to run inventory, gap detection, waste/orphan pruning, and suite validation. This replaces steps 1–3 below, which previously performed these tasks inline.

```powershell
$sweepResults = & (Resolve-Path "Skills/Docker/Tests/test-refactor-coverage.ps1") -WriteDrafts -PassThru -SkipCoverage
```

Additionally, load AQE quality scan results (if available from Phase 0):

```powershell
$scanDate = (Get-Date -Format "yyyy-MM-dd")
$aqePath = Join-Path $repoRoot "Tasks\Logs\aqe-scan-$scanDate.json"
if (Test-Path $aqePath) {
    $aqeFindings = Get-Content $aqePath -Raw | ConvertFrom-Json
    if ($aqeFindings.available) {
        $qualityScores = $aqeFindings.findings | Where-Object { $_.scan -eq "quality-assess" }
        # Use quality scorecards to identify modules with low maintainability or coverage scores
        # Cross-reference with sweep results to confirm test gaps
    }
}
```

The sweep handles:
- **Source-to-test mapping** — enumerates all scripts across `Skills/Docker/Modules/`, `Skills/Docker/`, `Skills/Bookkeeping/Scripts/`, `Orchestrator/Orchestration/`, `Skills/Workflows/Cowork/Scripts/`, `Skills/AQE/`, `Skills/Marketer/` and maps them to their test files
- **Gap detection** — identifies uncovered source files, partial coverage, and untested exported functions
- **Waste/orphan pruning** — detects orphan test files, empty/dormant test files, always-skipped tests, and dead source scripts
- **Suite validation** — runs the full Pester test suite and captures failures/skips
- **Draft plans** — writes draft plan findings for each gap, orphan, dead file, and test failure (via `-WriteDrafts`)

The `-SkipCoverage` flag skips the slow code-coverage analysis (command-level hit/miss counts) while still performing file-level inventory and gap detection. To include code coverage, omit `-SkipCoverage`.

**Divergence**: If the sweep script fails or cannot run (environment issues), fall back to the manual steps 1–3 below.

### Step 1 — Read sweep results (test gap detection)

After the sweep completes, read `$sweepResults` to identify test gaps:

```powershell
$sweepResults.phase1_inventory   # Total/covered/partial/uncovered counts + file lists
$sweepResults.phase2_waste       # Orphans, empty files, stale functions, dead sources
$sweepResults.phase3_validation  # Suite pass/fail/skip results
```

Key fields for step 1 findings:
- `$sweepResults.phase1_inventory.uncoveredFiles` — modules/scripts with no matching test file → log as **High** findings
- `$sweepResults.phase1_inventory.partialFiles` — modules with coverage below 80% → log as **Medium** findings
- `$sweepResults.phase2_waste.staleFuncTests` — exported functions lacking a Describe/It block → log as **Medium** findings

If the sweep wrote draft plans (via `-WriteDrafts`), review them at `Tasks/Code/Drafts/domain-3/` and confirm the severity and scope are correct. Adjust if needed.

### Step 2 — Read sweep results (Skills/ subdirectory gaps)

The sweep already enumerates all `Skills/` subdirectories listed above. Review its uncovered/partial findings filtered by `Category`:
- `accountant` → scripts under `Skills/Bookkeeping/Scripts/`
- `opencode` + `opencode-scripts` → scripts under `Orchestrator/Orchestration/`
- `cowork` → scripts under `Skills/Workflows/Cowork/Scripts/`
- `aqe` → scripts under `Skills/AQE/`
- `marketer` → scripts under `Skills/Marketer/`

Log any additional Media findings for uncovered Skills/ scripts. The sweep's draft plans already cover core module gaps; Skills/ gaps are downgraded to **Medium** per the original rubric.

### Step 3 — Validate test execution (from sweep results)

The sweep's Phase 3 already ran the full suite. Read its results:

```powershell
$sweepResults.phase3_validation.summary    # Total/Passed/Failed/Skipped counts
$sweepResults.phase3_validation.failures   # Per-failure detail (Describe, It, Error)
$sweepResults.phase3_validation.skips     # Per-skip detail (Describe, It)
```

If `$sweepResults.phase3_validation.failures` is not empty, review each failure. The sweep already wrote draft plans for failures via `-WriteDrafts`. Confirm each failure's diagnosis and adjust if the sweep's error capture is incomplete.

**Divergence**: If the sweep's suite validation was skipped or returned no results, run the full suite directly:
```
Invoke-Pester -Path Skills/Docker/Tests/ -PassThru
```

4. **Find dead code (deep analysis)**:
   The automated sweep already handled test-adjacent dead code (orphan test files, empty/dormant tests, always-skipped tests, dead source scripts with no callers). Remaining deep dead code analysis:
   - Scan each module for functions that are defined but never called within the module, not exported, and not referenced in any script outside the module
   - For scripts, check unused parameter names and variables assigned but never read
   - Check for parameters that always receive the same value across every call site (candidate for inlining or removal)
   - **Findings**: Log each dead code finding not already covered by the sweep

5. **Check documentation coverage**:
   - For every public function in `Skills/Docker/Modules/Interclaw.*/Public/`, verify it has a help comment block with at least `.SYNOPSIS` and `.PARAMETER` entries for each parameter
   - For scripts in `Skills/Docker/`, verify the top-level entry point has a comment block describing purpose, arguments, and exit codes
   - **Findings**: Log each documentation gap

6. **Check type safety**:
   - Scan all `param()` blocks for parameters that lack a type constraint (`[string]`, `[int]`, `[bool]`, `[hashtable]`, etc.)
   - Scan `[ValidateSet()]`, `[ValidateRange()]`, `[ValidateScript()]`, `[ValidateNotNull()]`, `[AllowNull()]` usage — note parameters where validation is missing but the domain implies constraints
   - Check for `[OutputType()]` on public functions — missing output type annotations are a finding
   - **Findings**: Log each type safety gap

7. **Check audit log archival compliance**:
   - Count files matching `Tasks/Logs/alignment-audit-*.jsonl`
   - If count ≤ 10, write an audit log entry with action "pass": "Audit log count (<N>) within retention limit" — no session plan needed
   - If count > 10, log a finding for archival remediation

8. **Log findings**: Log each finding as a draft plan via `Write-DraftPlan`

**Scoring**:
- **High**: An exported public function has zero test coverage and no tests exist in the test file — regressions will ship silently
- **High**: Dead code that mutates state or accesses external resources (file, network, registry) — side-effect risk with no observable benefit
- **Medium**: Missing help comments on public functions; untested functions that are not exported (tested by callers indirectly, but fragile)
- **Medium**: Missing `[OutputType()]` annotations; missing type constraint on a parameter where the type is obvious from usage
- **Low**: Audit log archival not a concern yet (count ≤ 10)
