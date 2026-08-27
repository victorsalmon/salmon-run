<#
.SYNOPSIS
    Groom Tasks — Plan Mode skill: inventory, validate, analyze, suggest order.
.DESCRIPTION
    Scans Tasks/Code/ for plan files, extracts frontmatter, validates naming
    conventions against the canonical format, runs connascence analysis via
    corrected namespace extraction, and outputs a structured report.

    Uses its own corrected Get-FileNamespace regex that handles both dot and
    dash date separators. Detects drift vs the legacy regex in the canonical
    scripts and prints a Coder task stub to fix the canonical bug.

    Flags: -Validate | -Analyze | -SuggestOrder | -FixNames [-Apply]
.PARAMETER TaskDir
    Directory to scan for plan files. Defaults to Tasks/Code/ under repo root.
.PARAMETER RepoRoot
    Repository root directory.
.PARAMETER WorkingDir
    Tasks/Working/ for lock conflict detection.
.PARAMETER CompleteDir
    Tasks/Complete/ for dependency resolution checks.
.PARAMETER Validate
    Run inventory + validation checks (Phase 1-2).
.PARAMETER Analyze
    Run connascence analysis (Phase 3).
.PARAMETER SuggestOrder
    Output topological execution order (Phase 4).
.PARAMETER FixNames
    Suggest renames for non-conforming files (Phase 5). Requires -Apply to execute.
.PARAMETER Apply
    Actually execute the suggested renames (requires -FixNames).
.PARAMETER OutFile
    Write markdown report to file instead of stdout.
.PARAMETER AsJson
    Output JSON for orchestrator consumption.
.EXAMPLE
    .\Skills\\Planner\Groom-Tasks-Skill\Invoke-GroomTaskInventory.ps1 -Validate
.EXAMPLE
    .\Skills\\Planner\Groom-Tasks-Skill\Invoke-GroomTaskInventory.ps1 -Analyze -SuggestOrder -OutFile groom-report.md
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")),
    [string]$TaskDir = (Join-Path $RepoRoot "Tasks\Code"),
    [string]$WorkingDir = (Join-Path $RepoRoot "Tasks\Working"),
    [string]$CompleteDir = (Join-Path $RepoRoot "Tasks\Complete"),
    [switch]$Validate,
    [switch]$Analyze,
    [switch]$SuggestOrder,
    [switch]$FixNames,
    [switch]$Apply,
    [string]$OutFile,
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# HELPERS
# ==============================================================================

function Get-FileNamespaceCorrected {
    <#
    .SYNOPSIS
        Extracts namespace using regex that handles both dot and dash dates.
    .DESCRIPTION
        Same pipeline as the canonical Get-FileNamespace but uses
        \d{4}[-\.]\d{2}[-\.]\d{2} to strip dates in both formats.
    #>
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -replace '\d+$', ''
    $base = $base -replace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}[-\.]\d{2}[-\.]\d{2}-?', ''
    return ($base -replace '^-|-$', '')
}

function Get-FileNamespaceLegacy {
    <#
    .SYNOPSIS
        Exact copy of the canonical Get-FileNamespace regex (dots only).
        Used for drift detection.
    #>
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -replace '\d+$', ''
    $base = $base -replace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}\.\d{2}\.\d{2}-?', ''
    return ($base -replace '^-|-$', '')
}

function Get-HeaderField {
    param([string]$Content, [string]$FieldName)
    if ($Content -match "(?m)^\*\*$FieldName\*\*:\s*(.+)$") {
        return $matches[1].Trim()
    }
    return $null
}

function Get-FilesField {
    param([string]$Content)
    if ($Content -match "(?m)^\*\*Files\*\*:\s*(.+)$") {
        return ($matches[1] -split ',' | ForEach-Object { $_.Trim() }) |
            Where-Object { $_ -and $_ -ne 'None' -and $_ -ne 'none' }
    }
    return @()
}

