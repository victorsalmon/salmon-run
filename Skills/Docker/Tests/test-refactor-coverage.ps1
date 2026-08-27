<#
.SYNOPSIS
    Autonomous test-coverage refactor: inventory, gap detection, waste pruning, suite validation.
.DESCRIPTION
    Consolidates the deterministic Pester-related work of Audit Domains 3 (Codebase Health
    steps 1-4) and 4 (Full Regression Coverage) with new dead/waste pruning logic.

    Phases:
      1 - Inventory & Gap Detection: enumerate source scripts, test files, run code coverage
      2 - Waste & Orphan Pruning: find orphan/empty/skipped tests, dead source
      3 - Suite Validation: run full Pester suite, capture failures and skips
      4 - Output: write JSON summary, optional Write-DraftPlan findings, optional cleanup

    Always writes Tasks/Logs/test-refactor-coverage-<date>.json.
    Read-only by default (-Cleanup requires explicit opt-in for destructive operations).
.PARAMETER WriteDrafts
    Call Write-DraftPlan.ps1 for each finding (high-severity gaps, orphan tests, failures).
.PARAMETER Cleanup
    Delete orphan test files and empty/zero-value test files permanently.
.PARAMETER SuiteOnly
    Skip Phases 1-2 (inventory and pruning), only run Phase 3 (suite validation).
.PARAMETER SkipCoverage
    Skip the slow code-coverage scan; still do file-level inventory and gap detection.
.PARAMETER PassThru
    Return the structured results object instead of printing console output.
.EXAMPLE
    ./test-refactor-coverage.ps1
.EXAMPLE
    ./test-refactor-coverage.ps1 -WriteDrafts -SkipCoverage
.EXAMPLE
    ./test-refactor-coverage.ps1 -SuiteOnly
#>
param(
    [switch]$WriteDrafts,
    [switch]$Cleanup,
    [switch]$SuiteOnly,
    [switch]$SkipCoverage,
    [switch]$PassThru
)

$ErrorActionPreference = "Continue"

# ── Path resolution ───────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = $ScriptDir
while ($RepoRoot) {
    if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
    if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
    $parent = Split-Path $RepoRoot -Parent
    if ($parent -eq $RepoRoot) { $RepoRoot = $null; break }
    $RepoRoot = $parent
}
if (-not $RepoRoot) { $RepoRoot = Join-Path $HOME "intersite-orchestrator" }

$TestDir = $ScriptDir
$LogDir = Join-Path $RepoRoot "Tasks\Logs"
$null = New-Item -ItemType Directory -Path $LogDir -Force
$DateStamp = Get-Date -Format "yyyy-MM-dd"
$LogPath = Join-Path $LogDir "test-refactor-coverage-$DateStamp.json"
$DraftPlanScript = Join-Path $RepoRoot "Skills\\Orchestration\Workflows\Audit\Write-DraftPlan.ps1"

# ── Result accumulator ────────────────────────────────────────────────────
$Result = [PSCustomObject]@{
    timestamp       = (Get-Date -Format "o")
    repoRoot        = $RepoRoot
    parameters      = @{
        WriteDrafts   = [bool]$WriteDrafts
        Cleanup       = [bool]$Cleanup
        SuiteOnly     = [bool]$SuiteOnly
        SkipCoverage  = [bool]$SkipCoverage
    }
    phase1_inventory = $null
    phase2_waste     = $null
    phase3_validation = $null
    summary          = $null
    cleanup_actions  = @()
}

# ── Source directories to scan ────────────────────────────────────────────
$SourceDirectories = @(
    @{ Path = "Skills\Docker\Modules";        Pattern = "SalmonRun.*\Public\*.ps1";     Category = "module-public" }
    @{ Path = "Skills\Docker\Modules";        Pattern = "SalmonRun.*\Private\*.ps1";    Category = "module-private" }
    @{ Path = "Skills\Docker\Modules";        Pattern = "Interclaw.*\Public\*.ps1";     Category = "module-public" }
    @{ Path = "Skills\Docker\Modules";        Pattern = "Interclaw.*\Private\*.ps1";    Category = "module-private" }
    @{ Path = "Skills\Docker";               Pattern = "*.ps1";                         Category = "deploy-script" }
    @{ Path = "Skills\Bookkeeping\Scripts";    Pattern = "*.ps1";                         Category = "bookkeeping" }
    @{ Path = "Skills\\Orchestration";             Pattern = "*.ps1";                         Category = "opencode" }
    @{ Path = "Skills\\Orchestration\Scripts";      Pattern = "*.ps1";                         Category = "opencode-scripts" }
    @{ Path = "Skills\Cowork\Scripts";        Pattern = "*.ps1";                         Category = "cowork" }
    @{ Path = "Skills\AQE";                  Pattern = "*.ps1";                         Category = "aqe" }
    @{ Path = "Skills\Marketer";             Pattern = "*.ps1";                         Category = "marketer" }
)

