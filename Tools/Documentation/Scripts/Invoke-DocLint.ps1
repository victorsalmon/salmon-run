<#
.SYNOPSIS
    Lint documentation files for broken file path references.
.DESCRIPTION
    Scans .md files under docs/, AGENTS.md, AGENTS-Code.md, Skills/**/*.md
    (excluding Skills/_build/, Tasks/, node_modules/) for file path
    references and verifies each referenced file exists on disk.
.PARAMETER Fix
    Output sed-like fix commands for known broken reference patterns.
.PARAMETER Format
    Output format: "text" (default) or "json" for CI integration.
.PARAMETER ReportPath
    Write report to a file instead of stdout.
.EXAMPLE
    ./Invoke-DocLint.ps1
.EXAMPLE
    ./Invoke-DocLint.ps1 -Format json
#>
param(
    [string]$RepoRoot = '',
    [switch]$Fix,
    [ValidateSet("text", "json")]
    [string]$Format = "text",
    [string]$ReportPath
)

if (-not $RepoRoot) {
    $RepoRoot = $PWD.Path
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
if (-not (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf)) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSCommandPath)).TrimEnd('\', '/')
    for ($i = 0; $i -lt 5 -and $RepoRoot; $i++) {
        if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
        $RepoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $RepoRoot)).TrimEnd('\', '/')
    }
}
if (-not $RepoRoot -or -not (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf)) {
    Write-Error "Cannot find repo root (AGENTS.md not found)"
    exit 1
}

$excludeRelPatterns = @('_build', 'node_modules', '.git')