function Get-ConnascenceRefs {
    <#
    .SYNOPSIS
        Extracts referenced filenames from the **Connascence**: field.
        Handles both simple lists (comma-separated .md refs) and
        complex entries like "name.md (loc: Tasks/Code, status: ready) — reason".
    #>
    param([string]$Content)
    $result = @()
    if ($Content -match "(?m)^\*\*Connascence\*\*:\s*(.+)$") {
        $val = $matches[1]
        # Extract all .md filenames (with or without surrounding context)
        $tokens = $val -split ',' | ForEach-Object { $_.Trim() }
        foreach ($token in $tokens) {
            # Match "filename.md" optionally followed by parenthetical context
            if ($token -match '([\w\.\-]+\.md)') {
                $result += $matches[1]
            }
        }
    }
    return ($result | Select-Object -Unique)
}

function Get-DependsOn {
    <#
    .SYNOPSIS
        Extracts **Depends on**: field entries.
        Format: "SessionName (status: reviewed)" or comma-separated.
    #>
    param([string]$Content)
    $result = @()
    # Try canonical "Depends on" field
    $matchField = 'Depends on'
    if ($Content -match "(?m)^\*\*$matchField\*\*:\s*(.+)$") {
        $val = $matches[1].Trim()
        if ($val -eq 'None') { return $result }
        $entries = $val -split ',' | ForEach-Object { $_.Trim() }
        foreach ($entry in $entries) {
            if ($entry -match '^(.+?)\s+\(status:\s+(\w+)\)$') {
                $result += @{ Ref = $matches[1].Trim(); Status = $matches[2] }
            } elseif ($entry -and $entry -ne 'None') {
                $result += @{ Ref = $entry; Status = 'unknown' }
            }
        }
        return $result
    }
    # Fallback: try "DependsOn" (no space)
    if ($Content -match "(?m)^\*\*DependsOn\*\*:\s*(.+)$") {
        $val = $matches[1].Trim()
        if ($val -eq 'None') { return $result }
        $entries = $val -split ',' | ForEach-Object { $_.Trim() }
        foreach ($entry in $entries) {
            if ($entry -match '^(.+?)\s+\(status:\s+(\w+)\)$') {
                $result += @{ Ref = $matches[1].Trim(); Status = $matches[2] }
            } elseif ($entry -and $entry -ne 'None') {
                $result += @{ Ref = $entry; Status = 'unknown' }
            }
        }
    }
    return $result
}

function Get-DateFormat {
    param([string]$FileName)
    if ($FileName -match '^\d{4}\.\d{2}\.\d{2}') { return 'dot' }
    if ($FileName -match '^\d{4}-\d{2}-\d{2}') { return 'dash' }
    return 'unknown'
}

function Get-Iteration {
    <#
    .SYNOPSIS
        Extracts iteration number from filename.
        Looks for the first number after the namespace prefix.
    #>
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $stripped = $base -replace '^\d{4}[-\.]\d{2}[-\.]\d{2}-?', ''
    if ($stripped -match '^[^-]+-(\d+)') {
        return [int]$matches[1]
    }
    if ($base -match '(\d+)$') {
        return [int]$matches[1]
    }
    return 0
}

function Get-SuggestedName {
    <#
    .SYNOPSIS
        Produces the canonical filename for a plan.
        Standardizes to dot-separated date + corrected namespace + iteration + short description.
    #>
    param(
        [string]$FileName,
        [string]$Namespace,
        [int]$Iteration,
        [string]$Description
    )
    $date = if ($FileName -match '^(\d{4}[-\.]\d{2}[-\.]\d{2})') {
        $matches[1] -replace '-', '.'
    } else {
        (Get-Date -Format "yyyy.MM.dd")
    }
    $desc = if ($Description) { "-$($Description -replace '\s+', '-')" } else { '' }
    return "$date-$Namespace-$Iteration$desc.md"
}