# ── Helper: resolve category from test file path ───────────────────────────
function Get-CategoryForDir($Path) {
    $p = $Path.Replace($RepoRoot, "").TrimStart("\").Replace("/", "\")
    if ($p -match "^Skills\\Docker\\Modules\\(SalmonRun|Interclaw)\.(\w+)") { return "module-$( $matches[2] )" }
    if ($p -match "^Skills\\Docker\\(.+)\.ps1$")                 { return "deploy-script" }
    if ($p -match "^Skills\\Bookkeeping\\Scripts")                 { return "bookkeeping" }
    if ($p -match "^Skills\\OpenCode\\Scripts")                   { return "opencode-scripts" }
    if ($p -match "^Skills\\OpenCode")                           { return "opencode" }
    if ($p -match "^Skills\\Cowork\\Scripts")                     { return "cowork" }
    if ($p -match "^Skills\\AQE")                                { return "aqe" }
    if ($p -match "^Skills\\Marketer")                           { return "marketer" }
    return "other"
}

# ── Helper: count It blocks in a test file ────────────────────────────────
function Get-ItBlockCount($Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $content = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return 0 }
    $matches = [regex]::Matches($content, '(?ms)^\s*It\s+')
    return $matches.Count
}

function Get-SkippedItCount($Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $content = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return 0 }
    $matches = [regex]::Matches($content, '(?ms)^\s*It\s+.+-\s*Skip\b')
    return $matches.Count
}

function Get-DescribeTitles($Path) {
    if (-not (Test-Path $Path)) { return @() }
    $lines = Get-Content -Path $Path -ErrorAction SilentlyContinue
    $titles = @()
    foreach ($line in $lines) {
        if ($line -match 'Describe\s+"([^"]+)"') { $titles += $matches[1] }
    }
    return $titles
}

# ── Helper: extract exported function names from a module ──────────────────
function Get-ExportedFunctions($ModuleDir) {
    $psd1 = Get-ChildItem -Path $ModuleDir -Filter "*.psd1" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($psd1) {
        $data = Import-PowerShellDataFile -Path $psd1.FullName -ErrorAction SilentlyContinue
        if ($data -and $data.FunctionsToExport) { return @($data.FunctionsToExport) }
    }
    $publicDir = Join-Path $ModuleDir "Public"
    if (Test-Path $publicDir) {
        return @(Get-ChildItem -Path $publicDir -Filter "*.ps1" | ForEach-Object { $_.BaseName })
    }
    return @()
}

# ── Helper: check if a function name is tested in a Describe block ────────
function Test-FunctionHasTest($FunctionName, $DescribeTitles) {
    $norm = $FunctionName -replace '-', ''
    foreach ($dt in $DescribeTitles) {
        $dtn = $dt -replace '-', ''
        if ($dtn -eq $norm) { return $true }
        if ($dtn -match [regex]::Escape($norm)) { return $true }
    }
    return $false
}

