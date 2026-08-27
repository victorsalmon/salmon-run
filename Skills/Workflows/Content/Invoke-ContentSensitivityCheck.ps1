<#
.SYNOPSIS
    Mechanical enforcement of the Intimate-Victor content-sensitivity boundary (ADR-0001).
.DESCRIPTION
    Checks three violation classes:
      1. Committed tool caches / derived artifacts (FAIL)
      2. Misused PII placeholder tokens - [ADDRESS] standing in for a person's name (FAIL)
      3. Missing boundary documentation (WARN)
    Exits 1 if any FAIL is found, 0 otherwise. Always emits a
    [CONTENT-SENSITIVITY] summary line.
.NOTES
    Dependency-free: uses only System.Management.Automation and git.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = (Get-Location).Path
)

$fails = @()
$warns = @()
$clean = 0

# --- Check 1: committed cache / derived artifacts --------------------------
$cachePatterns = @('\.vision-cache\.json$', '\.cache$', '^Thumbs\.db$', '^~\$')
$tracked = git -C $RepoRoot ls-files 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "git ls-files failed for $RepoRoot"
    exit 1
}
foreach ($file in $tracked) {
    foreach ($pattern in $cachePatterns) {
        if ($file -match $pattern) {
            $fails += "committed cache artifact: $file"
            break
        }
    }
}

# --- Check 2: placeholder misuse (person's name redacted as [ADDRESS]) ----
$accountabilityDir = Join-Path $RepoRoot "Accountability"
if (Test-Path -LiteralPath $accountabilityDir) {
    $markdown = git -C $RepoRoot ls-files -- "Accountability/*.md" 2>$null
    foreach ($rel in $markdown) {
        $abs = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $abs)) { continue }
        $content = Get-Content -LiteralPath $abs -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'LISA \[ADDRESS\]|named \[ADDRESS\]') {
            $fails += "placeholder misuse (name redacted as [ADDRESS]): $rel"
        }
    }
} else {
    $warns += "Accountability/ directory not found - placeholder check skipped"
}

# --- Check 3: boundary documentation freshness ----------------------------
$requiredDocs = @(
    "AGENTS.md",
    "docs/Reference/Decisions/ADR-0001-content-sensitivity-boundary.md"
)
foreach ($doc in $requiredDocs) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $doc))) {
        $warns += "missing boundary doc: $doc"
    } else {
        $clean++
    }
}
if (Test-Path -LiteralPath (Join-Path $RepoRoot "docs/Redaction-Policy.md")) {
    $clean++
} else {
    $warns += "missing boundary doc: docs/Redaction-Policy.md"
}

# --- Report ----------------------------------------------------------------
foreach ($f in $fails) { Write-Output "[CONTENT-SENSITIVITY] FAIL - $f" }
foreach ($w in $warns) { Write-Output "[CONTENT-SENSITIVITY] WARN - $w" }
Write-Output "[CONTENT-SENSITIVITY] summary: $clean clean, $($fails.Count) FAIL, $($warns.Count) WARN"

if ($fails.Count -gt 0) { exit 1 }
exit 0