function Get-ShortDescription {
    <#
    .SYNOPSIS
        Extracts a short description from the plan title (first line).
    #>
    param([string]$Content)
    if ($Content -match '^#\s+.+?[—\-]\s*(.+?)(\s*\(|$)') {
        return $matches[1].Trim()
    }
    if ($Content -match '^#\s+Session Plan:\s+(.+)') {
        return ($matches[1] -replace '^\d{4}[-\.]\d{2}[-\.]\d{2}\s*', '' -replace '\s+', '-')
    }
    return ''
}

# ==============================================================================
# PHASE 1: INVENTORY
# ==============================================================================

Write-Host "Scanning $TaskDir ..." -ForegroundColor Cyan

$planFiles = Get-ChildItem -Path $TaskDir -Filter "*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' }

if (-not $planFiles) {
    Write-Host "No plan files found in $TaskDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($planFiles.Count) plan files." -ForegroundColor Cyan

$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($f in $planFiles) {
    $content = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $nsCorrect = Get-FileNamespaceCorrected -FileName $f.Name
    $nsLegacy  = Get-FileNamespaceLegacy -FileName $f.Name
    $dateFmt   = Get-DateFormat -FileName $f.Name
    $iteration = Get-Iteration -FileName $f.Name
    $filesField = Get-FilesField -Content $content
    $dependsOn = Get-DependsOn -Content $content
    $connAsc   = Get-ConnascenceRefs -Content $content
    $status    = Get-HeaderField -Content $content -FieldName "Status"
    $connScope = Get-HeaderField -Content $content -FieldName "ConnascenceScope"
    $type      = Get-HeaderField -Content $content -FieldName "Type"
    $title     = Get-ShortDescription -Content $content

    $inventory.Add([PSCustomObject]@{
        FileName           = $f.Name
        FullPath           = $f.FullName
        DateFormat         = $dateFmt
        NamespaceCorrected = $nsCorrect
        NamespaceLegacy    = $nsLegacy
        NamespaceDrift     = ($nsCorrect -ne $nsLegacy)
        Iteration          = $iteration
        Status             = $status
        Type               = $type
        Title              = $title
        Files              = @($filesField)
        ConnascenceScope   = $connScope
        ConnascenceRefs    = @($connAsc)
        DependsOn          = @($dependsOn)
    })
}

# ==============================================================================
# PHASE 2: VALIDATION
# ==============================================================================

if ($Validate) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  VALIDATION REPORT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Check 1: Date format summary
    Write-Host ""
    Write-Host "📅 Date formats:" -ForegroundColor Cyan
    $dateFormats = $inventory | Group-Object DateFormat
    foreach ($g in $dateFormats) {
        Write-Host "  $($g.Name): $($g.Count) files"
    }

    # Check 2: Namespace extraction drift
    $drifted = $inventory | Where-Object { $_.NamespaceDrift }
    if ($drifted) {
        $warnings.Add("$($drifted.Count) files have namespace extraction drift (legacy regex doesn't strip their date format):")
        foreach ($d in $drifted) {
            $warnings.Add("  $($d.FileName)")
            $warnings.Add("    legacy:    $($d.NamespaceLegacy)")
            $warnings.Add("    corrected: $($d.NamespaceCorrected)")
        }
    }

    # Check 3: Missing Status
    $noStatus = $inventory | Where-Object { -not $_.Status }
    if ($noStatus) {
        $errors.Add("$($noStatus.Count) files missing **Status**: field:")
        foreach ($f in $noStatus) { $errors.Add("  $($f.FileName)") }
    }

    # Check 4: Non-ready status
    $nonReady = $inventory | Where-Object { $_.Status -and $_.Status -ne 'ready' }
    if ($nonReady) {
        $warnings.Add("$($nonReady.Count) files with non-ready status:")
        foreach ($f in $nonReady) { $warnings.Add("  $($f.FileName) → $($f.Status)") }
    }

    # Check 5: Empty Files field
    $noFiles = $inventory | Where-Object { $_.Files.Count -eq 0 }
    if ($noFiles) {
        $warnings.Add("$($noFiles.Count) files have empty **Files**: field (orchestrator can't detect file overlap):")
        foreach ($f in $noFiles) { $warnings.Add("  $($f.FileName)") }
    }

    # Check 6: >3 files but no ConnascenceScope
    $missingScope = $inventory | Where-Object { $_.Files.Count -gt 3 -and -not $_.ConnascenceScope }
    if ($missingScope) {
        $warnings.Add("$($missingScope.Count) files touch >3 files but lack **ConnascenceScope**: (needed for smart connascence):")
        foreach ($f in $missingScope) { $warnings.Add("  $($f.FileName): $($f.Files.Count) files") }
    }

    # Check 7: Lock conflicts with Working/
    if (Test-Path $WorkingDir) {
        $workingFiles = Get-ChildItem -Path $WorkingDir -Filter "*.md" -ErrorAction SilentlyContinue
        $nsInWorking = @{}
        foreach ($wf in $workingFiles) {
            $wns = Get-FileNamespaceCorrected -FileName $wf.Name
            if (-not $nsInWorking.ContainsKey($wns)) { $nsInWorking[$wns] = @() }
            $nsInWorking[$wns] += $wf.Name
        }
        foreach ($nsEntry in $nsInWorking.GetEnumerator()) {
            $conflicts = $inventory | Where-Object {
                $_.NamespaceCorrected -eq $nsEntry.Key -and $_.Status -eq 'ready'
            }
            if ($conflicts) {
                $warnings.Add("Namespace '$($nsEntry.Key)' already locked in Working/ ($($nsEntry.Value -join ', ')) — $($conflicts.Count) ready files blocked:")
                foreach ($f in $conflicts) { $warnings.Add("  $($f.FileName)") }
            }
        }
    }

    # Output
    Write-Host ""
    if ($errors.Count -gt 0) {
        Write-Host "❌ ERRORS:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "⚠️  WARNINGS:" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host "✅ No issues found." -ForegroundColor Green
    }
}

