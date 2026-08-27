# Domain 2: Deep Code Analysis

**Purpose**: Conduct a comprehensive static and runtime-pattern analysis of the entire codebase — every PowerShell module, script, config file, Dockerfile, and test file — to identify bugs, logic errors, concurrency hazards, resource leaks, edge-case failures, and runtime correctness issues. This domain merges the former Domain 2 (Runtime Correctness) and Domain 8 (Static Code Analysis) into a single unified survey.

**Trigger**: Every audit cycle. In sequential mode, run as the penultimate survey domain before regression testing. In parallel mode, this domain is independent and can run concurrently with any other read-only domain.

---

## Phase 1 — Pre-flight: Load automated scan + AQE results

Before starting manual analysis, load findings from both the pre-flight automated sweep and the AQE quality scan:

```powershell
$scanDate = (Get-Date -Format "yyyy-MM-dd")
$scanPath = Join-Path $HOME "salmon-orchestrator\Tasks\Logs\automated-scan-$scanDate.json"
if (Test-Path $scanPath) {
    $automatedFindings = Get-Content $scanPath -Raw | ConvertFrom-Json
    Write-Host "Loaded $($automatedFindings.findings.Count) automated findings from $scanPath"
} else {
    Write-Host "WARNING: No automated scan results found. Run Invoke-AutomatedScan.ps1 first."
}

# Load AQE quality scan results (non-blocking if unavailable)
$aqePath = Join-Path $HOME "salmon-orchestrator\Tasks\Logs\aqe-scan-$scanDate.json"
if (Test-Path $aqePath) {
    $aqeFindings = Get-Content $aqePath -Raw | ConvertFrom-Json
    if ($aqeFindings.available) {
        Write-Host "Loaded $($aqeFindings.findings.Count) AQE findings from $aqePath"
        # Extract quality_assess and defect_predict results for this domain
        $qualityScores = $aqeFindings.findings | Where-Object { $_.scan -eq "quality-assess" }
        $defectPredictions = $aqeFindings.findings | Where-Object { $_.scan -eq "defect-predict" }
    } else {
        Write-Host "AQE bridge was unreachable — continuing with grep-based scan only."
    }
} else {
    Write-Host "NOTE: No AQE scan results found. Run Invoke-AqeAuditScan.ps1 for quality scorecards."
}
```

The automated scan covers:
- **Deprecated patterns**: Write-Host, `Select-Object -Property *`, `Add-Content` without `-Encoding`
- **Concurrency hazards**: `ForEach-Object -Parallel`, `Start-ThreadJob`, `$script:` variable access, sync primitives
- **Retry/timeout patterns**: `Start-Sleep`, retry/backoff logic
- **Error swallowing**: `Out-Null`, `2>$null`, `-ErrorAction SilentlyContinue`, empty `catch` blocks
- **Atomic file writes**: Direct `Set-Content`/`Out-File` without temp-file pattern
- **Pinned Docker tags**: `FROM` with floating tags (`:latest`, `:stable`, `:lts`)
- **Canonical section headings**: `## Constraints` and `## Lessons Learned` violations
- **Module parser validation**: PowerShell syntax errors
- **TOCTOU**: `Test-Path` followed by separate write call

The AQE scan adds (when bridge is available):
- **quality_assess**: 4-pillar scorecard (coverage, complexity, maintainability, security) for key modules — use these scores to prioritize which files need the deepest manual analysis
- **defect_predict**: Predictions for defect-prone areas in `Skills/Docker/Modules/` — cross-reference predicted hotspots with automated scan findings to identify high-risk files

Use these results as the starting point. For each automated finding, verify the diagnosis and reclassify if needed. For AQE quality scores below threshold (coverage < 50%, security score < 70%), prioritize those files for thorough manual analysis. Add any findings the automation missed.

---

## Phase 2 — File Enumeration

Enumerate every source file. Start from the file list in the automated scan and add any paths the scan didn't cover:

- `Skills/Docker/`
- `Skills/Docker/Modules/Interclaw.*/`
- `Infrastructure/`
- `Skills/Bookkeeping/Scripts/`
- `Orchestrator/Orchestration/`
- `Skills/Workflows/Cowork/` (deprecated original at `Skills/Cowork/`)
- `Skills/Shared/`
- `Skills/Tavily/`
- `Skills/AQE/`
- `Skills/Marketer/`
- `Skills/Email/`
- `Skills/Tasks/`
- `Configuration/`
- `docs/Reference/`
- `Tasks/` (active plans — verify plan logic is sound and references resolve)

> **Note**: External third-party skill trees are not considered codebase-owned source code.

---

## Phase 3 — Manual Line-by-Line Static Analysis

For every file not fully covered by automated findings, perform line-by-line analysis. For each line, ask:

