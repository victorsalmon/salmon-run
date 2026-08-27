function Invoke-PondTaskTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }

    $lanePath = $group.StreamPath
    if ([string]::IsNullOrWhiteSpace($lanePath)) {
        $Context.Continue = $false
        return $Context
    }

    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return $Context }

    $destPondName = if ($Context.Success) { $Pond.OnSuccess.MoveTo } else { $Pond.OnFailure.MoveTo }
    if ([string]::IsNullOrWhiteSpace($destPondName)) {
        Write-Verbose "Invoke-PondTaskTransition: no transition for pond '$($Pond.Name)'"
        return $Context
    }

    $destDir = Join-Path $Context.TaskRoot $destPondName
    $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue

    # Retry logic for failure transitions back to the same pond.
    $finalDest = $destPondName
    $retry = 0
    if (-not $Context.Success -and $destPondName -eq $Pond.Name) {
        $first = $files | Select-Object -First 1
        $content = Get-Content -LiteralPath $first.FullName -Raw
        $retry = 0
        if ($content -match '(?im)^\*\*Retry\*\*:\s*(?<value>\d+)') {
            $retry = [int]$Matches['value'].Trim()
        }
        $retry++
        if ($retry -ge $Pond.OnFailure.MaxRetries) {
            $finalDest = $Pond.OnFailure.FinalMoveTo
            $destDir = Join-Path $Context.TaskRoot $finalDest
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
        } else {
            # Mark the retry count on every plan file.
            foreach ($f in $files) {
                $c = Get-Content -LiteralPath $f.FullName -Raw
                $c = $c -replace '(?im)^\*\*Retry\*\*:\s*\d+\r?\n?', ''
                $c = $c + "`n`n**Retry**: $retry`n"
                $c | Set-Content -LiteralPath $f.FullName -Encoding utf8 -NoNewline
            }
        }
    }

    foreach ($file in $files) {
        $dest = Join-Path $destDir $file.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop

        # Mark the plan's status based on the outcome.
        $c = Get-Content -LiteralPath $dest -Raw
        $newStatus = if ($Context.Success) { 'ready' } else { 'blocked' }
        if ($Context.Success -and $Pond.OnSuccess.MoveTo -eq 'Complete') {
            $newStatus = 'complete'
        }
        if ($c -match '(?im)^\*\*Status\*\*:\s*[^\r\n]+') {
            $c = $c -replace '(?im)^\*\*Status\*\*:\s*[^\r\n]+', "**Status**: $newStatus"
        } else {
            $c = $c + "`n`n**Status**: $newStatus`n"
        }
        $c | Set-Content -LiteralPath $dest -Encoding utf8 -NoNewline

        # Append a transition event to the canonical **PondLog** history.
        $action = $null
        $detail = $null
        if ($Context.Success) {
            $action = 'complete'
            $detail = "moved from $($Pond.Name) to $finalDest"
        } else {
            if ($destPondName -eq $Pond.Name) {
                if ($retry -lt $Pond.OnFailure.MaxRetries) {
                    $action = 'retry'
                    $detail = "retry $retry of $($Pond.OnFailure.MaxRetries) in $($Pond.Name)"
                } else {
                    $action = 'fail'
                    $detail = "exceeded max retries in $($Pond.Name); moved to $finalDest"
                }
            } else {
                if ($finalDest -in @('Failed','Tasks/Failed')) {
                    $action = 'fail'
                    $detail = "moved from $($Pond.Name) to $finalDest"
                } else {
                    $action = 'retry'
                    $detail = "moved from $($Pond.Name) back to $finalDest after failure"
                }
            }
        }

        if ($action) {
            $null = Add-PlanPondLog -PlanPath $dest -Entry @{
                ts     = (Get-Date -Format 'o')
                pond   = $Pond.Name
                role   = $Pond.Role
                action = $action
                detail = $detail
                agent  = 'PondEngine'
            } -ErrorAction Stop
        }

        # If the plan carries an explicit **Override** header, log it as history.
        $c = Get-Content -LiteralPath $dest -Raw
        if ($c -match '(?im)^\*\*Override\*\*:\s*(?<value>[^\r\n]+)') {
            $overrideValue = $Matches['value'].Trim()
            $null = Add-PlanPondLog -PlanPath $dest -Entry @{
                ts     = (Get-Date -Format 'o')
                pond   = $Pond.Name
                role   = $Pond.Role
                action = 'override'
                detail = $overrideValue
                agent  = 'PondEngine'
            } -ErrorAction Stop
            $c = $c -replace '(?im)^\*\*Override\*\*:\s*[^\r\n]+\r?\n?', ''
            $c | Set-Content -LiteralPath $dest -Encoding utf8 -NoNewline
        }
    }

    # Clean up sentinel files and empty lane directory.
    Remove-Item -Path "$lanePath/.*" -Force -ErrorAction SilentlyContinue
    $laneRemaining = @(Get-ChildItem $lanePath -Force -ErrorAction SilentlyContinue)
    if ($laneRemaining.Count -eq 0) {
        Remove-Item -LiteralPath $lanePath -Force -ErrorAction SilentlyContinue
    }

    Write-Verbose "Invoke-PondTaskTransition: moved $($files.Count) plan(s) from '$($Pond.Name)' to '$finalDest' (success=$($Context.Success))"
    return $Context
}