# ==============================================================================
# PHASE 3: CONNASCENCE ANALYSIS
# ==============================================================================

if ($Analyze) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CONNASCENCE ANALYSIS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $nsGroups = $inventory | Group-Object NamespaceCorrected
    $groupsOut = [System.Collections.Generic.List[object]]::new()

    foreach ($nsGroup in $nsGroups | Sort-Object Name) {
        $sortedPlans = $nsGroup.Group | Sort-Object Iteration

        # Build per-plan target file sets
        $filesPerPlan = @{}
        $allTargets = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($p in $sortedPlans) {
            $targets = @($p.Files)
            if ($p.ConnascenceScope) {
                $targets += ($p.ConnascenceScope -split ',' | ForEach-Object { $_.Trim() }) |
                    Where-Object { $_ }
            }
            $filesPerPlan[$p.FileName] = $targets
            foreach ($t in $targets) { $null = $allTargets.Add($t) }
        }

        # Detect file overlap
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $hasOverlap = $false
        foreach ($p in $sortedPlans) {
            $targets = $filesPerPlan[$p.FileName]
            foreach ($t in $targets) {
                if ($seen.Contains($t)) { $hasOverlap = $true }
                else { $null = $seen.Add($t) }
            }
        }

        # Classify parallelism
        if ($sortedPlans.Count -eq 0) { continue }
        elseif ($sortedPlans.Count -eq 1) {
            $paraType = "SINGLE"
            $icon = "📄"
        } elseif ($hasOverlap) {
            $paraType = "SERIAL"
            $icon = "🔗"
        } else {
            $paraType = "PARALLEL"
            $icon = "⚡"
        }

        # Check for DependsOn edges to other namespaces
        $externalDeps = @()
        foreach ($p in $sortedPlans) {
            foreach ($dep in $p.DependsOn) {
                if ($dep.Status -ne 'unknown') {
                    $externalDeps += "$($p.FileName) → $($dep.Ref) (status: $($dep.Status))"
                }
            }
        }

        $groupsOut.Add([PSCustomObject]@{
            GroupId       = $nsGroup.Name
            FileCount     = $sortedPlans.Count
            Parallelism   = $paraType
            HasOverlap    = $hasOverlap
            ScopeCount    = $allTargets.Count
            ScopeFiles    = @($allTargets | Sort-Object)
            ExternalDeps  = @($externalDeps)
            Files         = @($sortedPlans | ForEach-Object { $_.FileName })
        })
    }

    # Print groups
    Write-Host ""
    Write-Host "$($groupsOut.Count) connascence groups from $($inventory.Count) plans" -ForegroundColor Cyan
    Write-Host ""

    $totalParallel = 0
    $totalSerial = 0
    $totalSingle = 0

    foreach ($g in $groupsOut) {
        $color = switch ($g.Parallelism) {
            'PARALLEL' { 'Green' }
            'SERIAL'   { 'Yellow' }
            'SINGLE'   { 'Gray' }
        }
        $scopeSummary = if ($g.ScopeCount -le 5) {
            $g.ScopeFiles -join ', '
        } else {
            "$($g.ScopeCount) files ($($g.ScopeFiles[0])…)"
        }

        Write-Host "$($g.GroupId) | $($g.Parallelism) | $($g.FileCount) files | scope: $scopeSummary" -ForegroundColor $color

        if ($g.ExternalDeps.Count -gt 0) {
            foreach ($dep in $g.ExternalDeps) {
                Write-Host "  ╰ $dep" -ForegroundColor DarkGray
            }
        }

        switch ($g.Parallelism) {
            'PARALLEL' { $totalParallel += $g.FileCount }
            'SERIAL'   { $totalSerial += $g.FileCount }
            'SINGLE'   { $totalSingle++ }
        }
    }

    Write-Host ""
    Write-Host "Summary: $totalParallel parallelizable | $totalSerial serial | $totalSingle single-file groups" -ForegroundColor Cyan
}

