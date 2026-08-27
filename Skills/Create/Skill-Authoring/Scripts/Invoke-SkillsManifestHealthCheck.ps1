param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot "..\..\..\skills.json"),
    [string]$IndexPath = (Join-Path $PSScriptRoot "..\..\..\skills-index.json"),
    [string]$SkillsRoot = (Join-Path $PSScriptRoot "..\..\.."),
    [switch]$PassThru,
    [switch]$FixIndex
)

$scriptName = "Invoke-SkillsManifestHealthCheck.ps1"
$exitCode = 0
$issues = @()

# Resolve repo root once
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")).Path.TrimEnd('\')
$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

function Test-FileExists {
    param([string]$Path)
    if ($Path -match '^~[/\\]') {
        # Home-relative path
        $resolved = Join-Path $homeDir $Path.Substring(2)
        return Test-Path $resolved
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return Test-Path $Path
    }
    # Repo-relative path
    $full = Join-Path $repoRoot $Path
    return Test-Path $full
}

Write-Host "=== Skills Manifest Health Check ===" -ForegroundColor Cyan

# ---- 1. Load manifest ----
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Manifest not found: $ManifestPath"
    exit 2
}
$registry = Get-Content $ManifestPath -Raw | ConvertFrom-Json
Write-Host "Manifest: $($registry.Count) entries" -ForegroundColor Gray

# ---- 2. Dead paths ----
Write-Host "`n[1/6] Checking for dead paths..." -ForegroundColor Yellow
$deadPaths = $registry | Where-Object {
    if ([string]::IsNullOrWhiteSpace($_.path)) { return $false }
    -not (Test-FileExists $_.path)
}
if ($deadPaths) {
    $deadPaths | ForEach-Object {
        $issues += "DEAD PATH: $($_.name) → $($_.path) (file not found)"
    }
    Write-Host "  Found $($deadPaths.Count) dead paths" -ForegroundColor Red
} else {
    Write-Host "  All paths valid" -ForegroundColor Green
}

# ---- 3. Broken cross_refs ----
Write-Host "[2/6] Checking cross_refs..." -ForegroundColor Yellow
$brokenRefs = $registry | ForEach-Object {
    $entry = $_
    $bad = @($entry.cross_refs | Where-Object { $_ -and -not (Test-FileExists $_) })
    if ($bad.Count -gt 0) {
        [PSCustomObject]@{ Entry = $entry.name; Broken = $bad }
    }
}
if ($brokenRefs) {
    $brokenRefs | ForEach-Object {
        $_.Broken | ForEach-Object {
            $issues += "BROKEN CROSS_REF: $($_.Entry) → $_"
        }
    }
    Write-Host "  Found $($brokenRefs.Count) entries with broken cross_refs" -ForegroundColor Red
} else {
    Write-Host "  All cross_refs valid" -ForegroundColor Green
}

