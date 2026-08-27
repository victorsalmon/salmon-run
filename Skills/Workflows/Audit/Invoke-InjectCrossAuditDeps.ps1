param(
    [string]$TaskDir = (Join-Path $PSScriptRoot "..\..\..\..\Tasks\Code"),
    [switch]$WhatIf,
    [bool]$Reconcile = $true
)

<#
.SYNOPSIS
    Scans Tasks/Code/ for architectural-*, functional-*, and compliance-* plan
    files, extracts Namespace-Iteration pairs, and injects them into
    non-source plan files' DependsOn sections — each stamped with the dep's
    ACTUAL status (complete/reviewed/locked/ready/unknown), not a hardcoded
    "complete". With -Reconcile (default on), existing dep lines whose declared
    status no longer matches reality are rewritten in place.

    compliance-* is a config-gated source: it is present only when the target
    repo has a .compliance-audit.yml. When no compliance plans exist the script
    degrades gracefully — the existing early-return sums across all source dirs
    and simply reports the zero count.
#>

function Get-DepStatus {
    <#
    .SYNOPSIS
        Returns the current dispatch gate for a namespace-iteration dep:
        complete (Tasks/Complete/), reviewed (Tasks/Review/), locked
        (Tasks/Working/), ready (Tasks/Code/), or unknown (not found).
    #>
    param([string]$Namespace, [string]$Iteration, [string]$TaskDir)
    $ref = "$Namespace-$Iteration"
    $baseDir = Split-Path $TaskDir -Parent
    $completeHits = @(Get-ChildItem -Path (Join-Path $baseDir "Complete") -Recurse -Filter "*$ref*.md" -ErrorAction SilentlyContinue)
    if ($completeHits.Count -gt 0) { return "complete" }
    $reviewHits = @(Get-ChildItem -Path (Join-Path $baseDir "Review") -Recurse -Filter "*$ref*.md" -ErrorAction SilentlyContinue)
    if ($reviewHits.Count -gt 0) { return "reviewed" }
    $workingHits = @(Get-ChildItem -Path (Join-Path $baseDir "Working") -Recurse -Filter "*$ref*.md" -ErrorAction SilentlyContinue)
    if ($workingHits.Count -gt 0) { return "locked" }
    $codeHits = @(Get-ChildItem -Path $TaskDir -Filter "*$ref*.md" -ErrorAction SilentlyContinue)
    if ($codeHits.Count -gt 0) { return "ready" }
    return "unknown"
}

$sourceDirs = @("architectural", "functional", "compliance")
$sourcePlans = @()
$targetFiles = @()