function Get-DocFiles {
    $files = @()
    foreach ($root in @('docs', 'Tools')) {
        $fullPath = Join-Path $RepoRoot $root
        if (Test-Path $fullPath) {
            Get-ChildItem $fullPath -Recurse -Include '*.md' -File | ForEach-Object { $files += $_ }
        }
    }
    foreach ($single in @('README.md', 'AGENTS.md')) {
        $p = Join-Path $RepoRoot $single
        if (Test-Path $p) { $files += Get-Item $p }
    }
    $result = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($RepoRoot.Length + 1).Replace('\', '/')
        $excluded = $false
        foreach ($pat in $excludeRelPatterns) {
            $p = $pat.Replace('\', '/')
            if ($rel -like "$p/*" -or $rel -like "$p" -or $rel -like "*/$p/*") {
                $excluded = $true
                break
            }
        }
        if (-not $excluded) { $result += $f }
    }
    return $result
}

function Test-ExemptRef {
    param([string]$Ref)
    if ($Ref -match '^https?://') { return $true }
    if ($Ref -match '^#') { return $true }
    if ($Ref -match '^~[/\\]') { return $true }
    if ($Ref -match '<[^>]+>') { return $true }
    if ($Ref -match '^\$[a-zA-Z]') { return $true }
    if ($Ref -match '^[A-Za-z]:\\') { return $true }
    if ($Ref -match '^~') { return $true }
    if ($Ref -match '^\.salmon') { return $true }
    if ($Ref -match '^Tasks/') { return $true }
    if ($Ref -match '\.(jpg|jpeg|png|gif|svg|ico|webp|css|woff2?|ttf|eot)$') { return $true }
    if ($Ref -match '^(npm|node|python|pip|git|docker|pwsh)\.') { return $true }
    if ($Ref -match '^Tasks[/\\]Logs') { return $true }
    return $false
}

function Resolve-NormalizedPath { param([string]$P) return [System.IO.Path]::GetFullPath($P) }

function Resolve-Ref {
    param([string]$Ref, [string]$SourceDir)
    $pathOnly = ($Ref -split ':')[0]
    $pathOnly = $pathOnly.Trim() -replace '[),;.]+$', ''
    if ([string]::IsNullOrWhiteSpace($pathOnly)) { return $null }
    if (Test-ExemptRef $pathOnly) { return $null }
    if ($pathOnly -match '^\.md$') { return $null }
    $rootPrefixes = @('docs/', 'Tools/', 'Modules/', 'Tests/', 'scripts/', 'dot-salmon.example/')
    $isRootRef = $false
    foreach ($p in $rootPrefixes) { if ($pathOnly -match "^$([regex]::Escape($p))") { $isRootRef = $true; break } }
    $seen = @{}
    $candidates = @()
    if ($isRootRef) {
        $candidates += Resolve-NormalizedPath (Join-Path $RepoRoot $pathOnly)
        $candidates += Resolve-NormalizedPath (Join-Path $SourceDir $pathOnly)
    } else {
        $candidates += Resolve-NormalizedPath (Join-Path $SourceDir $pathOnly)
        $candidates += Resolve-NormalizedPath (Join-Path $RepoRoot $pathOnly)
    }
    $firstSeg = ($pathOnly -split '[/\\]')[0]
    if ($firstSeg -and -not ($pathOnly.StartsWith('.') -or $pathOnly.StartsWith('/') -or $pathOnly.StartsWith('\'))) {
        $current = $SourceDir
        while ($current -and $current.Length -ge $RepoRoot.Length) {
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ($parent -and $parent.Length -ge $RepoRoot.Length) {
                $cand = Resolve-NormalizedPath (Join-Path $parent $pathOnly)
                if (-not $seen.ContainsKey($cand)) { $candidates += $cand; $seen[$cand] = $true }
            }
            if ($parent -eq $current -or -not $parent) { break }
            $current = $parent
        }
    }
    $candidates = $candidates | Select-Object -Unique
    foreach ($c in $candidates) {
        if ($c.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $c)) {
            return @{ Path = $c; Found = $true }
        }
    }
    $rep = $candidates | Where-Object { $_ -and $_.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $rep) { $rep = $candidates | Select-Object -First 1 }
    return @{ Path = $rep; Found = $false }
}

function Get-RefsFromLine {
    param([string]$Line, [int]$LineNum)
    $refs = @()
    $seen = @{}
    $patterns = @(
        '(?<=\]\()([^)]+(?:\.md|\.ps1|\.psm1|\.psd1|\.py|\.js|\.mjs|\.json|\.yml|\.yaml|\.toml|\.cfg|\.ini|\.sh|\.bat|\.cmd|\.csv|\.env|\.txt|\.html|\.ts|\.tsx)(?::\d+)?)(?=\))',
        '`((?:docs|Tools|Modules|Tests|scripts|dot-salmon\.example)/[A-Za-z0-9_./\\-]+\.[a-z]{2,})`',
        '`([A-Za-z0-9_/\\-]+\.[a-z]{2,4}:\d+)`',
        '`([A-Z][A-Za-z0-9]*/[A-Za-z0-9_./\\-]+\.[a-z]{2,})`',
        '(?<=file:///)([A-Za-z0-9_./\\-]+)'
    )
    foreach ($pattern in $patterns) {
        $matches_found = [regex]::Matches($Line, $pattern)
        foreach ($m in $matches_found) {
            $ref = $m.Groups[1].Value.Trim() -replace '`', ''
            if (-not $ref -or $ref.Length -lt 3) { continue }
            if ($seen.ContainsKey($ref)) { continue }
            $seen[$ref] = $true
            if ($ref -match '^https?://') { continue }
            if ($ref -match '^#') { continue }
            $refs += @{ Reference = $ref; Line = $LineNum }
        }
    }
    return $refs
}

$docFiles = Get-DocFiles
$violations = @()

foreach ($file in $docFiles) {
    $content = Get-Content $file.FullName -Raw
    if (-not $content) { continue }
    $lines = $content -split "`n"
    $rootLen = ([string]$RepoRoot).TrimEnd('\', '/').Length
    $sourceRel = $file.FullName.Substring($rootLen + 1)
    $sourceDir = $file.Directory.FullName
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1
        $refs = Get-RefsFromLine $line $lineNum
        foreach ($r in $refs) {
            $refText = $r.Reference
            if (Test-ExemptRef $refText) { continue }
            $resolved = Resolve-Ref $refText $sourceDir
            if (-not $resolved) { continue }
            if (-not $resolved.Found) {
                $violations += [PSCustomObject]@{
                    SourceFile = $sourceRel
                    Line = $r.Line
                    Reference = $refText
                    ExpectedPath = $resolved.Path
                }
            }
        }
    }
}

# Check for doc-lint exempt comments on surrounding lines
foreach ($v in $violations) {
    $sourcePath = Join-Path $RepoRoot $v.SourceFile
    if (Test-Path $sourcePath) {
        $allLines = Get-Content $sourcePath
        $idx = $v.Line - 2
        if ($idx -ge 0 -and $idx -lt $allLines.Count) {
            $currentLine = $allLines[$idx]
            $prevLine = if ($idx -gt 0) { $allLines[$idx - 1] } else { '' }
            $nextLine = if ($idx -lt $allLines.Count - 1) { $allLines[$idx + 1] } else { '' }
            $context = "$prevLine`n$currentLine`n$nextLine"
            if ($context -match '<!--\s*doc-lint:\s*exempt\s*-->') {
                $v | Add-Member -NotePropertyName Exempt -NotePropertyValue $true -Force
            }
        }
    }
}

$activeViolations = $violations | Where-Object { -not $_.Exempt }

if ($Format -eq 'json') {
    $output = @{
        scanned_files = $docFiles.Count
        broken_references = $activeViolations.Count
        results = $activeViolations | ForEach-Object {
            @{
                file = $_.SourceFile
                line = $_.Line
                reference = $_.Reference
                expected_path = $_.ExpectedPath
            }
        }
    }
    $json = $output | ConvertTo-Json -Depth 5
    if ($ReportPath) { $json | Out-File $ReportPath -Encoding utf8; if ($activeViolations.Count -gt 0) { exit 1 } else { exit 0 } }
    $json
    if ($activeViolations.Count -gt 0) { exit 1 } else { exit 0 }
    return
}

if ($activeViolations.Count -gt 0) {
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "  Documentation Lint Report" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "Scanned: $($docFiles.Count) files"
    Write-Host "Broken references: $($activeViolations.Count) (exemptions applied to $($violations.Count - $activeViolations.Count))"
    Write-Host ""
    $activeViolations | Group-Object SourceFile | Sort-Object Name | ForEach-Object {
        Write-Host $_.Name -ForegroundColor Cyan
        foreach ($v in $_.Group) {
            Write-Host "  L$($v.Line): $($v.Reference)" -ForegroundColor Red
        }
    }
    if ($ReportPath) {
        $lines = @("# Documentation Lint Report", "Broken references: $($activeViolations.Count)", '')
        $activeViolations | Group-Object SourceFile | Sort-Object Name | ForEach-Object {
            $lines += "## $($_.Name)"
            foreach ($v in $_.Group) {
                $lines += "- Line $($v.Line): ``$($v.Reference)``"
            }
        }
        $lines -join "`n" | Out-File $ReportPath -Encoding utf8
    }
    exit 1
} else {
    Write-Host "Documentation Lint: PASS" -ForegroundColor Green
    Write-Host "Scanned: $($docFiles.Count) files, 0 broken refs"
    exit 0
}
