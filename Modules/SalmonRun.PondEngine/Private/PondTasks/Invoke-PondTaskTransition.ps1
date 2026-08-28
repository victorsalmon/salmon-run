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

    # A provider process exiting zero only means the agent ran. Quality ponds
    # must also record an explicit passing verdict. This is repeated here as a
    # trust-boundary check even though external executors validate before
    # writing their sentinel.
    $decisionContract = switch ($Pond.Name) {
        'Review'       { @{ Decision = 'ReviewDecision'; Evidence = 'Reviewed' } }
        'Audit'        { @{ Decision = 'AuditDecision'; Evidence = 'Audit' } }
        'QA'           { @{ Decision = 'QADecision'; Evidence = 'QA' } }
        'ProjectReview'{ @{ Decision = 'ProjectReviewDecision'; Evidence = 'ProjectReview' } }
        default        { $null }
    }
    if ($Context.Success -and $decisionContract) {
        foreach ($verdictFile in $files) {
            $verdictContent = Get-Content -LiteralPath $verdictFile.FullName -Raw
            $decisionMatch = [regex]::Match($verdictContent, "(?im)^\*\*$($decisionContract.Decision)\*\*:\s*(?<value>[^\r\n]+)")
            $evidenceMatch = [regex]::Match($verdictContent, "(?im)^\*\*$($decisionContract.Evidence)\*\*:\s*(?<value>[^\r\n]+)")
            $passed = ($decisionMatch.Success -and $decisionMatch.Groups['value'].Value.Trim() -match '^pass(?:ed)?\b') -or
                      ($evidenceMatch.Success -and $evidenceMatch.Groups['value'].Value.Trim() -match '^(passed|completed)\b')
            $failed = ($decisionMatch.Success -and $decisionMatch.Groups['value'].Value.Trim() -match '^(rework|fail(?:ed)?|reject(?:ed)?|blocked)\b') -or
                      ($evidenceMatch.Success -and $evidenceMatch.Groups['value'].Value.Trim() -match '^(failed|rework|rejected|blocked)\b')
            if ($failed -or -not $passed) { $Context.Success = $false; break }
        }
    }

    if (-not $Context.Success -and $Pond.Name -eq 'Review') {
        $feedbackDir = Join-Path $Context.TaskRoot 'Feedback'
        $null = New-Item -ItemType Directory -Path $feedbackDir -Force
        foreach ($reviewFile in $files) {
            $reviewContent = Get-Content -LiteralPath $reviewFile.FullName -Raw
            $reasonMatch = [regex]::Match($reviewContent, '(?im)^\*\*(ReviewSummary|Reviewed)\*\*:\s*(?<value>[^\r\n]+)')
            $reason = if ($reasonMatch.Success) { $reasonMatch.Groups['value'].Value.Trim() } else { 'Review did not record an explicit passing verdict.' }
            $feedbackName = "$($reviewFile.BaseName)-review.md"
            $feedbackPath = Join-Path $feedbackDir $feedbackName
            @"
# Review feedback: $($reviewFile.BaseName)

**ReviewDecision**: rework
**ReviewedPlan**: $($reviewFile.Name)
**RecordedAt**: $(Get-Date -Format 'o')

## Summary

$reason
"@ | Set-Content -LiteralPath $feedbackPath -Encoding utf8 -NoNewline

            $headers = [ordered]@{
                ReviewDecision = 'rework'
                ReviewSummary = $reason
                ReviewFeedbackFile = $feedbackName
                ReviewedPlan = $reviewFile.Name
            }
            foreach ($header in $headers.GetEnumerator()) {
                $pattern = "(?im)^\*\*$([regex]::Escape($header.Key))\*\*:\s*[^\r\n]+"
                $line = "**$($header.Key)**: $($header.Value)"
                if ($reviewContent -match $pattern) { $reviewContent = $reviewContent -replace $pattern, $line }
                else { $reviewContent += "`n$line" }
            }
            Set-Content -LiteralPath $reviewFile.FullName -Value $reviewContent -Encoding utf8 -NoNewline
        }
    }

    if ($Context.Success -and $Pond.Name -eq 'QA') {
        $projectGroups = $files | Group-Object {
            $qaContent = Get-Content -LiteralPath $_.FullName -Raw
            $projectMatch = [regex]::Match($qaContent, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
            if ($projectMatch.Success) { $projectMatch.Groups['value'].Value.Trim() } else { $_.BaseName }
        }
        foreach ($projectGroup in $projectGroups) {
            $null = Write-PondProjectQaEvidence -TaskRoot $Context.TaskRoot -ProjectId $projectGroup.Name -PlanFiles @($projectGroup.Group)
        }
    }

    $destPondName = if ($Context.Success) { $Pond.OnSuccess.MoveTo } else { $Pond.OnFailure.MoveTo }
    if ([string]::IsNullOrWhiteSpace($destPondName)) {
        Write-Verbose "Invoke-PondTaskTransition: no transition for pond '$($Pond.Name)'"
        return $Context
    }

    $destDir = Join-Path $Context.TaskRoot $destPondName
    $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue

    $sourcePaths = @($files | ForEach-Object { $_.FullName })
    $destFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

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
        $destFiles.Add((Get-Item -LiteralPath $dest))

        # Mark the plan's status based on the outcome.
        $c = Get-Content -LiteralPath $dest -Raw
        $newStatus = if ($Context.Success) { 'ready' } else { 'blocked' }
        if ($Context.Success -and $Pond.OnSuccess.MoveTo -eq 'Complete') {
            $newStatus = 'complete'
        }
        if (-not $Context.Success -and $finalDest -notin @('Complete','Failed')) {
            # The plan is being retried in a work pond; leave it eligible so the
            # next matching lane can pick it up. The Retry counter already tracks
            # how many times it has failed.
            $newStatus = 'ready'
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

    # A successful final project review becomes one self-contained evidence
    # bundle. Include every old/new path so task-repo commits preserve moves.
    if ($Context.Success -and $Pond.Name -eq 'ProjectReview' -and $destFiles.Count -eq 1) {
        $parentDest = $destFiles[0].FullName
        $parentContent = Get-Content -LiteralPath $parentDest -Raw
        $depMatch = [regex]::Match($parentContent, '(?im)^\*\*DependsOn\*\*:\s*(?<value>[^\r\n]+)')
        $projectIdMatch = [regex]::Match($parentContent, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
        $projectId = if ($projectIdMatch.Success) { $projectIdMatch.Groups['value'].Value.Trim() } else { $destFiles[0].BaseName }
        $children = if ($depMatch.Success) { @($depMatch.Groups['value'].Value -split ',\s*' | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Trim()) }) } else { @() }
        foreach ($child in $children) {
            $oldChild = Join-Path $Context.TaskRoot "Complete/$child.md"
            if (Test-Path -LiteralPath $oldChild) { $sourcePaths += $oldChild }
        }
        $oldQa = Join-Path $Context.TaskRoot "QA/$projectId-qa.json"
        if (Test-Path -LiteralPath $oldQa) { $sourcePaths += $oldQa }
        $feedbackRoot = Join-Path $Context.TaskRoot 'Feedback'
        if (Test-Path -LiteralPath $feedbackRoot) {
            foreach ($feedback in Get-ChildItem -LiteralPath $feedbackRoot -File -ErrorAction SilentlyContinue) {
                if ($children | Where-Object { $feedback.BaseName -like "$_-*" }) { $sourcePaths += $feedback.FullName }
            }
        }
        $bundle = Complete-PondProjectBundle -TaskRoot $Context.TaskRoot -ProjectPlanPath $parentDest
        $destFiles.Clear()
        foreach ($bundleFile in Get-ChildItem -LiteralPath $bundle -File -Recurse) { $destFiles.Add($bundleFile) }
        $finalDest = "Complete/$projectId"
    }

    # Clean up sentinel files and empty lane directory.
    Remove-Item -Path "$lanePath/.*" -Force -ErrorAction SilentlyContinue
    $laneRemaining = @(Get-ChildItem $lanePath -Force -ErrorAction SilentlyContinue)
    if ($laneRemaining.Count -eq 0) {
        Remove-Item -LiteralPath $lanePath -Force -ErrorAction SilentlyContinue
    }

    # Commit and push the .salmon task repo and the target code repo for every transition.
    $firstName = $files[0].Name
    $commitMsg = "move: $firstName from $($Pond.Name) to $finalDest"
    Push-PondRepos -Pond $Pond -Context $Context -FinalDest $finalDest -SourcePaths $sourcePaths -DestFiles $destFiles -CommitMessage $commitMsg

    Write-Verbose "Invoke-PondTaskTransition: moved $($files.Count) plan(s) from '$($Pond.Name)' to '$finalDest' (success=$($Context.Success))"
    return $Context
}
