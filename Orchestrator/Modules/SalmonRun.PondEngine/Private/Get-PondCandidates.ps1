<#
.SYNOPSIS
    Returns the plan files in a pond that pass the entry gate.
.DESCRIPTION
    Reads the pond folder, applies SkipScheduled, SkipBlocked, DependencyReady,
    EvidenceGate, and RequiredHeaders rules, and returns the eligible files.
    Plans that fail RequiredHeaders or EvidenceGate are moved to the pond's
    Entry.OnInvalid location so they do not get stuck.
#>
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

        # Evidence gate: a plan in Review must carry implementation evidence
        if ($Pond.Entry.EvidenceGate -eq 'implemented') {
            $hasLock = $content -match '(?im)^\*\*Lock\*\*'
            $hasValidation = $content -match '(?im)^\*\*Validation\*\*'
            if (-not ($hasLock -and $hasValidation)) {
                if ([string]::IsNullOrWhiteSpace($Pond.Entry.OnInvalid)) { continue }
                Write-Verbose "Get-PondCandidates: plan $($f.Name) missing evidence moving to $($Pond.Entry.OnInvalid)"
                $destDir = Join-Path $Context.TaskRoot $Pond.Entry.OnInvalid
                $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
                $dest = Join-Path $destDir $f.Name
                if (-not (Test-Path -LiteralPath $dest)) {
                    Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                }
                continue
            }
        }

        $candidates.Add($f)
    }

    return $candidates.ToArray()
}
