<#
.SYNOPSIS
    Pre-flight automated sweep for the Functional Audit. Scans all operational
    entry-point scripts for error-handling gaps, null-safety issues, hard-coded
    paths, TOCTOU races, and other reliability patterns.
.DESCRIPTION
    Runs 10 deterministic scans across the same script inventory the Functional
    Audit domains cover. Results are written as JSON findings to an output file
    that domain agents load before their manual analysis. This eliminates
    redundant grep searches across all 6 domains.

    Differential mode: pass -PriorAuditHead to only scan files changed since
    that git ref.
.PARAMETER OutputFile
    Path to write JSON findings. Default: Tasks/Logs/functional-scan-<date>.json
.PARAMETER PriorAuditHead
    Git ref (commit hash, tag, or HEAD~N) to diff against for differential mode.
    Only files changed since this ref will be scanned.
.PARAMETER RepoRoot
    Repository root path. Auto-detected from git if not provided.
.PARAMETER IncludePatterns
    File glob patterns to scan. Default: operational entry-point patterns.
.EXAMPLE
    # Full scan
    .\Invoke-FunctionalScan.ps1
.EXAMPLE
    # Differential scan
    .\Invoke-FunctionalScan.ps1 -PriorAuditHead HEAD~1
#>

[CmdletBinding()]
param(
    [string]$OutputFile,
    [string]$PriorAuditHead,
    [string]$RepoRoot,
    [string[]]$IncludePatterns = @(
        'Skills/Docker/Modules/Interclaw.*/Public/*.ps1',
        'Skills/Docker/Modules/Interclaw.*/Private/*.ps1',
        'Skills/Docker/*.ps1',
        'Orchestrator/Orchestration/*.ps1',
        'Skills/Bookkeeping/Scripts/*.ps1',
        'Skills/Bookkeeping/Scripts/*.py',
        'Skills/Bookkeeping/Scripts/*.js',
        'Skills/Bookkeeping/Scripts/*.mjs',
        'Infrastructure/**/*.ps1',
        'Infrastructure/**/*.sh',
        'Infrastructure/**/*.js'
    )
)

# --- Setup ---
$sessionStart = Get-Date
$findings = @()

if (-not $RepoRoot) {
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if (-not $gitRoot) {
        $RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    } else {
        $RepoRoot = $gitRoot
    }
}

if (-not $OutputFile) {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $OutputFile = Join-Path $RepoRoot 'Tasks/Logs' "functional-scan-$today.json"
}

# Ensure output directory exists
$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

Write-Host "[Invoke-FunctionalScan] Scanning from $RepoRoot" -ForegroundColor Cyan
Write-Host "[Invoke-FunctionalScan] Output: $OutputFile" -ForegroundColor Cyan
if ($PriorAuditHead) {
    Write-Host "[Invoke-FunctionalScan] Differential mode: changes since $PriorAuditHead" -ForegroundColor Yellow
}

# --- File discovery ---
$allFiles = @()
foreach ($pattern in $IncludePatterns) {
    $resolved = Get-ChildItem -Path (Join-Path $RepoRoot $pattern) -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Select-Object -ExpandProperty FullName
    $allFiles += $resolved
}
$allFiles = $allFiles | Sort-Object -Unique