# ── Helper: write a draft plan finding ────────────────────────────────────
function Write-TestCoverageFinding {
    param(
        [string]$Severity,
        [string]$BlastRadius,
        [string]$Title,
        [string]$Detail,
        [string[]]$Files
    )
    if (-not (Test-Path $DraftPlanScript)) {
        Write-Warning "Write-DraftPlan.ps1 not found at $DraftPlanScript — skipping draft"
        return
    }
    try {
        & $DraftPlanScript -Domain "test-refactor-coverage" -Severity $Severity -BlastRadius $BlastRadius -Title $Title -Detail $Detail -Files $Files
    } catch {
        Write-Warning "Write-DraftPlan failed: $_"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1 — Inventory & Gap Detection
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "=== Phase 1: Inventory & Gap Detection ===" -ForegroundColor Cyan

$AllSourceFiles = @()
$AllTestFiles = @()
$SourceToTestMap = @{}
$TestToSourceMap = @{}

if (-not $SuiteOnly) {
    # ── Enumerate source files ────────────────────────────────────────────
    foreach ($spec in $SourceDirectories) {
        $fullDir = Join-Path $RepoRoot $spec.Path
        if (-not (Test-Path $fullDir)) { continue }
        $files = Get-ChildItem -Path $fullDir -Filter $spec.Pattern -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $rel = $f.FullName.Replace($RepoRoot, "").TrimStart("\")
            $AllSourceFiles += [PSCustomObject]@{
                Path     = $f.FullName
                Relative = $rel
                Name     = $f.Name
                Category = $spec.Category
                Status   = "unknown"
                TestFile = $null
                Coverage = $null
            }
        }
    }

    # ── Enumerate test files ──────────────────────────────────────────────
    $allTests = Get-ChildItem -Path $TestDir -Recurse -Filter "*.Tests.ps1" -File -ErrorAction SilentlyContinue
    foreach ($t in $allTests) {
        $rel = $t.FullName.Replace($RepoRoot, "").TrimStart("\")
        $itCount = Get-ItBlockCount $t.FullName
        $skipCount = Get-SkippedItCount $t.FullName
        $AllTestFiles += [PSCustomObject]@{
            Path        = $t.FullName
            Relative    = $rel
            Name        = $t.Name
            ItCount     = $itCount
            SkippedCount = $skipCount
            DescribeTitles = Get-DescribeTitles $t.FullName
            Category    = Get-CategoryForDir $t.FullName
            Status      = "active"
        }
    }

    # ── Build source-to-test mapping ──────────────────────────────────────
    # Convention: SalmonRun.X.Tests.ps1   → SalmonRun.X/ module
    #             Interclaw.X.Tests.ps1   → legacy Interclaw.X/ shim
    #             ScriptName.Tests.ps1   → ScriptName.ps1 in same-origin dir
    #             Bookkeeping.*.Tests.ps1 → Skills/Bookkeeping/Scripts/
    #             OpenCode.Tests.ps1     → Orchestrator/Orchestration/
    #             Cowork.Tests.ps1       → Skills/Cowork/Scripts/
    #             AQE.Tests.ps1          → Skills/AQE/

    # Build lookup: by test-filename prefix → source name pattern
    $TestNameMap = @{}
    $TestNameMap["SalmonRun."] = @{ Type = "module-prefix"; Prefix = "SalmonRun."; SrcPrefix = "SalmonRun." }
    $TestNameMap["Interclaw."] = @{ Type = "module-prefix"; Prefix = "Interclaw."; SrcPrefix = "Interclaw." }
    $TestNameMap["OpenCode"] = @{ Type = "exact"; Name = "OpenCode.Tests.ps1"; SrcCategory = "opencode" }
    $TestNameMap["Cowork"] = @{ Type = "exact"; Name = "Cowork.Tests.ps1"; SrcCategory = "cowork" }
    $TestNameMap["Bookkeeping.Tests"] = @{ Type = "exact"; Name = "Bookkeeping.Tests.ps1"; SrcCategory = "bookkeeping" }

    # For each source file, find matching test
    for ($i = 0; $i -lt $AllSourceFiles.Count; $i++) {
        $src = $AllSourceFiles[$i]
        $matchedTest = $null

        # Module files: SalmonRun.X.Tests.ps1 → SalmonRun.X/Public/*.ps1
        #              Interclaw.X.Tests.ps1 → legacy Interclaw.X/Public/*.ps1
        if ($src.Category -eq "module-public" -or $src.Category -eq "module-private") {
            $moduleName = ""
            if ($src.Relative -match "(SalmonRun|Interclaw)\.(\w+)\\") {
                $moduleName = $matches[2]
            }
            $expectedTestName = "SalmonRun.$moduleName.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if (-not $found) {
                $expectedTestName = "Interclaw.$moduleName.Tests.ps1"
                $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            }
            if ($found) { $matchedTest = $found }
        }

        # Deploy scripts: ScriptName.Tests.ps1 → ScriptName.ps1
        if (-not $matchedTest -and $src.Category -eq "deploy-script") {
            $expectedTestName = "$($src.Name -replace '\.ps1$', '').Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        # Bookkeeping scripts
        if (-not $matchedTest -and $src.Category -eq "bookkeeping") {
            $expectedTestName = "Bookkeeping.Scripts.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if (-not $found) { $found = $AllTestFiles | Where-Object { $_.Category -eq "bookkeeping" } | Select-Object -First 1 }
            if ($found) { $matchedTest = $found }
        }

        # OpenCode scripts (top-level)
        if (-not $matchedTest -and $src.Category -eq "opencode") {
            $expectedTestName = "OpenCode.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        # OpenCode/Scripts
        if (-not $matchedTest -and $src.Category -eq "opencode-scripts") {
            $expectedTestName = "OpenCode.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        # Cowork scripts
        if (-not $matchedTest -and $src.Category -eq "cowork") {
            $expectedTestName = "Cowork.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        # AQE scripts
        if (-not $matchedTest -and $src.Category -eq "aqe") {
            $expectedTestName = "AQE.Tests.ps1"
            $found = $AllTestFiles | Where-Object { $_.Name -eq $expectedTestName } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        # Marketer scripts
        if (-not $matchedTest -and $src.Category -eq "marketer") {
            $found = $AllTestFiles | Where-Object { $_.Category -eq "marketer" } | Select-Object -First 1
            if ($found) { $matchedTest = $found }
        }

        if ($matchedTest) {
            $AllSourceFiles[$i].TestFile = $matchedTest.Path
        }
    }

    # ── Run code coverage (unless SkipCoverage) ───────────────────────────
    if (-not $SkipCoverage) {
        Write-Host "  Running code coverage analysis (Invoke-Pester -CodeCoverage)..." -ForegroundColor Yellow
        try {
            $covResult = Invoke-Pester -Path $TestDir -CodeCoverage @{ Enabled = $true } -PassThru -ErrorAction SilentlyContinue
            $covData = @{}
            if ($covResult -and $covResult.CodeCoverage) {
                foreach ($cc in $covResult.CodeCoverage) {
                    $filePath = $cc.File
                    $total = $cc.HitCommands.Count + $cc.MissedCommands.Count
                    $covered = $cc.HitCommands.Count
                    $covData[$filePath] = [PSCustomObject]@{
                        File          = $filePath
                        CoveredCount  = $covered
                        MissedCount   = $total - $covered
                        TotalCommands = $total
                        CoveragePct   = if ($total -gt 0) { [math]::Round($covered / $total * 100, 1) } else { 0 }
                    }
                }
            }
        } catch {
            Write-Warning "  Code coverage analysis failed: $_"
            $covData = @{}
        }
    } else {
        $covData = @{}
    }

    # ── Score each source file ────────────────────────────────────────────
    for ($i = 0; $i -lt $AllSourceFiles.Count; $i++) {
        $src = $AllSourceFiles[$i]
        if (-not $src.TestFile) {
            $AllSourceFiles[$i].Status = "uncovered"
            $AllSourceFiles[$i].Coverage = [PSCustomObject]@{ CoveredCount = 0; MissedCount = 0; TotalCommands = 0; CoveragePct = 0 }
        } else {
            $cov = $covData[$src.Path]
            if ($cov) {
                $AllSourceFiles[$i].Coverage = $cov
                $AllSourceFiles[$i].Status = if ($cov.CoveragePct -ge 80) { "covered" } elseif ($cov.CoveragePct -gt 0) { "partial" } else { "uncovered" }
            } else {
                # Test file exists but coverage not measured — check it blocks
                $itCount = Get-ItBlockCount $src.TestFile
                $AllSourceFiles[$i].Status = if ($itCount -gt 0) { "covered" } else { "uncovered" }
                $AllSourceFiles[$i].Coverage = [PSCustomObject]@{ CoveredCount = -1; MissedCount = -1; TotalCommands = -1; CoveragePct = $null }
            }
        }
    }

    # ── Group results ─────────────────────────────────────────────────────
    $uncovered = $AllSourceFiles | Where-Object { $_.Status -eq "uncovered" }
    $partial   = $AllSourceFiles | Where-Object { $_.Status -eq "partial" }
    $covered   = $AllSourceFiles | Where-Object { $_.Status -eq "covered" }

    $Phase1Result = [PSCustomObject]@{
        totalSourceFiles  = $AllSourceFiles.Count
        totalTestFiles    = $AllTestFiles.Count
        covered           = $covered.Count
        partial           = $partial.Count
        uncovered         = $uncovered.Count
        uncoveredFiles    = @($uncovered | ForEach-Object { $_.Relative })
        partialFiles      = @($partial | ForEach-Object { $_.Relative })
        sourceFiles       = @($AllSourceFiles)
        testFiles         = @($AllTestFiles)
    }

    Write-Host "  Source files: $($AllSourceFiles.Count) | Test files: $($AllTestFiles.Count)" -ForegroundColor Gray
    Write-Host "  Covered: $($covered.Count) | Partial: $($partial.Count) | Uncovered: $($uncovered.Count)" -ForegroundColor $(if ($uncovered.Count -eq 0) { "Green" } else { "Yellow" })
    if ($uncovered.Count -gt 0) {
        Write-Host "  Uncovered files:" -ForegroundColor Yellow
        $uncovered | ForEach-Object { Write-Host "    - $($_.Relative)" -ForegroundColor Gray }
    }
    if ($partial.Count -gt 0) {
        Write-Host "  Partial coverage files:" -ForegroundColor Yellow
        $partial | ForEach-Object { Write-Host "    - $($_.Relative) ($($_.Coverage.CoveragePct)%)" -ForegroundColor Gray }
    }

    # ── Write draft plans for uncovered gaps ──────────────────────────────
    if ($WriteDrafts -and $uncovered.Count -gt 0) {
        $CategorySummary = $uncovered | Group-Object Category
        foreach ($grp in $CategorySummary) {
            $fileList = @($grp.Group | ForEach-Object { $_.Relative })
            Write-TestCoverageFinding -Severity high -BlastRadius high `
                -Title "Uncovered source files in $($grp.Name)" `
                -Detail "$($grp.Count) source file(s) have no matching Pester test file. Category: $($grp.Name). Files: $($fileList -join ', ')" `
                -Files $fileList
        }
    }
    if ($WriteDrafts -and $partial.Count -gt 0) {
        $fileList = @($partial | ForEach-Object { $_.Relative })
        Write-TestCoverageFinding -Severity medium -BlastRadius medium `
            -Title "Partial test coverage detected" `
            -Detail "$($partial.Count) source file(s) have coverage below 80%. Details: $(($partial | ForEach-Object { "$($_.Relative) = $($_.Coverage.CoveragePct)%" }) -join '; ')" `
            -Files $fileList
    }
} else {
    $Phase1Result = $null
    Write-Host "  Skipped (SuiteOnly mode)" -ForegroundColor Gray
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2 — Waste & Orphan Pruning
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "=== Phase 2: Waste & Orphan Pruning ===" -ForegroundColor Cyan

$OrphanTestFiles = @()
$EmptyTestFiles  = @()
$StaleFuncTests  = @()
$AlwaysSkipped   = @()
$DeadSourceFiles = @()
$CleanupActions  = @()

if (-not $SuiteOnly) {
    # ── 2a. Orphan test detection ─────────────────────────────────────────
    foreach ($tf in $AllTestFiles) {
        if ($tf.Name -match "^(?:SalmonRun|Interclaw)\.(\w+)\.Tests\.ps1$") {
            $moduleName = $matches[1]
            $moduleDir = Join-Path $RepoRoot "Skills\Docker\Modules\SalmonRun.$moduleName"
            if (-not (Test-Path $moduleDir)) {
                $moduleDir = Join-Path $RepoRoot "Skills\Docker\Modules\Interclaw.$moduleName"
                if (-not (Test-Path $moduleDir)) {
                    $OrphanTestFiles += $tf
                }
            }
        } elseif ($tf.Name -match "^(\w+)\.Tests\.ps1$") {
            $baseName = $matches[1]
            # Check deploy scripts
            $srcScript = Join-Path $RepoRoot "Skills\Docker\$baseName.ps1"
            if (-not (Test-Path $srcScript)) {
                $OrphanTestFiles += $tf
            }
        }
    }

    # ── 2b. Empty/zero-value test detection ───────────────────────────────
    foreach ($tf in $AllTestFiles) {
        if ($tf.ItCount -eq 0) {
            $EmptyTestFiles += $tf
        } elseif ($tf.ItCount -eq $tf.SkippedCount -and $tf.ItCount -gt 0) {
            $AlwaysSkipped += $tf
        }
        # Check for "Template" tag = dormant
        $isTemplate = $false
        $content = Get-Content -Path $tf.Path -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match '-Tag\s+"Template"') {
            $EmptyTestFiles += $tf
            $isTemplate = $true
        }
    }

    # ── 2c. Function-staleness scan ──────────────────────────────────────
    foreach ($tf in $AllTestFiles) {
        if ($tf.Name -match "^(?:SalmonRun|Interclaw)\.(\w+)\.Tests\.ps1$") {
            $moduleName = $matches[1]
            $moduleDir = Join-Path $RepoRoot "Skills\Docker\Modules\SalmonRun.$moduleName"
            if (-not (Test-Path $moduleDir)) {
                $moduleDir = Join-Path $RepoRoot "Skills\Docker\Modules\Interclaw.$moduleName"
            }
            if (Test-Path $moduleDir) {
                $exportedFuncs = Get-ExportedFunctions $moduleDir
                if ($exportedFuncs.Count -gt 0) {
                    $describeTitles = $tf.DescribeTitles
                    foreach ($func in $exportedFuncs) {
                        $hasTest = Test-FunctionHasTest $func $describeTitles
                        if (-not $hasTest) {
                            $StaleFuncTests += [PSCustomObject]@{
                                TestFile = $tf.Relative
                                Function = $func
                                Module   = $moduleName
                            }
                        }
                    }
                }
            }
        }
    }

    # ── 2d. Dead source files ────────────────────────────────────────────
    # Batch grep: find standalone scripts referenced by name in other .ps1 files.
    # If the name only appears in its own file (or nowhere), the script is dead.
    $standaloneSrcs = $AllSourceFiles | Where-Object {
        $_.Category -ne "module-public" -and $_.Category -ne "module-private"
    }
    if ($standaloneSrcs.Count -gt 0) {
        $allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.ps1", "*.psm1", "*.psd1" -File -ErrorAction SilentlyContinue
        $allFilePaths = @($allFiles | Select-Object -ExpandProperty FullName)
        $scriptNames = @($standaloneSrcs | ForEach-Object { $_.Name -replace '\.ps1$', '' })
        $namePattern = $scriptNames -join '|'
        $allHits = Select-String -Path $allFilePaths -Pattern $scriptNames -SimpleMatch -ErrorAction SilentlyContinue
        $callerCount = @{}
        if ($allHits) {
            foreach ($hit in $allHits) {
                $basename = $hit.Pattern
                if (-not $callerCount.ContainsKey($basename)) { $callerCount[$basename] = 0 }
                $callerCount[$basename]++
            }
        }
        foreach ($src in $standaloneSrcs) {
            $nameWithoutExt = $src.Name -replace '\.ps1$', ''
            $count = if ($callerCount.ContainsKey($nameWithoutExt)) { $callerCount[$nameWithoutExt] } else { 0 }
            if ($count -le 1) {
                $DeadSourceFiles += $src
            }
        }
    }

    Write-Host "  Orphan test files: $($OrphanTestFiles.Count)" -ForegroundColor $(if ($OrphanTestFiles.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  Empty/zero-value test files: $($EmptyTestFiles.Count)" -ForegroundColor $(if ($EmptyTestFiles.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  Untested exported functions: $($StaleFuncTests.Count)" -ForegroundColor $(if ($StaleFuncTests.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  Always-skipped test files: $($AlwaysSkipped.Count)" -ForegroundColor $(if ($AlwaysSkipped.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  Dead source files (no callers): $($DeadSourceFiles.Count)" -ForegroundColor $(if ($DeadSourceFiles.Count -gt 0) { "Yellow" } else { "Green" })

    # ── List details ──────────────────────────────────────────────────────
    if ($OrphanTestFiles.Count -gt 0) {
        Write-Host "  Orphan test files:" -ForegroundColor Red
        $OrphanTestFiles | ForEach-Object { Write-Host "    - $($_.Relative)" -ForegroundColor Gray }
    }
    if ($EmptyTestFiles.Count -gt 0) {
        Write-Host "  Empty/zero-value test files:" -ForegroundColor Red
        $EmptyTestFiles | ForEach-Object { Write-Host "    - $($_.Relative) (It: $($_.ItCount), Skipped: $($_.SkippedCount))" -ForegroundColor Gray }
    }
    if ($StaleFuncTests.Count -gt 0) {
        Write-Host "  Untested exported functions:" -ForegroundColor Yellow
        $StaleFuncTests | Group-Object Module | ForEach-Object {
            Write-Host "    $($_.Name): $(($_.Group | ForEach-Object { $_.Function }) -join ', ')" -ForegroundColor Gray
        }
    }
    if ($AlwaysSkipped.Count -gt 0) {
        Write-Host "  Always-skipped test files (all tests skip):" -ForegroundColor Yellow
        $AlwaysSkipped | ForEach-Object { Write-Host "    - $($_.Relative)" -ForegroundColor Gray }
    }
    if ($DeadSourceFiles.Count -gt 0) {
        Write-Host "  Dead source files (no callers found):" -ForegroundColor Yellow
        $DeadSourceFiles | ForEach-Object { Write-Host "    - $($_.Relative)" -ForegroundColor Gray }
    }

    # ── Write draft plans ─────────────────────────────────────────────────
    if ($WriteDrafts) {
        if ($OrphanTestFiles.Count -gt 0) {
            $fileList = @($OrphanTestFiles | ForEach-Object { $_.Relative })
            Write-TestCoverageFinding -Severity high -BlastRadius medium `
                -Title "Orphan test files — source no longer exists" `
                -Detail "$($OrphanTestFiles.Count) test file(s) target modules or scripts that no longer exist. Recommend removal: $($fileList -join ', ')" `
                -Files $fileList
        }
        if ($EmptyTestFiles.Count -gt 0) {
            $fileList = @($EmptyTestFiles | ForEach-Object { $_.Relative })
            Write-TestCoverageFinding -Severity medium -BlastRadius medium `
                -Title "Empty or dormant test files" `
                -Detail "$($EmptyTestFiles.Count) test file(s) have zero It blocks or are tagged Template (dormant): $($fileList -join ', ')" `
                -Files $fileList
        }
        if ($StaleFuncTests.Count -gt 0) {
            $fileList = $StaleFuncTests | ForEach-Object { $_.Function } | Select-Object -Unique | ForEach-Object { "Skills/Docker/Modules/SalmonRun.$($_.Module)/Public/$_.ps1" }
            Write-TestCoverageFinding -Severity medium -BlastRadius low `
                -Title "Exported functions missing direct tests" `
                -Detail "$($StaleFuncTests.Count) exported function(s) lack a direct Describe/It block in their module's test file. Grouped by module: $(($StaleFuncTests | Group-Object Module | ForEach-Object { "$($_.Name): $(($_.Group | ForEach-Object { $_.Function }) -join ', ')" }) -join '; ')" `
                -Files $fileList
        }
    }

    # ── Cleanup mode: delete orphan/empty test files ──────────────────────
    if ($Cleanup) {
        $toDelete = @($OrphanTestFiles) + @($EmptyTestFiles)
        foreach ($del in $toDelete) {
            try {
                Remove-Item -LiteralPath $del.Path -Force
                $CleanupActions += "Deleted: $($del.Relative)"
                Write-Host "    Deleted: $($del.Relative)" -ForegroundColor Red
            } catch {
                Write-Warning "    Failed to delete $($del.Relative): $_"
            }
        }
    }
} else {
    Write-Host "  Skipped (SuiteOnly mode)" -ForegroundColor Gray
}

$Phase2Result = [PSCustomObject]@{
    orphanTestFiles       = @($OrphanTestFiles | ForEach-Object { $_.Relative })
    emptyTestFiles        = @($EmptyTestFiles | ForEach-Object { $_.Relative })
    staleFuncTests        = @($StaleFuncTests)
    alwaysSkippedFiles    = @($AlwaysSkipped | ForEach-Object { $_.Relative })
    deadSourceFiles       = @($DeadSourceFiles | ForEach-Object { $_.Relative })
    cleanupActions        = $CleanupActions
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3 — Suite Validation
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "=== Phase 3: Suite Validation ===" -ForegroundColor Cyan
Write-Host "  Running full Pester test suite..." -ForegroundColor Yellow

try {
    $suiteResult = Invoke-Pester -Path $TestDir -PassThru -ErrorAction SilentlyContinue
} catch {
    Write-Warning "  Pester suite execution failed: $_"
    $suiteResult = $null
}

$Failures = @()
$Skips = @()
$SuiteSummary = $null

if ($suiteResult) {
    $SuiteSummary = [PSCustomObject]@{
        totalCount  = $suiteResult.TotalCount
        passedCount = $suiteResult.PassedCount
        failedCount = $suiteResult.FailedCount
        skippedCount = $suiteResult.SkippedCount
    }

    # Capture failures from raw test results
    if ($suiteResult.FailedCount -gt 0 -and $suiteResult.Tests) {
        $Failures = $suiteResult.Tests | Where-Object { $_.Passed -eq $false -and $_.Skipped -eq $false } | ForEach-Object {
            $errMsg = if ($_.ErrorRecord) { $_.ErrorRecord[0].Exception.Message } else { "Unknown error" }
            [PSCustomObject]@{
                Describe = $_.Describe
                It       = $_.Name
                Error    = $errMsg
            }
        }
    }

    # Capture always-skipped tests
    if ($suiteResult.SkippedCount -gt 0 -and $suiteResult.Tests) {
        $Skips = $suiteResult.Tests | Where-Object { $_.Skipped } | ForEach-Object {
            [PSCustomObject]@{
                Describe = $_.Describe
                It       = $_.Name
            }
        }
    }

    Write-Host "  Total: $($suiteResult.TotalCount) | Passed: $($suiteResult.PassedCount) | Failed: $($suiteResult.FailedCount) | Skipped: $($suiteResult.SkippedCount)" -ForegroundColor $(if ($suiteResult.FailedCount -eq 0) { "Green" } else { "Red" })

    if ($Failures.Count -gt 0) {
        Write-Host "  Failures:" -ForegroundColor Red
        $Failures | ForEach-Object { Write-Host "    - [$($_.Describe)] $($_.It): $($_.Error)" -ForegroundColor Gray }
    }
    if ($Skips.Count -gt 0) {
        Write-Host "  Skipped tests:" -ForegroundColor Yellow
        $Skips | ForEach-Object { Write-Host "    - [$($_.Describe)] $($_.It)" -ForegroundColor Gray }
    }

    # ── Write draft plans for failures ────────────────────────────────────
    if ($WriteDrafts -and $Failures.Count -gt 0) {
        $detailLines = $Failures | ForEach-Object { "[$($_.Describe)] $($_.It): $($_.Error)" }
        Write-TestCoverageFinding -Severity high -BlastRadius critical `
            -Title "Pester test failures detected" `
            -Detail "$($Failures.Count) test(s) failed. Details: $($detailLines -join ' | ')" `
            -Files @("Skills/Docker/Tests/")
    }
} else {
    Write-Host "  Suite did not return results (possible environment issue)" -ForegroundColor Yellow
    $SuiteSummary = [PSCustomObject]@{
        totalCount   = 0
        passedCount  = 0
        failedCount  = 0
        skippedCount = 0
        error        = "Suite execution returned no results"
    }
}

$Phase3Result = [PSCustomObject]@{
    summary  = $SuiteSummary
    failures = @($Failures)
    skips    = @($Skips)
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4 — Output
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "=== Phase 4: Output ===" -ForegroundColor Cyan

$Summary = [PSCustomObject]@{
    phase1_inventory  = if ($Phase1Result) { @{ totalSource = $Phase1Result.totalSourceFiles; totalTest = $Phase1Result.totalTestFiles; covered = $Phase1Result.covered; partial = $Phase1Result.partial; uncovered = $Phase1Result.uncovered } } else { $null }
    phase2_waste      = @{ orphans = $Phase2Result.orphanTestFiles.Count; empty = $Phase2Result.emptyTestFiles.Count; stale = $Phase2Result.staleFuncTests.Count; alwaysSkipped = $Phase2Result.alwaysSkippedFiles.Count; deadSource = $Phase2Result.deadSourceFiles.Count; cleaned = $Phase2Result.cleanupActions.Count }
    phase3_validation = $Phase3Result.summary
}

$Result.phase1_inventory = $Phase1Result
$Result.phase2_waste = $Phase2Result
$Result.phase3_validation = $Phase3Result
$Result.summary = $Summary
$Result.cleanup_actions = $CleanupActions

# ── Write JSON summary ───────────────────────────────────────────────────
$ResultJson = $Result | ConvertTo-Json -Depth 5
$ResultJson | Set-Content -Path $LogPath -Encoding UTF8
Write-Host "  Summary written: $LogPath" -ForegroundColor Cyan

# ── Summary banner ────────────────────────────────────────────────────────
$bColor = if ($Summary.phase3_validation.failedCount -gt 0) { "Red" } else { "Green" }
Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor $bColor
Write-Host "│  Test Refactor & Coverage Summary                          │" -ForegroundColor $bColor
Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor $bColor
if ($Summary.phase1_inventory) {
    Write-Host "│  Source: $($Summary.phase1_inventory.totalSource) | Tests: $($Summary.phase1_inventory.totalTest)         │" -ForegroundColor $bColor
    Write-Host "│  Covered: $($Summary.phase1_inventory.covered) | Partial: $($Summary.phase1_inventory.partial) | Uncovered: $($Summary.phase1_inventory.uncovered)  │" -ForegroundColor $bColor
}
Write-Host "│  Orphans: $($Summary.phase2_waste.orphans) | Empty: $($Summary.phase2_waste.empty) | Stale funcs: $($Summary.phase2_waste.stale)  │" -ForegroundColor $bColor
Write-Host "│  Tests: $($Summary.phase3_validation.passedCount)/$($Summary.phase3_validation.totalCount) passed | $($Summary.phase3_validation.failedCount) failed | $($Summary.phase3_validation.skippedCount) skipped │" -ForegroundColor $bColor
Write-Host "│  Cleared: $($Summary.phase2_waste.cleaned)                                      │" -ForegroundColor $bColor
Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor $bColor

# ── PassThru ──────────────────────────────────────────────────────────────
if ($PassThru) {
    return $Result
}
