<#
.SYNOPSIS
    Returns the plan files in a pond that pass the entry gate.
.DESCRIPTION
    Reads the pond folder, applies SkipScheduled, SkipBlocked, DependencyReady,
    EvidenceGate, and RequiredHeaders rules, and returns the eligible files.
    Plans that fail RequiredHeaders or EvidenceGate are moved to the pond's
    Entry.OnInvalid location so they do not get stuck.
#>

function Test-PlanPondLogHasAction {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath,

        [Parameter(Mandatory)]
        [string]$Action
    )

    if (-not (Test-Path -LiteralPath $PlanPath)) { return $false }
    $log = @(Get-PlanPondLog -PlanPath $PlanPath)
    return @($log | Where-Object { $null -ne $_ -and $_.action -eq $Action }).Count -gt 0
}

function Test-PlanLegacyEvidence {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Action
    )

    $legacyMap = @{
        implement = '(?im)^\*\*Implementation\*\*:'
        review    = '(?im)^\*\*Reviewed\*\*:'
        audit     = '(?im)^\*\*Audit\*\*:'
        qa        = '(?im)^\*\*QA\*\*:'
    }
    if (-not $legacyMap.ContainsKey($Action)) { return $false }
    return $Content -match $legacyMap[$Action]
}

function Test-PlanHasEvidence {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath,

        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Action
    )

    return (Test-PlanPondLogHasAction -PlanPath $PlanPath -Action $Action) -or
           (Test-PlanLegacyEvidence -Content $Content -Action $Action)
}

