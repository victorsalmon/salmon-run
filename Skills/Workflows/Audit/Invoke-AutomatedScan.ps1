param(
    [switch]$DryRun,
    [string]$OutputFile = "",
    [string]$PriorAuditHead = "",
    [string]$RepoRoot = ""
)

# Used by: Skills/Workflows/Audit/alignment-audit.md (Phase 0 -- Pre-Flight Automated Sweep)
# Known fixed bugs (2026-06-20):
#   - Path separator: git diff outputs `/`, Windows paths use `\`. In-Scope normalizes to `/`.
#   - PowerShell escape: `\$script:` is invalid (backslash is not the escape char). Use `` `$script: `` (backtick).
#   - Parser validation: [ref] parameters produce false positives in ParseInput. Filtered out in Scan 8.
#   - Em-dash/encoding (2026-06-27): non-ASCII characters (em-dash U+2014) in double-quoted strings
#     cause parser errors on PS 7.6.2 without UTF-8 BOM. File must be saved with UTF-8 BOM.
#     Avoid typographic characters in string literals -- use regular hyphens and ASCII quotes.

$ErrorActionPreference = "Stop"

# Resolve repo root
if ($RepoRoot) {
    $repoRoot = $RepoRoot
} elseif ($env:AUDIT_TARGET_REPO) {
    $repoRoot = $env:AUDIT_TARGET_REPO
} else {
    $repoRoot = $PSScriptRoot
    while ($repoRoot) {
        if (Test-Path (Join-Path $repoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $repoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $repoRoot -Parent
        if ($parent -eq $repoRoot) { $repoRoot = $null; break }
        $repoRoot = $parent
    }
    if (-not $repoRoot) { $repoRoot = Join-Path $HOME "intersite-orchestrator" }
}

# Default output path
if (-not $OutputFile) {
    $today = Get-Date -Format "yyyy-MM-dd"
    $OutputFile = Join-Path $repoRoot "Tasks\Logs\automated-scan-$today.json"
}

# Mutex for safe concurrent access
$MutexName = "Global\Interclaw-AutomatedScan"
$mutex = $null
$acquired = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquired = $mutex.WaitOne(30000)
    if (-not $acquired) { throw "Could not acquire mutex for automated scan" }

    # Collect scope: either full tree or git-diff restricted
    $scopedPaths = @{}
    $totalFileCount = 0

    if ($PriorAuditHead) {
        $diffFiles = & git diff --name-only "$PriorAuditHead..HEAD" 2>$null
        foreach ($f in $diffFiles) {
            $scopedPaths[$f] = $true
        }
        Write-Host "Differential mode: $($scopedPaths.Count) files changed since $PriorAuditHead"
    }

    function In-Scope($path) {
        if (-not $PriorAuditHead) { return $true }
        $normalized = $path -replace '\\', '/'
        return $scopedPaths.ContainsKey($normalized)
    }

    $findings = @()

    # ============================================================
    # SCAN 1: Deprecated patterns (from Domain 3)
    # ============================================================
    Write-Host "SCAN 1: Deprecated patterns..."
    $deprecatedPaths = @(
        "Skills/Docker",
        "Infrastructure"
    )
    foreach ($base in $deprecatedPaths) {
        $fullBase = Join-Path $repoRoot $base
        if (-not (Test-Path $fullBase)) { continue }
        Get-ChildItem -Path $fullBase -Recurse -Filter "*.ps1" | ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            if (-not (In-Scope $rel)) { return }
            $totalFileCount++
            $content = Get-Content -LiteralPath $_.FullName -Raw
            $issues = @()
            if ($content -match '\bWrite-Host\b') { $issues += "Write-Host (use Write-Information or Write-Output in non-interactive scripts)" }
            if ($content -match 'Select-Object\s+-Property\s+\*') { $issues += "Select-Object -Property * (should be explicit property names)" }
            if ($content -match 'Add-Content\s(?!.*-Encoding)') { $issues += "Add-Content without -Encoding (default varies by platform)" }
            if ($issues.Count -gt 0) {
                $findings += [PSCustomObject]@{
                    scan = "deprecated-patterns"
                    file = $rel
                    severity = "low"
                    title = "Deprecated patterns in $rel"
                    detail = ($issues -join '; ')
                }
            }
        }
    }

    # ============================================================
    # SCAN 2: Concurrency hazards (from Domain 2)
    # ============================================================
    Write-Host "SCAN 2: Concurrency hazards..."
    $moduleDir = Join-Path $repoRoot "Skills\Docker\Modules"
    if (Test-Path $moduleDir) {
        # ForEach-Object -Parallel usage
        Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            if (-not (In-Scope $rel)) { return }
            $lines = Get-Content -LiteralPath $_.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match 'ForEach-Object\s*-Parallel') {
                    $findings += [PSCustomObject]@{
                        scan = "concurrency"
                        file = $rel
                        line = $lineNum
                        severity = "medium"
                        title = "ForEach-Object -Parallel at $rel line $lineNum"
                        detail = "Runspace-parallel block detected. Verify module-scoped `$script: variables are not written inside - each runspace gets its own copy."
                    }
                }
                if ($line -match 'Start-ThreadJob|Start-Job') {
                    $findings += [PSCustomObject]@{
                        scan = "concurrency"
                        file = $rel
                        line = $lineNum
                        severity = "medium"
                        title = "Background job at $rel line $lineNum"
                        detail = "Job-based parallelism detected. Verify data crosses the process boundary correctly."
                    }
                }
                if ($line -match '\[void\]|Out-Null') {
                    $findings += [PSCustomObject]@{
                        scan = "concurrency"
                        file = $rel
                        line = $lineNum
                        severity = "low"
                        title = "Silent discard at $rel line $lineNum"
                        detail = "Output discarded with [void] or Out-Null. Verify no errors are being swallowed."
                    }
                }
            }
        }

        # $script: variable access
        Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            if (-not (In-Scope $rel)) { return }
            $lines = Get-Content -LiteralPath $_.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '\$script:') {
                    $findings += [PSCustomObject]@{
                        scan = "concurrency"
                        file = $rel
                        line = $lineNum
                        severity = "info"
                        title = "Module-scoped variable at $rel line $lineNum"
                        detail = "Module-scoped (`$script:) variable access. Verify this is not written from inside a ForEach-Object -Parallel block -- each runspace gets its own copy."
                    }
                }
            }
        }

        # Named vs unnamed sync primitives
        Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            if (-not (In-Scope $rel)) { return }
            $lines = Get-Content -LiteralPath $_.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match 'New-Object System\.Threading\.(Mutex|Semaphore)\s*\(') {
                    $findings += [PSCustomObject]@{
                        scan = "concurrency"
                        file = $rel
                        line = $lineNum
                        severity = "info"
                        title = "Sync primitive at $rel line $lineNum"
                        detail = "Mutex/Semaphore usage. Verify: named (for cross-process), WaitOne inside try, Release in finally, timeout is documented."
                    }
                }
            }
        }
    }

    # ============================================================
    # SCAN 3: Retry / timeout / backoff (from Domain 2)
    # ============================================================
    Write-Host "SCAN 3: Retry/timeout/backoff patterns..."
    $scan3Paths = @(
        "Skills/Docker",
        "Infrastructure"
    )
    foreach ($base in $scan3Paths) {
        $fullBase = Join-Path $repoRoot $base
        if (-not (Test-Path $fullBase)) { continue }
        Get-ChildItem -Path $fullBase -Recurse -Filter "*.ps1" | ForEach-Object {
            $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
            if (-not (In-Scope $rel)) { return }
            $lines = Get-Content -LiteralPath $_.FullName
            $lineNum = 0
            $hasRetry = $false
            $hasSleep = $false
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match 'Start-Sleep') { $hasSleep = $true }
                if ($line -match '\bRetry\b|BackoffSeconds|BackoffSchedule|Invoke-WithRetry') { $hasRetry = $true }
            }
            if ($hasRetry) {
                $findings += [PSCustomObject]@{
                    scan = "retry-patterns"
                    file = $rel
                    severity = "info"
                    title = "Retry logic in $rel"
                    detail = "File contains retry/backoff logic. Verify: exponential backoff, jitter, error variable capture, no infinite retry."
                }
            }
            if ($hasSleep) {
                $findings += [PSCustomObject]@{
                    scan = "retry-patterns"
                    file = $rel
                    severity = "info"
                    title = "Sleep-based timing in $rel"
                    detail = "File contains Start-Sleep. Verify: sleeps are bounded, documented, and not used as a substitute for proper synchronization."
                }
            }
        }
    }

    # ============================================================
    # SCAN 4: Silent error swallowing (from Domain 2)
    # ============================================================
    Write-Host "SCAN 4: Silent error swallowing..."
    Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if (-not (In-Scope $rel)) { return }
        $lines = Get-Content -LiteralPath $_.FullName
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line -match '\|\s*Out-Null') {
                $findings += [PSCustomObject]@{
                    scan = "error-swallowing"
                    file = $rel
                    line = $lineNum
                    severity = "low"
                    title = "Piped Out-Null at $rel line $lineNum"
                    detail = "Pipeline output discarded with | Out-Null. Verify no errors are being silently dropped."
                }
            }
            if ($line -match '2>\$null') {
                $findings += [PSCustomObject]@{
                    scan = "error-swallowing"
                    file = $rel
                    line = $lineNum
                    severity = "low"
                    title = "Error stream redirect at $rel line $lineNum"
                    detail = "Error stream redirected to `$null. Verify errors are intentionally suppressed and handled elsewhere."
                }
            }
            if ($line -match '-ErrorAction\s+SilentlyContinue') {
                $findings += [PSCustomObject]@{
                    scan = "error-swallowing"
                    file = $rel
                    line = $lineNum
                    severity = "medium"
                    title = "SilentlyContinue at $rel line $lineNum"
                    detail = "ErrorAction SilentlyContinue suppresses all errors. Verify there's an explicit error check after this call."
                }
            }
            if ($line -match 'catch\s*\{(\s*)\}') {
                $findings += [PSCustomObject]@{
                    scan = "error-swallowing"
                    file = $rel
                    line = $lineNum
                    severity = "high"
                    title = "Empty catch block at $rel line $lineNum"
                    detail = "Empty catch block silently swallows all exceptions. Add error logging or re-throw."
                }
            }
        }
    }

    # ============================================================
    # SCAN 5: Atomic file writes (from Domain 9 Invariant 2)
    # ============================================================
    Write-Host "SCAN 5: Atomic file writes..."
    Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if (-not (In-Scope $rel)) { return }
        $content = Get-Content -LiteralPath $_.FullName -Raw
        # Look for Set-Content / Out-File that is NOT preceded by .tmp pattern in the same line
        if ($content -match '(?<!\.tmp.*)(Set-Content|Out-File|Add-Content)(?!.*\.tmp)') {
            # Heuristic: direct write to target path without temp file
            $lines = Get-Content -LiteralPath $_.FullName
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '\| (Set-Content|Out-File|Add-Content)\b') {
                    $findings += [PSCustomObject]@{
                        scan = "atomic-writes"
                        file = $rel
                        line = $lineNum
                        severity = "medium"
                        title = "Direct file write at $rel line $lineNum"
                        detail = "Write to target path without temp-file+rename pattern. A crash mid-write could truncate the file."
                    }
                }
            }
        }
    }

    # ============================================================
    # SCAN 6: Pinned Docker tags (from Domain 9 Invariant 5)
    # ============================================================
    Write-Host "SCAN 6: Pinned Docker tags..."
    $dockerFiles = @()
    Get-ChildItem -Path (Join-Path $repoRoot "Infrastructure") -Recurse -Include "*.Dockerfile", "Dockerfile*" -ErrorAction SilentlyContinue | ForEach-Object { $dockerFiles += $_ }
    foreach ($df in $dockerFiles) {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $df.FullName)
        if (-not (In-Scope $rel)) { continue }
        $lines = Get-Content -LiteralPath $df.FullName
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line -match '^FROM\s+(\S+):(latest|stable|lts|[0-9]+\b)(\s|$)') {
                $findings += [PSCustomObject]@{
                    scan = "docker-tags"
                    file = $rel
                    line = $lineNum
                    severity = "medium"
                    title = "Floating base tag at $rel line $lineNum"
                    detail = "FROM uses floating tag '$($matches[2])'. Pin to a specific version (e.g. 'alpine:3.19')."
                }
            }
        }
    }

    # ============================================================
    # SCAN 7: Canonical section headings (from Domain 9 Invariant 8)
    # ============================================================
    Write-Host "SCAN 7: Canonical section headings..."
    Get-ChildItem -Path (Join-Path $repoRoot "Skills") -Recurse -Filter "*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if ($rel -match '_build|Tasks') { return }
        if (-not (In-Scope $rel)) { return }
        $lines = Get-Content -LiteralPath $_.FullName
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line -match '^## Constraints$') {
                $findings += [PSCustomObject]@{
                    scan = "section-headings"
                    file = $rel
                    line = $lineNum
                    severity = "high"
                    title = "Non-canonical heading '## Constraints' in $rel line $lineNum"
                    detail = "Use '## Red lines' instead of '## Constraints' (canonical convention)."
                }
            }
            if ($line -match '^## Lessons Learned$') {
                $findings += [PSCustomObject]@{
                    scan = "section-headings"
                    file = $rel
                    line = $lineNum
                    severity = "high"
                    title = "Non-canonical heading '## Lessons Learned' in $rel line $lineNum"
                    detail = "Use '### Lessons Learned -- YYYY-MM-DD' (level 3 heading with date) instead of level-2 heading."
                }
            }
        }
    }

    # ============================================================
    # SCAN 8: Module parser validation (from Domain 7)
    # ============================================================
    Write-Host "SCAN 8: Module parser validation..."
    Get-ChildItem -Path $moduleDir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if (-not (In-Scope $rel)) { return }
        try {
            $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                $refFiltered = 0
                foreach ($err in $errors) {
                    # Filter out [ref] false positives -- parser reports these for valid
                    # [ref] parameter references that cross scope boundaries.
                    # Message varies by PS version:
                    #   PS 7.3-:   "[ref] cannot be applied to a variable that does not exist."
                    #   PS 7.4+:   "[ref] argument must be a variable, not a value."
                    #   PS 7.6.2:  returns via $errors, not exception
                    if ($err.Message -match '\[ref\]') { $refFiltered++; continue }
                    $findings += [PSCustomObject]@{
                        scan = "parser-validation"
                        file = $rel
                        line = $err.Extent.StartLine
                        severity = "high"
                        title = "Parse error in $rel line $($err.Extent.StartLine)"
                        detail = "$($err.Message)"
                    }
                }
                if ($refFiltered -gt 0) { Write-Host "    (filtered $refFiltered [ref] false positives in $rel)" }
            }
        } catch {
            # Filter out [ref] exceptions -- some PS versions throw instead of returning
            # them as parse errors in $errors
            if ($_.Exception.Message -match '\[ref\]') {
                Write-Host "    (suppressed [ref] exception: $($_.Exception.Message))"
                return
            }
            $findings += [PSCustomObject]@{
                scan = "parser-validation"
                file = $rel
                severity = "high"
                title = "Could not parse $rel"
                detail = "$($_.Exception.Message)"
            }
        }
    }

    # ============================================================
    # SCAN 9: TOCTOU on file writes (Test-Path then separate write)
    # ============================================================
    Write-Host "SCAN 9: TOCTOU on file writes..."
    Get-ChildItem -Path (Join-Path $repoRoot "Skills\Docker") -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if (-not (In-Scope $rel)) { return }
        $content = Get-Content -LiteralPath $_.FullName -Raw
        if ($content -match '(?s)Test-Path.*\n.*Set-Content|Test-Path.*\n.*Add-Content|Test-Path.*\n.*Out-File') {
            $findings += [PSCustomObject]@{
                scan = "toctou"
                file = $rel
                severity = "medium"
                title = "Potential TOCTOU in $rel"
                detail = "Test-Path followed by separate write call. Between check and write, another process could modify the path. Use -Force or wrap in retry loop."
            }
        }
    }

    # ============================================================
    # SCAN 10: TOCTOU on Test-Path + Add-Content (Domain 2 canned search)
    # ============================================================
    Write-Host "SCAN 10: Test-Path + Add-Content..."
    Get-ChildItem -Path (Join-Path $repoRoot "Skills\Docker") -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName)
        if (-not (In-Scope $rel)) { return }
        $content = Get-Content -LiteralPath $_.FullName -Raw
        if ($content -match 'Test-Path.*Add-Content') {
            $findings += [PSCustomObject]@{
                scan = "toctou"
                file = $rel
                severity = "medium"
                title = "Test-Path + Add-Content in $rel"
                detail = "Test-Path check followed by Add-Content on same path. Use Add-Content -Force instead of pre-checking."
            }
        }
    }

    # ============================================================
    # Write output
    # ============================================================
    $result = [PSCustomObject]@{
        scanDate = (Get-Date -Format "yyyy-MM-dd")
        scanSource = if ($PriorAuditHead) { "differential-on-$PriorAuditHead" } else { "full" }
        totalFilesScanned = $totalFileCount
        totalFindings = $findings.Count
        findingsByScan = $findings | Group-Object scan | ForEach-Object {
            [PSCustomObject]@{ scan = $_.Name; count = $_.Count }
        }
        findings = @($findings | Sort-Object severity, file)
    }

    if (-not $DryRun) {
        $null = New-Item -ItemType Directory -Path (Split-Path $OutputFile -Parent) -Force
        $result | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding utf8
        Write-Host "Written: $OutputFile ($($findings.Count) findings, $totalFileCount files scanned)"
    } else {
        Write-Host "[DRY-RUN] Would write: $OutputFile ($($findings.Count) findings, $totalFileCount files scanned)"
    }

    # Group summary
    Write-Host ""
    $findings | Group-Object scan | Sort-Object Name | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count) findings"
    }
} finally {
    if ($acquired -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
