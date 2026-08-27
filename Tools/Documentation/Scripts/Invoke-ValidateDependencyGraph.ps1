<#
.SYNOPSIS
Validates dependency graph across session plan files in a directory.

.DESCRIPTION
Reads all session plan .md files from the specified directory, parses
**DependsOn**: fields, validates that all refs resolve, no cycles exist,
no self-references, and all status gates are valid (complete|reviewed).

.PARAMETER Path
Directory to scan for plan .md files. Default: Tasks/Code/

.PARAMETER Detailed
Print per-file pass/fail details (not just summary).

.PARAMETER ExitCode
Exit with code 0 (pass) or 1 (fail) for CI use.

.EXAMPLE
.\Invoke-ValidateDependencyGraph.ps1 -Detailed

.EXAMPLE
.\Invoke-ValidateDependencyGraph.ps1 -ExitCode
#>

param(
    [string]$Path = "Tasks/Code/",
    [switch]$Detailed,
    [switch]$ExitCode
)

function Get-DependsOnFromFile {
    param([string]$FilePath)

    $content = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop

    $depLines = @()
    # Match both **DependsOn**: and **Depends on**: (deprecated backward compat)
    if ($content -match '\*\*Depends(?:On| on)\*\*:\s*((?:.|\n)+?)(?=\n\*\*|\Z)') {
        $depBlock = $matches[1]
        # Split by comma or newline, trim each entry
        $depBlock -split ',|\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
            $entry = $_.Trim()
            if ($entry -match '^(\S+)\s+\(status:\s+(\w+)\)$') {
                $depLines += @{ Ref = $matches[1]; Status = $matches[2] }
            } elseif ($entry -match '^(\S+)$') {
                $depLines += @{ Ref = $matches[1]; Status = "reviewed" }
            }
        }
    }

    return $depLines
}