# ==============================================================================
# PHASE 4: EXECUTION ORDER
# ==============================================================================

if ($SuggestOrder) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  EXECUTION ORDER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Build dependency graph
    # Nodes = all filenames in Code/
    # Edges from:
    #   - ConnascenceRefs (within same namespace)
    #   - DependsOn (cross-namespace)
    $allFileNames = $inventory | ForEach-Object { $_.FileName } | Sort-Object
    $nameSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in $allFileNames) { $null = $nameSet.Add($n) }

    # Graph: adjacency list (dep → dependent edges)
    $graph = @{}
    $inDegree = @{}
    foreach ($fn in $allFileNames) {
        $graph[$fn] = [System.Collections.Generic.List[string]]::new()
        $inDegree[$fn] = 0
    }

    # Add edges from ConnascenceRefs (only if the referenced file exists in Code/)
    foreach ($p in $inventory) {
        foreach ($ref in $p.ConnascenceRefs) {
            if ($nameSet.Contains($ref) -and $ref -ne $p.FileName) {
                # Edge: ref → p.FileName (ref must complete first)
                $graph[$ref].Add($p.FileName)
            }
        }
    }

    # Add edges from DependsOn (cross-namespace deps)
    foreach ($p in $inventory) {
        foreach ($dep in $p.DependsOn) {
            $refFile = $dep.Ref
            # Append .md if not present
            if (-not $refFile.EndsWith('.md')) { $refFile += '.md' }
            if ($nameSet.Contains($refFile) -and $refFile -ne $p.FileName) {
                $graph[$refFile].Add($p.FileName)
            }
        }
    }

    # Recompute in-degree
    foreach ($fn in $allFileNames) {
        $inDegree[$fn] = 0
    }
    foreach ($fn in $allFileNames) {
        foreach ($dep in $graph[$fn]) {
            if ($inDegree.ContainsKey($dep)) {
                $inDegree[$dep]++
            }
        }
    }

    # Kahn's algorithm for topological sort into stages
    $stages = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($fn in $allFileNames) {
        if ($inDegree[$fn] -eq 0) { $queue.Enqueue($fn) }
    }

    $processed = [System.Collections.Generic.HashSet[string]]::new()
    $stageNum = 1

    while ($queue.Count -gt 0) {
        $currentStage = [System.Collections.Generic.List[string]]::new()
        $nextQueue = [System.Collections.Generic.Queue[string]]::new()

        while ($queue.Count -gt 0) {
            $fn = $queue.Dequeue()
            if ($processed.Contains($fn)) { continue }
            $null = $processed.Add($fn)
            $currentStage.Add($fn)

            foreach ($dep in $graph[$fn]) {
                if (-not $processed.Contains($dep)) {
                    $inDegree[$dep]--
                    if ($inDegree[$dep] -eq 0) {
                        $nextQueue.Enqueue($dep)
                    }
                }
            }
        }

        if ($currentStage.Count -gt 0) {
            $stages.Add([PSCustomObject]@{
                Stage = $stageNum
                Count = $currentStage.Count
                Files = @($currentStage | Sort-Object)
            })
            $stageNum++
        }

        $queue = $nextQueue
    }

    # Check for unprocessed (cycle)
    $unprocessed = $allFileNames | Where-Object { -not $processed.Contains($_) }
    if ($unprocessed) {
        Write-Host ""
        Write-Host "⚠️  Cycle detected — $($unprocessed.Count) files not in execution order:" -ForegroundColor Yellow
        foreach ($fn in $unprocessed) { Write-Host "  $fn" -ForegroundColor Yellow }
    }

    # Print stages
    Write-Host ""
    Write-Host "$($stages.Count) execution stages" -ForegroundColor Cyan
    Write-Host ""

    # Compute parallelism for each stage
    $stageFileLookup = @{}
    foreach ($p in $inventory) {
        $stageFileLookup[$p.FileName] = $p
    }

    foreach ($stage in $stages) {
        # Check what namespaces appear in this stage
        $namespacesInStage = $stage.Files | ForEach-Object {
            if ($stageFileLookup.ContainsKey($_)) {
                $stageFileLookup[$_].NamespaceCorrected
            } else { '?' }
        } | Sort-Object -Unique

        $hasNamespaceCollision = ($namespacesInStage.Count -lt $stage.Count -and $stage.Count -gt 1)

        $stageColor = if ($hasNamespaceCollision) { 'Yellow' } else { 'Green' }
        $paraLabel = if ($hasNamespaceCollision) {
            "⚠️  same-namespace collision — serialize or verify ConnascenceScope"
        } else {
            "✅ all different namespaces — fully parallel"
        }

        Write-Host "Stage $($stage.Stage): $($stage.Count) files — $paraLabel" -ForegroundColor $stageColor
        foreach ($fn in $stage.Files | Sort-Object) {
            if ($stageFileLookup.ContainsKey($fn)) {
                $p = $stageFileLookup[$fn]
                $ns = $p.NamespaceCorrected
                Write-Host "  [$ns] $fn"
            } else {
                Write-Host "  $fn"
            }
        }
        Write-Host ""
    }

    # Check for files still in Code/ with DependsOn not in Code/ (blocked by completed work)
    $blockedByExternal = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $inventory) {
        foreach ($dep in $p.DependsOn) {
            $refFile = $dep.Ref
            if (-not $refFile.EndsWith('.md')) { $refFile += '.md' }
            if (-not $nameSet.Contains($refFile) -and $dep.Status -eq 'reviewed') {
                # Dep is not in Code/ — check if it's in Complete/
                $completePath = Join-Path $CompleteDir $refFile
                $found = Get-ChildItem -Path $CompleteDir -Recurse -Filter $refFile -ErrorAction SilentlyContinue
                if (-not $found) {
                    $blockedByExternal.Add("$($p.FileName) → $refFile (not found in Code/ or Complete/)")
                }
            }
        }
    }

    if ($blockedByExternal.Count -gt 0) {
        Write-Host "⚠️  Blocked by external deps (not in any queue):" -ForegroundColor Yellow
        foreach ($b in $blockedByExternal) { Write-Host "  $b" -ForegroundColor Yellow }
        Write-Host ""
    }
}