foreach ($file in Get-ChildItem -Path $TaskDir -Filter "*.md") {
    $content = Get-Content $file -Raw
    $nsMatch = [regex]::Match($content, '^\*\*Namespace\*\*:\s*(\S+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $iterMatch = [regex]::Match($content, '^\*\*Iteration\*\*:\s*(\S+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $nsMatch.Success) { continue }
    $namespace = $nsMatch.Groups[1].Value
    $iteration = if ($iterMatch.Success) { $iterMatch.Groups[1].Value } else { "0" }
    $prefix = $namespace -replace '-.*', ''
    if ($prefix -in $sourceDirs) {
        $sourcePlans += @{ namespace = $namespace; iteration = $iteration; file = $file.Name }
    } else {
        $targetFiles += @{ file = $file; namespace = $namespace }
    }
}

if ($sourcePlans.Count -eq 0) {
    Write-Host "No source plans found (architectural-*, functional-*, or compliance-* namespaces)."
    return
}

Write-Host "Found $($sourcePlans.Count) source plans across $($sourceDirs -join ', ') domains."
Write-Host "Found $($targetFiles.Count) target files to check."

$injected = 0
$reconciled = 0
foreach ($target in $targetFiles) {
    $content = Get-Content $target.file -Raw
    $dependsMatch = [regex]::Match($content, '(?m)^\*\*DependsOn\*\*:\s*(.*)$')
    $dependsSection = $dependsMatch.Success
    $existingDeps = @()
    if ($dependsSection) {
        # Comma-separated single-line format: **DependsOn**: ref-0 (status: x), ref-1 (status: y)
        foreach ($e in ($dependsMatch.Groups[1].Value -split ',')) {
            $e = $e.Trim()
            if ($e -match '^(.+?)\s+\(status:\s+\w+\)$') { $existingDeps += $Matches[1].Trim() }
        }
        # Legacy multiline list format: **DependsOn**:\n- ref (status: x)
        foreach ($d in [regex]::Matches($content, '(?m)^\s*- (\S+) \(status: \S+\)')) {
            $existingDeps += $d.Groups[1].Value
        }
    }
    $existingDeps = @($existingDeps | Select-Object -Unique)

    # Reconcile pass: rewrite existing cross-audit dep statuses whose declared
    # status no longer matches the source plan's actual location/state.
    $fileReconciled = 0
    if ($Reconcile) {
        foreach ($sp in $sourcePlans) {
            $depRef = "$($sp.namespace)-$($sp.iteration)"
            $actual = Get-DepStatus -Namespace $sp.namespace -Iteration $sp.iteration -TaskDir $TaskDir
            $pattern = [regex]::Escape($depRef) + ' \(status: \S+\)'
            if ([regex]::IsMatch($content, $pattern)) {
                $declared = if ([regex]::Match($content, $pattern).Value -match '\(status: (\S+)\)') { $Matches[1] } else { $null }
                if ($declared -ne $actual) {
                    $content = [regex]::Replace($content, $pattern, "$depRef (status: $actual)")
                    $fileReconciled++
                    $reconciled++
                    if (-not $WhatIf) {
                        Write-Host "  Reconciled $($target.file.Name): $depRef (status: $declared -> $actual)"
                    } else {
                        Write-Host "  [WHATIF] Would reconcile $($target.file.Name): $depRef (status: $declared -> $actual)"
                    }
                }
            }
        }
    }

    $newDeps = @()
    foreach ($sp in $sourcePlans) {
        $depKey = "$($sp.namespace)-$($sp.iteration)"
        if ($depKey -notin $existingDeps) {
            $newDeps += $sp
        }
    }
    if ($newDeps.Count -eq 0) {
        if ($fileReconciled -gt 0 -and -not $WhatIf) {
            $content | Set-Content $target.file -Encoding utf8 -NoNewline
        }
        continue
    }
    # Build new DependsOn entries with each dep's ACTUAL status (ready/locked/
    # reviewed/complete/unknown), never a hardcoded "complete".
    $newParts = $newDeps | ForEach-Object {
        $status = Get-DepStatus -Namespace $_.namespace -Iteration $_.iteration -TaskDir $TaskDir
        "$($_.namespace)-$($_.iteration) (status: $status)"
    }
    if ($dependsSection) {
        # Append to the existing DependsOn line (comma-separated — the format
        # Get-DependsOn parses).
        $content = $content -replace '(?m)^(\*\*DependsOn\*\*:\s*[^\r\n]*)', ("`$1" + ', ' + ($newParts -join ', '))
    } elseif ($content -match '(?m)^\*\*Description\*\*:[^\r\n]*') {
        # Insert a new DependsOn line after the Description line (handles
        # both CRLF and LF line endings).
        $content = [regex]::Replace($content, '(?m)^(\*\*Description\*\*:[^\r\n]*?)\r?\n', ("`$1`r`n**DependsOn**: " + ($newParts -join ', ') + "`r`n"))
    } else {
        # No Description line — prepend DependsOn above the session plan marker.
        $content = "**DependsOn**: " + ($newParts -join ', ') + "`n" + $content
    }
    if (-not $WhatIf) {
        $content | Set-Content $target.file -Encoding utf8 -NoNewline
        Write-Host "  Injected $($newDeps.Count) dep(s) into $($target.file.Name)"
    } else {
        Write-Host "  [WHATIF] Would inject $($newDeps.Count) dep(s) into $($target.file.Name): $($newDeps | ForEach-Object { "$($_.namespace)-$($_.iteration)" })"
    }
    $injected++
}

Write-Host "Done. $injected files updated."