- **Logic bug**: Wrong value, wrong comparison, wrong operator, wrong index, wrong variable?
- **Null/empty hazard**: Can a variable be `$null`, `$false`, empty, or `$Error` when the next line assumes populated?
- **Type mismatch**: Wrong cast, missing type check, property access on object that may lack it?
- **Cmdlet misuse**: Wrong parameter name, missing required param, wrong position, pipeline mismatch?
- **Error handling gap**: Call that can fail has no `try/catch`, no `-ErrorAction`, no `$?` check?
- **Resource leak**: File handle, stream, HTTP response opened but not guaranteed closed?
- **Race condition** (from Domain 2): Two concurrent agents, threads, or containers write to same file, registry key, or shared variable without locking?
- **Hard-coded assumption**: Path separator, drive letter, env var, IP, port, timeout, retry that breaks on different host/OS?
- **Off-by-one / fencepost**: Loop bound `<` vs `<=`, array starts at 1 when 0-based, pagination offset?
- **Deprecated / removed API**: Cmdlet or .NET API deprecated in PowerShell 7?
- **Encoding / locale bug**: File written with default encoding, case-sensitive comparison when insensitive needed?
- **Security / secret exposure**: Secret logged, written to file, passed as CLI arg, in error message?
- **Spelling / identifier mismatch**: Variable typo, function name wrong, param misspelled, config key mismatch?
- **Missing input validation**: Parameter expects non-null but has no `[ValidateNotNullOrEmpty()]`?
- **Infinite loop / runaway recursion**: Loop with no exit, or exit condition unreachable?
- **Module-state in parallel**: `[void]` function writes `$script:` variables but called from `ForEach-Object -Parallel`?
- **Test-then-act TOCTOU**: `if (Test-Path $path) { Set-Content $path ... }` — separate check and write?

---

## Phase 4 — Concurrency & Runtime-Pattern Analysis (merged from former Domain 2)

### 4a. Enumerate concurrent-access points

For every file with parallel constructs found by the automated scan, manually verify:
- Shared mutable state access (module-scoped variables, global caches, hashtable refs)
- Lock-free read/write to files or registries from concurrent callers
- PowerShell runspaces, jobs, `Start-ThreadJob`, `ForEach-Object -Parallel`
- `lock` / `Monitor` / `Mutex` / `Semaphore` — verify scope, ordering, and timeout
- Docker Swarm API calls that can race with concurrent orchestrator operations

### 4b. Analyse retry / timeout / backoff chains

For every file flagged by the automated scan, manually verify:
- Retry loops have exponential backoff or jitter (not fixed-interval)
- Retry loops capture errors via `-ErrorVariable` (not `-ErrorAction SilentlyContinue` alone)
- Hard-coded timeouts are long enough for real-world conditions
- No infinite retry patterns (retry loop with no max count)

### 4c. Trace error-propagation paths

For the top 5 busiest functions in each module with error-swallowing patterns, trace:
- Are there paths where an exception escapes unhandled?
- Are there `catch { }` blocks (empty catch) that silently drop errors?
- Are there functions returning `$null` on failure where callers expect non-null?
- Are there `| Out-Null` or `[void]()` patterns discarding error-producing expressions?

### 4d. Resource-lifecycle hygiene

For all `New-Object`, `New-*` cmdlets that create disposable resources:
- Is every resource wrapped in `try/finally` or `using`?
- Are temp files cleaned up in `finally` blocks (not just on success)?
- Are `[System.IO.Stream]` / `[System.Net.Http.HttpClient]` instances disposed?

---

## Phase 5 — Log Findings

Log each distinct bug as a draft plan to `Tasks/Code/Drafts/domain-2/`. Include the file path, line number, bug class, and a brief diagnosis. Do NOT collapse multiple bugs into one finding. The consolidation script groups related findings into plans by file path overlap.

Use `Write-DraftPlan` for each finding:

```powershell
. ./Write-DraftPlan.ps1
Write-DraftPlan -Domain "domain-2" -Severity <severity> -BlastRadius <blast> `
    -Title "<file>: <bug-class> - <brief>" `
    -Detail "<diagnosis and suggested fix>" `
    -Files @("<affected-file-path>")
```

---

## Scoring

| Severity | Description |
|----------|-------------|
| **Critical** | Will cause data loss, security breach, deployment failure, or container crash in normal operation |
| **High** | Will cause incorrect behaviour, silent data corruption, partial failure requiring manual recovery, or unsynchronized concurrent write to shared state |
| **Medium** | Edge-case bug, fragile assumption, missing error handling, retry loop without backoff, hard-coded timeout that causes spurious failures |
| **Low** | Cosmetic, non-functional, minor encoding/formatting assumption, documentation gap |
