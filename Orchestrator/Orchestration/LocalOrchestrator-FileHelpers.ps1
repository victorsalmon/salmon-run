<#
.SYNOPSIS
    File helper functions for LocalOrchestrator.ps1.
#>

<#
.SYNOPSIS
    Extracts the namespace portion from a task filename.
.DESCRIPTION
    Strips date prefix, environment prefix, and iteration suffix to
    produce a clean namespace string used for connascence grouping.
    Example: "2026.05.22-alignment-comments2.md" → "alignment-comments".
.PARAMETER FileName
    Task file name (e.g. "2026.05.22-task1.md").
#>
function Get-FileNamespace {
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -creplace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}[-.]\d{2}[-.]\d{2}-?', ''

    if ($base -match '^(.+)-(\d+)$') {
        return $matches[1]
    }

    if ($base -match '^(.+?)-\d+') {
        return $matches[1]
    }

    if ($base -match '-') {
        $base = $base -replace '\d+$', ''
        if ([string]::IsNullOrWhiteSpace($base)) { return 'ungrouped' }
        return ($base -replace '^-|-$', '')
    }

    return 'ungrouped'
}

<#
.SYNOPSIS
    Groups .md files in a directory by namespace extracted from filenames.
.DESCRIPTION
    Lists .md files in a directory, extracts namespace from filename via
    Get-FileNamespace, groups by namespace. No file content reads — purely
    filename-based. Used by the reactive orchestrator for stream creation.
.PARAMETER Directory
    Path to the directory to scan (e.g. Tasks/Code/ or Tasks/Review/).
#>
function Get-NamespaceGroups {
    param([string]$Directory)
    $files = Get-ChildItem "$Directory\*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    $groups = @{}
    foreach ($f in $files) {
        $ns = Get-FileNamespace -FileName $f.Name
        if (-not $groups.ContainsKey($ns)) { $groups[$ns] = [System.Collections.Generic.List[string]]::new() }
        $groups[$ns].Add($f.Name)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($ns in ($groups.Keys | Sort-Object)) {
        $result.Add([PSCustomObject]@{
            Namespace = $ns
            Files     = $groups[$ns].ToArray()
        })
    }
    return $result
}

# ==============================================================================
# FILE LOCK PRIMITIVES — REMOVED: migrated to SalmonRun.Core/Public/Lock-File.ps1
# ==============================================================================
# Lock-File, Unlock-File, and aliases were consolidated into the SalmonRun.Core
# module to eliminate the duplicate implementation (Core's version had a
# partial-claim deadlock bug). The Core version is now the canonical ADR-compliant
# all-or-nothing batch lock.
#
# Test-FileLock is preserved here as a lightweight read-only helper.
# LockDir helpers are handled by SalmonRun.Core internally.
# ==============================================================================

<#
.SYNOPSIS
    Tests whether a file lock exists.
.DESCRIPTION
    Returns $true if Tasks/Locks/<name>.lock exists, $false otherwise.
    Does not acquire or release the lock.
.PARAMETER FileName
    Single lock name to check.
#>
function Test-FileLock {
    param([string]$FileName)
    $repoRoot = Get-InterclawRepoRoot
    $lockPath = Join-Path $repoRoot "Tasks" "Locks" "$FileName.lock"
    return Test-Path $lockPath
}
