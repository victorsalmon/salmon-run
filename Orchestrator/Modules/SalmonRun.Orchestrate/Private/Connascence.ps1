<#
.SYNOPSIS
    Namespace extraction, file grouping, and lock testing for connascence-based dispatch.
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

function Test-FileLock {
    param([string]$FileName)
    $repoRoot = $script:RepoRoot
    $lockPath = Join-Path $repoRoot "Tasks" "Locks" "$FileName.lock"
    return Test-Path $lockPath
}

function Prepend-StreamLog {
    <#
    .SYNOPSIS
        DEPRECATED — Prepends a log entry to stream.log
    .DESCRIPTION
        Agents no longer write stream.log. The Lock Header on the session plan
        file is the canonical per-file log. This function is retained for
        backward compatibility with orphaned stream directories from prior
        orchestrator runs. New code should not call this.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Backward-compatible helper retained for legacy stream.log consumers')]
    param([string]$StreamDir, [string]$Entry)
    $log = Join-Path $StreamDir "stream.log"
    $existing = if (Test-Path $log) { Get-Content $log -Raw -ErrorAction SilentlyContinue } else { "" }
    "$Entry`n$existing" | Set-Content $log -Encoding utf8 -NoNewline
}

function Test-IsFatalError {
    param(
        $Counts,
        $CgResult,
        [string]$StreamDir,
        [hashtable]$ActiveStreams,
        [string]$PidLockFile
    )
    if (-not $Counts) { return $true }
    # Missing connascence data is recoverable — fall back to naive namespace grouping.
    if (-not $cgResult) { return $false }
    if ($PidLockFile -and -not (Test-Path $PidLockFile)) { return $true }
    if ($StreamDir) {
        $streamJson = Join-Path $StreamDir "stream.json"
        if (Test-Path $streamJson) {
            $hasMdFiles = (Get-ChildItem "$StreamDir/*.md" -ErrorAction SilentlyContinue).Count -gt 0
            $hasComplete = Test-Path (Join-Path $StreamDir ".complete")
            if (-not $hasMdFiles -and -not $hasComplete) { return $true }
        }
    }
    return $false
}