# In differential mode, filter to changed files only
if ($PriorAuditHead) {
    $changed = & git -C $RepoRoot diff --name-only "$PriorAuditHead..HEAD" 2>$null
    $changedSet = @($changed | ForEach-Object { $_ -replace '\\', '/' } | ForEach-Object {
        (Join-Path $RepoRoot $_).Replace('\', '/')
    })
    $allFiles = $allFiles | Where-Object {
        $normalized = $_.Replace('\', '/')
        $normalized -in $changedSet
    }
}

Write-Host "[Invoke-FunctionalScan] Files to scan: $($allFiles.Count)" -ForegroundColor Cyan

if ($allFiles.Count -eq 0) {
    Write-Host "[Invoke-FunctionalScan] No files to scan — writing empty results" -ForegroundColor Yellow
    $result = @{
        scan_date = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        scan_version = 1
        prior_audit_head = $PriorAuditHead
        total_files = 0
        total_findings = 0
        findings = @()
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $OutputFile -Encoding utf8
    return
}

# --- Scan 1: Missing try/catch around external calls ---
Write-Host "[Scan 1/10] Missing try/catch around external calls..." -ForegroundColor Gray
$scan1 = @()
$externalCallPatterns = @(
    'Invoke-NativeCommand\b',
    'Invoke-Docker\b',
    'aws\s',
    'docker\s',
    'curl\s',
    'Invoke-RestMethod\b',
    'Invoke-WebRequest\b'
)
foreach ($file in $allFiles) {
    $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    # Comment/string mask: 1 = code char, 0 = inside comment or string literal.
    # Prevents brace counting and external-call matching inside comments, help
    # text, and string literals (e.g. a log message mentioning "docker stack").
    $inCode = New-Object bool[] $content.Length
    $state = 'code'  # code | line-comment | block-comment | double-string | single-string | double-here | single-here
    for ($ci = 0; $ci -lt $content.Length; $ci++) {
        $ch = $content[$ci]
        $nxt = if ($ci + 1 -lt $content.Length) { $content[$ci + 1] } else { '' }
        switch ($state) {
            'code' {
                if ($ch -eq '<' -and $nxt -eq '#') { $state = 'block-comment' }
                elseif ($ch -eq '#' -and ($ci -eq 0 -or $content[$ci - 1] -match '\s|;')) { $state = 'line-comment' }
                elseif ($ch -eq '"') { $state = if ($nxt -eq '@') { 'double-here' } else { 'double-string' } }
                elseif ($ch -eq "'") { $state = if ($nxt -eq '@') { 'single-here' } else { 'single-string' } }
                else { $inCode[$ci] = $true }
            }
            'line-comment' { if ($ch -eq "`n") { $state = 'code'; $inCode[$ci] = $true } }
            'block-comment' { if ($ch -eq '#' -and $nxt -eq '>') { $state = 'code'; $ci++ } }
            'double-string' {
                if ($ch -eq '`') { $ci++ }
                elseif ($ch -eq '"') { $state = 'code'; $inCode[$ci] = $true }
            }
            'single-string' {
                if ($ch -eq "'" -and $nxt -eq "'") { $ci++ }
                elseif ($ch -eq "'") { $state = 'code'; $inCode[$ci] = $true }
            }
            'double-here' {
                if ($ch -eq '"' -and $nxt -eq '@') { $state = 'code'; $ci++ }
                elseif ($ch -eq "`n") { $inCode[$ci] = $true }
            }
            'single-here' {
                if ($ch -eq "'" -and $nxt -eq '@') { $state = 'code'; $ci++ }
                elseif ($ch -eq "`n") { $inCode[$ci] = $true }
            }
        }
    }
    # Brace-aware try/catch scope map: for each char index, 1 = inside a
    # try/catch/finally/trap frame, 0 = outside. More accurate than the old
    # "nearest try above" heuristic, which wrongly flagged calls in sibling
    # try blocks (any earlier catch ended the scope).
    $inTryScope = New-Object bool[] $content.Length
    $handlerBraceIdx = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($hm in [regex]::Matches($content, 'try\s*(\([^)]*\))?\s*\{|catch\s*(\([^)]*\))?\s*\{|finally\s*(\([^)]*\))?\s*\{|trap\s*(\([^)]*\))?\s*\{')) {
        $null = $handlerBraceIdx.Add($hm.Index + $hm.Length - 1)
    }
    $depth = 0
    $handlerStack = New-Object 'System.Collections.Generic.Stack[int]'
    for ($ci = 0; $ci -lt $content.Length; $ci++) {
        if (-not $inCode[$ci]) { continue }
        $ch = $content[$ci]
        if ($ch -eq '{') {
            $depth++
            if ($handlerBraceIdx.Contains($ci)) { $handlerStack.Push($depth) }
        } elseif ($ch -eq '}') {
            if ($handlerStack.Count -gt 0 -and $depth -eq $handlerStack.Peek()) { $null = $handlerStack.Pop() }
            if ($depth -gt 0) { $depth-- }
        }
        if ($handlerStack.Count -gt 0) { $inTryScope[$ci] = $true }
    }
    foreach ($pattern in $externalCallPatterns) {
        $matches = [regex]::Matches($content, $pattern)
        foreach ($m in $matches) {
            # Skip matches inside comments/strings and command lookups
            # (e.g. Get-Command docker — a cmdlet argument, not an external call)
            $inCodeCtx = $m.Index -lt $content.Length -and $inCode[$m.Index]
            if (-not $inCodeCtx) { continue }
            $lookupPrefix = if ($m.Index -ge 30) { $content.Substring($m.Index - 30, 30) } else { $content.Substring(0, $m.Index) }
            if ($lookupPrefix -match '(Get-Command|Get-Process|Get-Content|Get-Item|Test-Path|Get-NetFirewallRule)\s+$') { continue }
            # Check if this match is inside a try/catch/finally scope via the brace map
            $inTry = $m.Index -lt $content.Length -and $inTryScope[$m.Index]
            if (-not $inTry) {
                # Find line number
                $safeIndex = [Math]::Min($m.Index, $content.Length)
                $lineNum = ($content.Substring(0, $safeIndex) -split "`n").Count
                $scan1 += [PSCustomObject]@{
                    file = $file
                    line = $lineNum
                    match = $m.Value
                    detail = "External call '$($m.Value)' not wrapped in try/catch"
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 1
    scan_name = 'Missing try/catch around external calls'
    description = 'Calls to Invoke-NativeCommand, Invoke-Docker, aws, docker, curl, Invoke-RestMethod, or Invoke-WebRequest that are not inside a try/catch block'
    severity = 'High'
    count = $scan1.Count
    results = $scan1 | Select-Object -First 50  # cap output size
    total_found = $scan1.Count
}

# --- Scan 2: -ErrorAction SilentlyContinue without -ErrorVariable ---
Write-Host "[Scan 2/10] -ErrorAction SilentlyContinue without -ErrorVariable..." -ForegroundColor Gray
$scan2 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '-ErrorAction\s+SilentlyContinue') {
            # Check if the same statement has -ErrorVariable
            $statementEnd = $i
            while ($statementEnd -lt $lines.Count -and $lines[$statementEnd] -notmatch '^\s*$' -and $lines[$statementEnd] -notmatch '[;{}]') {
                $statementEnd++
            }
            $statementBlock = ($lines[$i..$statementEnd] -join ' ')
            if ($statementBlock -notmatch '-ErrorVariable') {
                $scan2 += [PSCustomObject]@{
                    file = $file
                    line = $i + 1
                    match = $line.Trim()
                    detail = "-ErrorAction SilentlyContinue without -ErrorVariable on line $($i+1)"
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 2
    scan_name = '-ErrorAction SilentlyContinue without -ErrorVariable'
    description = 'Errors silently swallowed with no way to inspect them'
    severity = 'Medium'
    count = $scan2.Count
    results = $scan2 | Select-Object -First 50
    total_found = $scan2.Count
}

# --- Scan 3: Empty catch blocks ---
Write-Host "[Scan 3/10] Empty catch blocks..." -ForegroundColor Gray
$scan3 = @()
foreach ($file in $allFiles) {
    $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    # Match catch blocks: catch { } or catch { $_ } or catch { \n }
    $emptyCatches = [regex]::Matches($content, 'catch\s*\{[^a-zA-Z0-9_]*\}')
    foreach ($m in $emptyCatches) {
        $safeIndex = [Math]::Min($m.Index, $content.Length)
        $lineNum = ($content.Substring(0, $safeIndex) -split "`n").Count
                $v3 = ($m.Value -replace '\s+', ' ').Trim(); $match3 = if ($v3.Length -gt 60) { $v3.Substring(0, 60) } else { $v3 }
                $scan3 += [PSCustomObject]@{
                    file = $file
                    line = $lineNum
                    match = $match3
                    detail = "Empty catch block — errors silently dropped"
                }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 3
    scan_name = 'Empty catch blocks'
    description = 'catch { } blocks that silently discard errors without logging or remediation'
    severity = 'High'
    count = $scan3.Count
    results = $scan3 | Select-Object -First 50
    total_found = $scan3.Count
}

# --- Scan 4: $null-unsafe variable passing ---
Write-Host "[Scan 4/10] Potential `$null-unsafe variable passing..." -ForegroundColor Gray
$scan4 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Check for common patterns where a function result is passed without null check
        if ($lines[$i] -match '\$\w+\s*=\s*(Get-|Invoke-|Read-|Find-|Receive-)' -and
            $lines[$i] -notmatch '\#\s*\$null' -and
            $lines[$i] -notmatch '\| Select-Object -First 1') {
            # Check the next few lines for a null check
            $hasNullCheck = $false
            for ($j = 1; $j -le 5 -and ($i + $j) -lt $lines.Count; $j++) {
                if ($lines[$i + $j] -match '\$null\s*(-eq|-ne|-eq\s+\$null|-ne\s+\$null)') {
                    $hasNullCheck = $true
                    break
                }
            }
            if (-not $hasNullCheck) {
                $varName = $lines[$i] -replace '^.*\$(\w+)\s*=.*', '$1'
                $scan4 += [PSCustomObject]@{
                    file = $file
                    line = $i + 1
                    match = $lines[$i].Trim().Substring(0, [Math]::Min(80, $lines[$i].Trim().Length))
                    detail = "Result of '$varName' not null-checked within 5 lines"
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 4
    scan_name = 'Potential $null-unsafe variable passing'
    description = 'Function results stored in variables without subsequent null check'
    severity = 'Medium'
    count = $scan4.Count
    results = $scan4 | Select-Object -First 50
    total_found = $scan4.Count
}

# --- Scan 5: Hard-coded absolute paths ---
Write-Host "[Scan 5/10] Hard-coded absolute paths..." -ForegroundColor Gray
$scan5 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '[A-Za-z]:\\[^"''\s]' -and
            $lines[$i] -notmatch '^\s*#' -and
            $lines[$i] -notmatch '\$env:' -and
            $lines[$i] -notmatch 'Join-Path' -and
            $lines[$i] -notmatch 'Split-Path' -and
            $lines[$i] -notmatch '\\\\wsl\$' -and
            $lines[$i] -notmatch '\\\\localhost' -and
            $lines[$i] -notmatch 'C:\\Windows') {
            # Skip matches that are part of a provider path (e.g. "v:\FOO" inside
            # "Env:\FOO" or "M:\SOFTWARE" inside "HKLM:\SOFTWARE") — the char
            # before the drive letter is a letter when it is a provider name.
            $pathMatches = [regex]::Matches($lines[$i], '[A-Za-z]:\\[^"''\s,).;]*')
            $realPath = $null
            foreach ($pm in $pathMatches) {
                $precededByLetter = $pm.Index -gt 0 -and $lines[$i][$pm.Index - 1] -match '[A-Za-z]'
                if (-not $precededByLetter) { $realPath = $pm; break }
            }
            if ($realPath) {
                $scan5 += [PSCustomObject]@{
                    file = $file
                    line = $i + 1
                    match = $realPath.Value
                    detail = "Hard-coded absolute path '$($realPath.Value)' — use Join-Path with `$PSScriptRoot instead"
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 5
    scan_name = 'Hard-coded absolute paths'
    description = 'Drive-letter absolute paths that break when script is moved or run on another host'
    severity = 'Medium'
    count = $scan5.Count
    results = $scan5 | Select-Object -First 50
    total_found = $scan5.Count
}

# --- Scan 6: | Out-Null or [void]() discarding error-producing expressions ---
Write-Host "[Scan 6/10] `| Out-Null / [void]() discarding errors..." -ForegroundColor Gray
$scan6 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '\| Out-Null\b' -or $lines[$i] -match '\[void\]\(') {
            $scan6 += [PSCustomObject]@{
                file = $file
                line = $i + 1
                match = $lines[$i].Trim().Substring(0, [Math]::Min(60, $lines[$i].Trim().Length))
                detail = 'Error-stream is discarded — errors are invisible'
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 6
    scan_name = '| Out-Null / [void]() discarding errors'
    description = 'Expressions piped to Out-Null or cast to [void]() — errors in these expressions are silently dropped'
    severity = 'Medium'
    count = $scan6.Count
    results = $scan6 | Select-Object -First 50
    total_found = $scan6.Count
}

# --- Scan 7: Start-Sleep without rationale comment ---
Write-Host "[Scan 7/10] Start-Sleep without rationale comment..." -ForegroundColor Gray
$scan7 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Start-Sleep\b') {
            # Check previous 2 lines for a comment explaining why
            $hasRationale = $false
            for ($j = 1; $j -le 2 -and ($i - $j) -ge 0; $j++) {
                if ($lines[$i - $j] -match '^\s*#' -or $lines[$i - $j] -match '<#' ) {
                    $hasRationale = $true
                    break
                }
            }
            if (-not $hasRationale) {
                $scan7 += [PSCustomObject]@{
                    file = $file
                    line = $i + 1
                    match = $lines[$i].Trim().Substring(0, [Math]::Min(60, $lines[$i].Trim().Length))
                    detail = 'Sleep without rationale comment — magic timer is fragile'
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 7
    scan_name = 'Start-Sleep without rationale comment'
    description = 'Start-Sleep calls without a preceding comment explaining why the wait is needed'
    severity = 'Low'
    count = $scan7.Count
    results = $scan7 | Select-Object -First 50
    total_found = $scan7.Count
}

# --- Scan 8: Path concatenation with + instead of Join-Path ---
Write-Host "[Scan 8/10] Path concatenation with `+` instead of Join-Path..." -ForegroundColor Gray
$scan8 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '["'']\s*\+\s*["'']' -and
            $lines[$i] -match '\\' -and
            $lines[$i] -notmatch 'Join-Path' -and
            $lines[$i] -notmatch '^\s*#') {
            $scan8 += [PSCustomObject]@{
                file = $file
                line = $i + 1
                match = $lines[$i].Trim().Substring(0, [Math]::Min(60, $lines[$i].Trim().Length))
                detail = 'String concatenation for path — use Join-Path for portability'
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 8
    scan_name = 'Path concatenation with + instead of Join-Path'
    description = 'Path fragments joined with string concatenation instead of Join-Path — breaks on trailing-slash differences'
    severity = 'Low'
    count = $scan8.Count
    results = $scan8 | Select-Object -First 50
    total_found = $scan8.Count
}

# --- Scan 9: Test-Path then separate write (TOCTOU) ---
Write-Host "[Scan 9/10] Test-Path + separate write (TOCTOU)..." -ForegroundColor Gray
$scan9 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Test-Path\b') {
            # Check next 3 lines for a write operation
            for ($j = 1; $j -le 3 -and ($i + $j) -lt $lines.Count; $j++) {
                if ($lines[$i + $j] -match '\b(Set-Content|Out-File|Add-Content|New-Item|Remove-Item|Copy-Item|Move-Item)\b') {
                    $scan9 += [PSCustomObject]@{
                        file = $file
                        line = $i + 1
                        match = $lines[$i].Trim().Substring(0, [Math]::Min(60, $lines[$i].Trim().Length))
                        detail = "Test-Path followed by write on line $($i + $j + 1) — TOCTOU race"
                    }
                    break
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 9
    scan_name = 'Test-Path + separate write (TOCTOU)'
    description = 'File existence check followed by write — file could be created/deleted between check and write'
    severity = 'Medium'
    count = $scan9.Count
    results = $scan9 | Select-Object -First 50
    total_found = $scan9.Count
}

# --- Scan 10: Missing parameter validation ---
Write-Host "[Scan 10/10] Missing parameter validation..." -ForegroundColor Gray
$scan10 = @()
foreach ($file in $allFiles) {
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'param\s*\(' -or $lines[$i] -match '\[Parameter\(') {
            # Skip single-line param(...) — nothing to scan after the closing paren
            if ($lines[$i] -match '\)\s*(#.*)?$') { continue }
            # Check if there are parameter declarations without [Validate*] attributes
            $inParams = $true
            for ($j = $i + 1; $j -lt $lines.Count -and $inParams; $j++) {
                if ($lines[$j] -match '\)') { $inParams = $false; break }
                if ($lines[$j] -match '\$\w+' -and
                    $lines[$j] -notmatch '\[Validate' -and
                    $lines[$j] -notmatch '^\s*#' -and
                    $lines[$j] -notmatch '\[switch\]') {
                    $paramName = [regex]::Match($lines[$j], '\$(\w+)').Value
                    $scan10 += [PSCustomObject]@{
                        file = $file
                        line = $j + 1
                        match = $lines[$j].Trim()
                        detail = "Parameter $paramName lacks [ValidateNotNull()] or [ValidateSet()]"
                    }
                }
            }
        }
    }
}
$findings += [PSCustomObject]@{
    scan_id = 10
    scan_name = 'Missing parameter validation'
    description = 'Parameters declared without [ValidateNotNull()], [ValidateSet()], [ValidateScript()], or similar attributes'
    severity = 'Low'
    count = $scan10.Count
    results = $scan10 | Select-Object -First 50
    total_found = $scan10.Count
}

# --- Write output ---
$totalFindings = ($findings | ForEach-Object { $_.total_found } | Measure-Object -Sum).Sum
$result = @{
    scan_date = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    scan_version = 1
    prior_audit_head = $PriorAuditHead
    total_files = $allFiles.Count
    total_findings = $totalFindings
    findings = $findings | ForEach-Object {
        @{
            scan_id = $_.scan_id
            scan_name = $_.scan_name
            description = $_.description
            severity = $_.severity
            count = $_.total_found
            results = $_.results
        }
    }
}

$result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputFile -Encoding utf8

$elapsed = [math]::Round(((Get-Date) - $sessionStart).TotalSeconds, 0)
Write-Host "[Invoke-FunctionalScan] Complete — $totalFindings findings across $($allFiles.Count) files in ${elapsed}s" -ForegroundColor Green
Write-Host "[Invoke-FunctionalScan] Results written to $OutputFile" -ForegroundColor Green