function Invoke-ValidateDependencyGraph {
    param(
        [string]$Path,
        [switch]$Detailed
    )

    $result = @{
        HasFailures = $false
        Passed = 0
        Failed = 0
        Errors = @()
        PlanFiles = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Errors += "Path does not exist: $Path"
        $result.HasFailures = $true
        return $result
    }

    $files = Get-ChildItem -LiteralPath $Path -Filter "*.md" -File | Where-Object { $_.Name -ne '.gitkeep' }

    if ($files.Count -eq 0) {
        if ($Detailed) { Write-Host "No plan files found in $Path" }
        return $result
    }

    $graph = @{}
    $fileNames = @{}

    foreach ($f in $files) {
        $deps = Get-DependsOnFromFile -FilePath $f.FullName
        $baseName = $f.BaseName

        $graph[$baseName] = $deps
        $fileNames[$baseName] = $f.Name
        $result.PlanFiles += $baseName
    }

    foreach ($f in $files) {
        $baseName = $f.BaseName
        $deps = $graph[$baseName]
        $fileErrors = @()

        if ($deps.Count -eq 0) {
            if ($Detailed) { Write-Host "✓ $baseName (root session, no deps)" }
            continue
        }

        $depResults = @()
        foreach ($dep in $deps) {
            $ref = $dep.Ref
            $status = $dep.Status

            # Validate status gate
            if ($status -notin @('complete', 'reviewed')) {
                $err = "$baseName`: DependsOn ref $ref has invalid status gate: $status"
                $fileErrors += $err
                $result.Errors += "FAIL: $err"
                $depResults += "✗ $ref (invalid status: $status)"
                continue
            }

            # Find matching file — ref like A-1 must appear as -A-1- or -A-1 in filename
            $found = $false
            foreach ($fileBase in $fileNames.Keys) {
                if ($fileBase -match "(^|-)${ref}(-|$)") {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                $err = "$baseName`: DependsOn ref $ref does not match any plan file"
                $fileErrors += $err
                $result.Errors += "FAIL: $err"
                $depResults += "✗ $ref (no matching plan file)"
            } else {
                # Check self-reference
                if ($baseName -match "(^|-)${ref}(-|$)") {
                    $err = "$baseName`: DependsOn self-reference to $ref"
                    $fileErrors += $err
                    $result.Errors += "FAIL: $err"
                    $depResults += "✗ $ref (self-reference)"
                } else {
                    $depResults += "✓ $ref"
                }
            }
        }

        if ($fileErrors.Count -eq 0) {
            $result.Passed++
            if ($Detailed) {
                $depStr = ($depResults -join ', ')
                Write-Host "✓ $baseName (depends on: $depStr)"
            }
        } else {
            $result.Failed++
            $result.HasFailures = $true
            if ($Detailed) {
                $depStr = ($depResults -join ', ')
                Write-Host "✗ $baseName (depends on: $depStr)"
            }
        }
    }

    # Cycle detection via DFS coloring with recursion stack tracking
    # Using a scriptblock (not a nested function) to capture outer scope variables
    $script:cycleState = @{
        WHITE = 0; GRAY = 1; BLACK = 2
        color = @{}
        stack = New-Object System.Collections.ArrayList
        cycleFound = $false
        cyclePath = @()
        graph = $graph
        fileNames = $fileNames
    }

    $script:VisitNode = {
        param([string]$Node)
        $s = $script:cycleState
        $s.color[$Node] = $s.GRAY
        $s.stack.Add($Node) | Out-Null
        foreach ($dep in $s.graph[$Node]) {
            $ref = $dep.Ref
            $targetBase = $null
            foreach ($fileBase in $s.fileNames.Keys) {
                if ($fileBase -match "(^|-)${ref}(-|$)") { $targetBase = $fileBase; break }
            }
            if (-not $targetBase -or -not $s.graph.ContainsKey($targetBase)) { continue }
            if ($s.color[$targetBase] -eq $s.GRAY) {
                $s.cycleFound = $true
                $idx = $s.stack.IndexOf($targetBase)
                if ($idx -ge 0) {
                    $s.cyclePath = $s.stack[$idx..($s.stack.Count-1)] + $targetBase
                }
                return
            } elseif ($s.color[$targetBase] -eq $s.WHITE) {
                & $script:VisitNode -Node $targetBase
                if ($s.cycleFound) { return }
            }
        }
        $s.stack.RemoveAt($s.stack.Count - 1) | Out-Null
        $s.color[$Node] = $s.BLACK
    }

    foreach ($node in $graph.Keys) { $script:cycleState.color[$node] = $script:cycleState.WHITE }
    foreach ($node in $graph.Keys) {
        if ($script:cycleState.color[$node] -eq $script:cycleState.WHITE) {
            & $script:VisitNode -Node $node
        }
    }

    if ($script:cycleState.cycleFound) {
        $result.HasFailures = $true
        $err = "Cycle detected: $($script:cycleState.cyclePath -join ' -> ')"
        $result.Errors += "FAIL: $err"
        if ($Detailed) { Write-Host "✗ Cycle: $err" -ForegroundColor Red }
    }

    return $result
}

$results = Invoke-ValidateDependencyGraph -Path $Path -Detailed:$Detailed

if ($results.HasFailures) {
    if (-not $Detailed) {
        Write-Host "$($results.Errors.Count) validation failure(s) found:" -ForegroundColor Red
        $results.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host "DependsOn validation: FAILED ($($results.Failed) failed, $($results.Passed) passed)" -ForegroundColor Red
    if ($ExitCode) { exit 1 }
} else {
    if ($results.PlanFiles.Count -eq 0) {
        if (-not $Detailed) { Write-Host "No plan files found in $Path" }
    } else {
        Write-Host "All plan files passed dependency graph validation. ($($results.Passed) passed)" -ForegroundColor Green
    }
    if ($ExitCode) { exit 0 }
}