# ---- 4. Orphaned files (skill .md not in manifest) ----
Write-Host "[3/6] Checking for orphaned skill files..." -ForegroundColor Yellow
$manifestPaths = $registry | ForEach-Object { $_.path.Replace('/', '\') }

# Exclude known non-skill file names (framework files, persona files, workflow support)
$excludedNames = @(
    'soul.md', 'identity.md', 'bootstrap.md', 'memory.md', 'heartbeat.md',
    'system-prompt.md', 'tools.md', 'workflow.md', 'user.md', 'environment.md',
    'git-repos.md', 'projects.md', 'protocols.md', 'boundaries.md', 'opencode-acp.md',
    'SKILL.md',
    'lessons-archive.md', 'session-plan-format.md', 'opencode-two-agent.md',
    'environment-tasks.md', 'groom-tasks.md', 'therapy.md',
    '_cowork-scripts.md', 'README.md'
)
# Exclude known non-skill directory patterns (matched against repo-relative path)
$excludedDirPatterns = @(
    '^Skills\\_build',
    '^Skills\\node_modules', '^Skills\\Tests', '^Skills\\Scripts',
    '^Skills\\_organizations', '^Skills\\Tasks', '^Skills\\Docker\\Modules\\.+\\Archive',
    '^Skills\\Plugins\\', '^Skills\\Codex\\AutoCode\\',
    '^Skills\\Docker\\Modules\\.+\\Templates', '^Skills\\ORCHESTRATOR\\Personas',
    '^Skills\\Shared', '^Skills\\Docker\\Modules\\.+\\_deprecated',
    '\\_deprecated\\',
    '^Skills\\Email\\Scripts\\node_modules',
    '\.pytest_cache',
    '^Skills\\Bookkeeping\\Tests',
    '^Skills\\Docker\\\d',
    '^Skills\\Docker\\Tests',
    '^Skills\\Workflows\\Audit\\alignment-audit-domain',
    '^Skills\\Workflows\\Audit\\architectural-audit',
    '^Skills\\Auditor\\alignment-audit-domain',
    '^Skills\\Bookkeeping\\',
    '^Skills\\Public\\',
    '^Skills\\Workflows\\Redeploy',
    '^Skills\\Refactor\\examples',
    '^Skills\\Refactor\\templates'
)

$orphaned = Get-ChildItem -Recurse -Filter "*.md" -Path $SkillsRoot | Where-Object {
    $rel = $_.FullName.Replace($repoRoot, '').TrimStart('\')
    $rel -notin $manifestPaths -and
    $_.Name -notin $excludedNames -and
    (-not ($excludedDirPatterns | Where-Object { $rel -match $_ } | Select-Object -First 1))
}
if ($orphaned) {
    $orphaned | ForEach-Object {
        $relPath = $_.FullName.Replace($repoRoot, '').TrimStart('\')
        $issues += "ORPHANED FILE: $relPath"
    }
    Write-Host "  Found $($orphaned.Count) orphaned files" -ForegroundColor Red
} else {
    Write-Host "  No orphaned files" -ForegroundColor Green
}

# ---- 5. Index/manifest agreement ----
Write-Host "[4/6] Checking index/manifest agreement..." -ForegroundColor Yellow
if (Test-Path $IndexPath) {
    $index = Get-Content $IndexPath -Raw | ConvertFrom-Json
    $indexNames = $index.PSObject.Properties.Name | Where-Object { $_ -ne '_meta' }
    $manifestActive = $registry | Where-Object { $_.stale -ne $true -and $_.type -ne 'archived' }
    $manifestNames = $manifestActive | ForEach-Object { $_.name }

    $missingFromIndex = $manifestNames | Where-Object { $_ -notin $indexNames }
    $staleInIndex = $indexNames | Where-Object { $_ -notin $manifestNames }

    if ($missingFromIndex) {
        $missingFromIndex | ForEach-Object {
            $issues += "INDEX MISSING: Active manifest entry '$_' not found in index"
        }
        Write-Host "  $($missingFromIndex.Count) entries missing from index" -ForegroundColor Red
    }
    if ($staleInIndex) {
        $staleInIndex | ForEach-Object {
            $issues += "INDEX STALE: Index entry '$_' has no active manifest entry (purged or renamed)"
        }
        Write-Host "  $($staleInIndex.Count) stale entries in index" -ForegroundColor Red
    }
    if (-not $missingFromIndex -and -not $staleInIndex) {
        Write-Host "  Index and manifest are in sync" -ForegroundColor Green
    }
} else {
    Write-Host "  Index not found at $IndexPath — skipping agreement check" -ForegroundColor Yellow
}

# ---- 6. Stale entries still on disk ----
Write-Host "[5/6] Checking for stale entries on disk..." -ForegroundColor Yellow
$staleOnDisk = Get-ChildItem -Recurse -Filter "*.md" -Path (Join-Path $SkillsRoot "_deprecated") -ErrorAction SilentlyContinue
if ($staleOnDisk) {
    $staleOnDisk | ForEach-Object {
        $issues += "STALE ON DISK: $($_.FullName) (in _deprecated/)"
    }
    Write-Host "  Found $($staleOnDisk.Count) stale files in _deprecated/" -ForegroundColor Yellow
} else {
    Write-Host "  No stale files on disk" -ForegroundColor Green
}

# ---- 7. Supersedes chain termination check ----
Write-Host "[6/6] Checking supersedes chain termination..." -ForegroundColor Yellow
$superseded = $registry | Where-Object { $_.superseded_by }
$brokenChains = $superseded | Where-Object {
    $target = $_.superseded_by
    -not ($registry | Where-Object { $_.path -eq $target -or $_.name -eq $target })
}
if ($brokenChains) {
    $brokenChains | ForEach-Object {
        $issues += "BROKEN CHAIN: $($_.name) superseded_by $($_.superseded_by) but target not found in manifest"
    }
    Write-Host "  Found $($brokenChains.Count) broken supersedes chains" -ForegroundColor Red
} else {
    Write-Host "  All supersedes chains valid" -ForegroundColor Green
}

# ---- Summary ----
Write-Host "`n=== Results ===" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "No issues found. Skills manifest is healthy." -ForegroundColor Green
    if ($PassThru) { return @{ Healthy = $true; Issues = @() } }
    exit 0
} else {
    Write-Host "$($issues.Count) issues found:" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($PassThru) { return @{ Healthy = $false; Issues = $issues } }
    exit 1
}

# ---- Auto-fix index if requested ----
if ($FixIndex -and (Test-Path $IndexPath)) {
    Write-Host "`nRebuilding index from manifest..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "Build-SkillsIndex.ps1") -ManifestPath $ManifestPath -OutputPath $IndexPath
}
