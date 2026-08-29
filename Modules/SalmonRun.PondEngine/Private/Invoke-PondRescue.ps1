function Invoke-PondRescue {
    <#
    .SYNOPSIS
        Rescues stale or failed plan files back to a source pond.
    .DESCRIPTION
        Scans -SourceDir for files matching -RescuePlan and moves them to
        -TargetDir. Files are considered stale if their last write time is older
        than -StaleThresholdSeconds. Existing files in the target are not
        overwritten; instead a numbered suffix is appended.
    .PARAMETER SourceDir
        Directory to scan (e.g. Tasks/Working or Tasks/Failed).
    .PARAMETER TargetDir
        Directory to move rescued files into.
    .PARAMETER StaleThresholdSeconds
        Age in seconds above which a file is rescued. Default 300.
    .PARAMETER RescuePlan
        Optional. If supplied, only files whose names match this wildcard pattern are rescued.
    .OUTPUTS
        PSCustomObject with Rescued, Skipped, and Errors counts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [Parameter(Mandatory)]
        [string]$TargetDir,

        [int]$StaleThresholdSeconds = 300,

        [string]$RescuePlan = '*.md'
    )

    $rescued = 0
    $skipped = 0
    $errors = 0

    if (-not (Test-Path $SourceDir)) { return [pscustomobject]@{ Rescued = 0; Skipped = 0; Errors = 0 } }
    $null = New-Item -ItemType Directory -Path $TargetDir -Force

    $cutoff = (Get-Date).AddSeconds(-$StaleThresholdSeconds)
    $files = Get-ChildItem -Path "$SourceDir\$RescuePlan" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($file in $files) {
        try {
            $dest = Join-Path $TargetDir $file.Name
            if (Test-Path $dest) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $ext = [System.IO.Path]::GetExtension($file.Name)
                $dest = Join-Path $TargetDir "$base-rescued$ext"
                $counter = 1
                while (Test-Path $dest) {
                    $dest = Join-Path $TargetDir "$base-rescued-$counter$ext"
                    $counter++
                }
            }
            Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
            $rescued++
        } catch {
            Write-Warning "POND_RESCUE_FAILED file=$($file.Name) error=$($_.Exception.Message)"
            $errors++
        }
    }

    return [pscustomobject]@{ Rescued = $rescued; Skipped = $skipped; Errors = $errors }
}

function Invoke-PondLaneRecovery {
    <# Recover only proven orphans: dead PID, stale heartbeat, stable lease generation, no result. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkingDir,
        [Parameter(Mandatory)][string]$TaskRoot,
        [int]$StaleThresholdSeconds = 300
    )

    $rescued = 0; $skipped = 0; $errors = 0
    if (-not (Test-Path -LiteralPath $WorkingDir)) { return [pscustomobject]@{ Rescued=0; Skipped=0; Errors=0 } }
    $cutoff = [datetimeoffset]::Now.AddSeconds(-$StaleThresholdSeconds)
    foreach ($lane in Get-ChildItem -LiteralPath $WorkingDir -Directory -ErrorAction SilentlyContinue) {
        $plans = @(Get-ChildItem -LiteralPath $lane.FullName -Filter '*.md' -File -ErrorAction SilentlyContinue)
        if ($plans.Count -eq 0) { continue }
        $leasePath = Join-Path $lane.FullName '.lease.json'
        $lease = if (Test-Path -LiteralPath $leasePath) { Get-Content -LiteralPath $leasePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue } else { $null }
        if (-not $lease -or [string]::IsNullOrWhiteSpace([string]$lease.generation) -or [string]::IsNullOrWhiteSpace([string]$lease.sourcePond)) {
            $reason = "lane $($lane.Name) has no valid coordinator lease"
            $paused = Move-PondLaneToEngineError -LanePath $lane.FullName -TaskRoot $TaskRoot -PondName 'Recovery' -Reason $reason
            $errors += [math]::Max(1, $paused.Moved)
            continue
        }

        # A completed provider result belongs to the transition reaper, never orphan rescue.
        if ((Test-Path (Join-Path $lane.FullName '.complete')) -or (Test-Path (Join-Path $lane.FullName '.failed'))) { $skipped++; continue }

        $lanePid = 0
        [void][int]::TryParse([string]$lease.processId, [ref]$lanePid)
        if ($lanePid -gt 0 -and (Get-Process -Id $lanePid -ErrorAction SilentlyContinue)) { $skipped++; continue }

        $heartbeat = ConvertTo-PondLeaseTimestamp -Value $lease['heartbeatAt']
        if ($null -eq $heartbeat) {
            $reason = "lane $($lane.Name) has an invalid lease heartbeat"
            $paused = Move-PondLaneToEngineError -LanePath $lane.FullName -TaskRoot $TaskRoot -PondName ([string]$lease.sourcePond) -Reason $reason
            $errors += [math]::Max(1, $paused.Moved)
            continue
        }
        if ($heartbeat -ge $cutoff) { $skipped++; continue }

        $observedAt = ConvertTo-PondLeaseTimestamp -Value $lease['recoveryObservedAt']
        $sameGeneration = ([string]($lease['recoveryObservedGeneration']) -eq [string]($lease['generation']))
        $hasOldObservation = $sameGeneration -and $null -ne $observedAt -and $observedAt -lt $cutoff
        if (-not $hasOldObservation) {
            $lease['recoveryObservedGeneration'] = $lease['generation']
            $lease['recoveryObservedAt'] = [datetimeoffset]::UtcNow.ToString('o')
            $tmp = "$leasePath.tmp-$PID-$([guid]::NewGuid().ToString('n'))"
            $lease | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
            Move-Item -LiteralPath $tmp -Destination $leasePath -Force
            $skipped++
            continue
        }

        try {
            $target = [string]$lease.sourcePond
            $targetDir = Join-Path $TaskRoot $target
            $result = Invoke-PondRescue -SourceDir $lane.FullName -TargetDir $targetDir -StaleThresholdSeconds 0
            $rescued += $result.Rescued
            $errors += $result.Errors
            if (@(Get-ChildItem -LiteralPath $lane.FullName -Filter '*.md' -File -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $lane.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $errors++
            Write-Warning "POND_LANE_RECOVERY_FAILED lane=$($lane.Name) error=$($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Rescued=$rescued; Skipped=$skipped; Errors=$errors }
}