function Get-PondCandidates {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $pondPath = Get-PondQueuePath -Pond $Pond -Context $Context
    if (-not (Test-Path -LiteralPath $pondPath)) { return @() }

    $files = Get-ChildItem "$pondPath/*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } |
        Sort-Object Name

    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $scheduledRe = '(?im)^\*\*Type\*\*:\s*scheduled-task\b'
    $blockedRe = '(?im)^\*\*Status\*\*:\s*blocked\b'

    foreach ($f in $files) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Scheduled plans stay out of the generic pipeline
        if ($Pond.Entry.SkipScheduled -and $content -match $scheduledRe) {
            Write-Verbose "Get-PondCandidates: skipping scheduled plan $($f.Name)"
            continue
        }

        # Blocked plans are not eligible yet
        if ($Pond.Entry.SkipBlocked -and $content -match $blockedRe) {
            Write-Verbose "Get-PondCandidates: skipping blocked plan $($f.Name)"
            continue
        }

        # DependencyReady: if the plan declares DependsOn entries, they must
        # exist in a completion pond (Complete, Archive, or ProjectReview).
        if ($Pond.Entry.DependencyReady) {
            $dependsRe = '(?im)^\*\*DependsOn\*\*:\s*(?<value>[^\r\n]+)'
            $depMatches = [regex]::Matches($content, $dependsRe)
            $unsatisfied = $false
            foreach ($m in $depMatches) {
                $deps = $m.Groups['value'].Value.Trim() -split ',\s*'
                foreach ($d in $deps) {
                    $d = $d.Trim()
                    if ([string]::IsNullOrWhiteSpace($d)) { continue }
                    if (-not (Test-PlanDependencySatisfied -Dependency $d -Context $Context)) {
                        Write-Verbose "Get-PondCandidates: skipping plan $($f.Name) with unsatisfied dependency '$d'"
                        $unsatisfied = $true
                        break
                    }
                }
                if ($unsatisfied) { break }
            }
            if ($unsatisfied) { continue }
        }

        # Required headers must be present; otherwise park the plan
        $missing = @()
        foreach ($h in $Pond.Entry.RequiredHeaders) {
            $headerRe = "(?im)^\*\*$h\*\*"
            if ($content -notmatch $headerRe) { $missing += $h }
        }
        if ($missing.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($Pond.Entry.OnInvalid)) {
                Write-Verbose "Get-PondCandidates: plan $($f.Name) missing headers $($missing -join ',') but OnInvalid is not set; leaving in place"
                continue
            }
            Write-Verbose "Get-PondCandidates: plan $($f.Name) missing headers $($missing -join ',') moving to $($Pond.Entry.OnInvalid)"
            $destDir = Join-Path $Context.TaskRoot $Pond.Entry.OnInvalid
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
            $dest = Join-Path $destDir $f.Name
            if (-not (Test-Path -LiteralPath $dest)) {
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        # Evidence gate: a plan must carry the right history in **PondLog**
        # (legacy evidence headers are still accepted for backward compatibility).
        $failedGate = $false
        switch ($Pond.Entry.EvidenceGate) {
            'implemented' {
                if (-not (Test-PlanHasEvidence -PlanPath $f.FullName -Content $content -Action 'implement')) {
                    $failedGate = $true
                }
            }
            'reviewed' {
                if (-not (Test-PlanHasEvidence -PlanPath $f.FullName -Content $content -Action 'review')) {
                    $failedGate = $true
                }
            }
            'qa-ready' {
                foreach ($requiredAction in @('implement','review','audit')) {
                    if (-not (Test-PlanHasEvidence -PlanPath $f.FullName -Content $content -Action $requiredAction)) {
                        $failedGate = $true
                        break
                    }
                }
            }
            'project-qa-ready' {
                foreach ($requiredAction in @('implement','review','audit')) {
                    if (-not (Test-PlanHasEvidence -PlanPath $f.FullName -Content $content -Action $requiredAction)) {
                        $failedGate = $true
                        break
                    }
                }
                if (-not $failedGate) {
                    $projectMatch = [regex]::Match($content, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
                    if ($projectMatch.Success) {
                        $projectId = $projectMatch.Groups['value'].Value.Trim()
                        $projectState = Get-PondProjectState -TaskRoot $Context.TaskRoot -ProjectId $projectId
                        # Legacy standalone plans with no parent remain eligible.
                        # Project children wait until the exact declared batch is in QA.
                        if ($projectState.Parent -and -not $projectState.AllInQA) { $failedGate = $true }
                    }
                }
            }
            'children-complete' {
                $dependsRe = '(?im)^\*\*DependsOn\*\*:\s*(?<value>[^\r\n]+)'
                $depMatches = [regex]::Matches($content, $dependsRe)
                $completionDirs = @(
                    (Join-Path $Context.TaskRoot 'Complete'),
                    (Join-Path $Context.TaskRoot 'Archive')
                )
                $allComplete = $true
                foreach ($m in $depMatches) {
                    $deps = $m.Groups['value'].Value.Trim() -split ',\s*'
                    foreach ($d in $deps) {
                        $d = $d.Trim()
                        if ([string]::IsNullOrWhiteSpace($d)) { continue }
                        $depFile = if ($d -notlike '*.md') { "$d.md" } else { $d }
                        $found = $false
                        $childComplete = $false
                        foreach ($dir in $completionDirs) {
                            if (-not (Test-Path -LiteralPath $dir)) { continue }
                            $depFiles = @(Get-ChildItem -Path "$dir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $depFile })
                            if ($depFiles.Count -gt 0) {
                                $found = $true
                                $childLog = @(Get-PlanPondLog -PlanPath $depFiles[0].FullName)
                                $childComplete = @($childLog | Where-Object { $null -ne $_ -and $_.action -eq 'complete' }).Count -gt 0
                                if (-not $childComplete) {
                                    # Backward compatibility: accept legacy plans in
                                    # Complete/Archive that do not yet have a
                                    # **PondLog** section.
                                    $childContent = Get-Content -LiteralPath $depFiles[0].FullName -Raw -ErrorAction SilentlyContinue
                                    $childComplete = $childContent -notmatch '(?im)^\*\*PondLog\*\*'
                                }
                                break
                            }
                        }
                        if (-not $found -or -not $childComplete) {
                            Write-Verbose "Get-PondCandidates: plan $($f.Name) waiting for child '$d'"
                            $allComplete = $false
                            break
                        }
                    }
                    if (-not $allComplete) { break }
                }
                if (-not $allComplete) { $failedGate = $true }
            }
            default {
                # No evidence gate configured or unrecognized value; pass through.
            }
        }

        if ($failedGate) {
            if ([string]::IsNullOrWhiteSpace($Pond.Entry.OnInvalid)) {
                Write-Verbose "Get-PondCandidates: plan $($f.Name) failed evidence gate '$($Pond.Entry.EvidenceGate)' but OnInvalid is not set; leaving in place"
                continue
            }
            Write-Verbose "Get-PondCandidates: plan $($f.Name) failed evidence gate '$($Pond.Entry.EvidenceGate)' moving to $($Pond.Entry.OnInvalid)"
            $destDir = Join-Path $Context.TaskRoot $Pond.Entry.OnInvalid
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
            $dest = Join-Path $destDir $f.Name
            if (-not (Test-Path -LiteralPath $dest)) {
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        $candidates.Add($f)
    }

    return $candidates.ToArray()
}