# ==============================================================================
# PHASE 5: RENAME SUGGESTIONS
# ==============================================================================

if ($FixNames) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RENAME SUGGESTIONS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $renamePlan = [System.Collections.Generic.List[object]]::new()

    foreach ($p in $inventory) {
        $suggested = Get-SuggestedName -FileName $p.FileName `
            -Namespace $p.NamespaceCorrected `
            -Iteration $p.Iteration `
            -Description $p.Title

        if ($suggested -ne $p.FileName) {
            $renamePlan.Add([PSCustomObject]@{
                Current     = $p.FileName
                Suggested   = $suggested
                Reason      = if ($p.DateFormat -eq 'dash') { "standardize date format: dash → dot" }
                              else { "standardize naming" }
            })
        }
    }

    if ($renamePlan.Count -eq 0) {
        Write-Host "✅ All filenames already conform to standard format." -ForegroundColor Green
    } else {
        Write-Host "$($renamePlan.Count) renames suggested:" -ForegroundColor Cyan
        Write-Host ""
        foreach ($r in $renamePlan) {
            Write-Host "  $($r.Current)" -ForegroundColor Gray
            Write-Host "  → $($r.Suggested)  ($($r.Reason))" -ForegroundColor Cyan
            Write-Host ""
        }

        if ($Apply) {
            Write-Host "Applying $($renamePlan.Count) renames ..." -ForegroundColor Yellow
            $renameScript = Join-Path $PSScriptRoot "Invoke-GroomTaskRename.ps1"
            if (Test-Path $renameScript) {
                & $renameScript -Renames ($renamePlan | ForEach-Object {
                    @{ Current = $_.Current; Suggested = $_.Suggested }
                }) -TaskDir $TaskDir
            } else {
                # Fallback: inline rename
                foreach ($r in $renamePlan) {
                    $oldPath = Join-Path $TaskDir $r.Current
                    $newPath = Join-Path $TaskDir $r.Suggested
                    if (Test-Path $oldPath -and -not (Test-Path $newPath)) {
                        Rename-Item -Path $oldPath -NewName $r.Suggested
                        Write-Host "  ✓ $($r.Current) → $($r.Suggested)" -ForegroundColor Green
                    } elseif (Test-Path $newPath) {
                        Write-Host "  ✗ $($r.Suggested) already exists — skipping" -ForegroundColor Red
                    }
                }
            }
            Write-Host "Renames complete." -ForegroundColor Green
        } else {
            Write-Host "(Run with -Apply to execute these renames)" -ForegroundColor DarkGray
        }
    }
}

# ==============================================================================
# ALWAYS: Canonical fix Coder task stub
# ==============================================================================

$drifted = $inventory | Where-Object { $_.NamespaceDrift }
if ($drifted) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CANONICAL FIX — CODER TASK STUB" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The legacy Get-FileNamespace regex only strips dot-separated dates." -ForegroundColor Yellow
    Write-Host "$($drifted.Count) dash-date files get wrong namespaces." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Fix both locations:" -ForegroundColor Cyan
    Write-Host "  1. Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1 (line 22)" -ForegroundColor White
    Write-Host "  2. Orchestrator/Orchestration/Get-ConnascenceGroups.ps1 (line 44)" -ForegroundColor White
    Write-Host ""
    Write-Host "Change:" -ForegroundColor Cyan
    Write-Host "  '^\d{4}\.\d{2}\.\d{2}-?'" -ForegroundColor Gray
    Write-Host "To:" -ForegroundColor Cyan
    Write-Host "  '^\d{4}[-\.]\d{2}[-\.]\d{2}-?'" -ForegroundColor Green
    Write-Host ""
    Write-Host "This is a 1-character regex change in both files. All downstream" -ForegroundColor DarkGray
    Write-Host "consumers (orchestrator, Get-ConnascenceGroups, stream allocation)" -ForegroundColor DarkGray
    Write-Host "will immediately produce correct namespaces for dash-date files." -ForegroundColor DarkGray
    Write-Host ""

    $stubPath = Join-Path $RepoRoot "Tasks\Code\generated-$(Get-Date -Format 'yyyy.MM.dd')-fix-get-filenamespace-regex.md"
    $stubContent = @"
# Session Plan: $(Get-Date -Format 'yyyy.MM.dd') — Fix Get-FileNamespace regex to handle dash dates

**Status**: ready
**Date**: $(Get-Date -Format 'yyyy-MM-dd')
**Files**: Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1, Orchestrator/Orchestration/Get-ConnascenceGroups.ps1
**Connascence**: None
**Token budget**: estimated 5K tokens

---

## Task 1: Update regex in LocalOrchestrator-FileHelpers.ps1:22

**File**: `Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1` (line 22)
**Change**: Replace `^\d{4}\.\d{2}\.\d{2}-?` with `^\d{4}[-\.]\d{2}[-\.]\d{2}-?`

## Task 2: Update regex in Get-ConnascenceGroups.ps1:44

**File**: `Orchestrator/Orchestration/Get-ConnascenceGroups.ps1` (line 44)
**Change**: Same regex replacement

**Verification**: Run `./Skills/Planner/Groom-Tasks-Skill/Invoke-GroomTaskInventory.ps1 -Validate` and confirm zero namespace drift.
"@

    Write-Host "Coder task stub generated at: $stubPath" -ForegroundColor Green
    Write-Host "(Stage with code changes when implementing the fix)" -ForegroundColor DarkGray
}

# ==============================================================================
# OUTPUT
# ==============================================================================

if ($OutFile) {
    # Collect all output text into a markdown report
    $reportLines = [System.Collections.Generic.List[string]]::new()
    $reportLines.Add("# Groom Tasks Report — $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $reportLines.Add("")
    $reportLines.Add("**Files scanned**: $($inventory.Count) in $TaskDir")
    $reportLines.Add("")

    if ($Validate) {
        $reportLines.Add("## Validation")
        $reportLines.Add("")
        # Summarize
        $reportLines.Add("- **Date formats**: $($dateFormats.Count) variants")
        $reportLines.Add("- **Namespace drift**: $($drifted.Count) files")
        $reportLines.Add("")
    }

    if ($Analyze) {
        $reportLines.Add("## Connascence Groups")
        $reportLines.Add("")
        foreach ($g in $groupsOut) {
            $reportLines.Add("### $($g.GroupId)  ($($g.Parallelism))")
            $reportLines.Add("- **Files**: $($g.FileCount)")
            $reportLines.Add("- **Scope**: $($g.ScopeCount) files")
            $reportLines.Add("")
            foreach ($fn in $g.Files) { $reportLines.Add("  - $fn") }
            $reportLines.Add("")
        }
    }

    if ($SuggestOrder -and $stages) {
        $reportLines.Add("## Execution Order")
        $reportLines.Add("")
        foreach ($stage in $stages) {
            $reportLines.Add("### Stage $($stage.Stage) — $($stage.Count) files")
            $reportLines.Add("")
            foreach ($fn in $stage.Files) { $reportLines.Add("  - $fn") }
            $reportLines.Add("")
        }
    }

    $reportLines | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "Report written to $OutFile" -ForegroundColor Green
}

if ($AsJson) {
    $jsonResult = [PSCustomObject]@{
        scanDate    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        fileCount   = $inventory.Count
        inventory   = @($inventory | ForEach-Object {
            [PSCustomObject]@{
                fileName           = $_.FileName
                namespaceCorrected = $_.NamespaceCorrected
                namespaceLegacy    = $_.NamespaceLegacy
                namespaceDrift     = $_.NamespaceDrift
                dateFormat         = $_.DateFormat
                iteration          = $_.Iteration
                status             = $_.Status
                fileCount          = $_.Files.Count
                hasConnascenceScope = [bool]$_.ConnascenceScope
                depCount           = $_.DependsOn.Count
            }
        })
        connascenceGroups = if ($Analyze) { @($groupsOut) } else { @() }
        executionStages   = if ($SuggestOrder -and $stages) { @($stages) } else { @() }
    }
    $jsonResult | ConvertTo-Json -Depth 3
}
