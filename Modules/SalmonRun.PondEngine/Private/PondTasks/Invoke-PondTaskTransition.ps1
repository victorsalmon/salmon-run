function Add-PondReworkFeedback {
    <#
    .SYNOPSIS
        Ensures a `## Feedback for Coder` section exists on a plan file that
        is being sent back to a work pond.
    .DESCRIPTION
        If the plan already contains a `## Feedback for Coder` section, this
        function is a no-op.  Otherwise it extracts the failure reason from the
        legacy evidence header (Reviewed/QA/Audit/Implementation) and appends a
        structured feedback block before the **PondLog** section.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PondName,

        [Parameter(Mandatory)]
        [string]$PlanPath
    )

    $content = Get-Content -LiteralPath $PlanPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { return }

    # If a feedback section already exists, do not overwrite it.
    if ($content -match '(?im)^## Feedback for Coder\s*$') { return }

    $header = switch ($PondName) {
        'Review'   { 'Reviewed' }
        'Audit'    { 'Audit' }
        'QA'       { 'QA' }
        'Code'     { 'Implementation' }
        default    { $PondName }
    }

    $m = [regex]::Match($content, "(?im)^\*\*$header\*\*:\s*failed by (?<provider>[^\-]+(?:-[^\-]+)*)\s+-\s+(?<reason>[^\r\n]+)")
    if (-not $m.Success) { return }

    $reason = $m.Groups['reason'].Value.Trim()
    $checks = @($reason -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($checks.Count -eq 0) { $checks = @($reason) }

    $failedLines = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $checks.Count; $i++) {
        $null = $failedLines.AppendLine("$($i + 1). $($checks[$i])")
    }

    $feedback = @"

## Feedback for Coder

|**Source**: $PondName
|**Verdict**: failed
|**FailedChecks**:
$($failedLines.ToString().TrimEnd())
|**FixActions**:
1. Resolve every FailedCheck above.
2. Re-run the plan's **Validation Rubric** or equivalent quality checks.
3. Update the **$header** evidence line to a passing result.
4. Record how each item was resolved in the **PondLog**.
"@

    # Insert before the **PondLog** block if one exists, otherwise append at the end.
    $pondLogMatch = [regex]::Match($content, '(?im)^(\*\*PondLog\*\*|```json\s*\[)\s*$')
    if ($pondLogMatch.Success) {
        $insertAt = $pondLogMatch.Index
        $content = $content.Insert($insertAt, $feedback + "`n`n")
    } else {
        $content += "`n$feedback`n"
    }

    $content | Set-Content -LiteralPath $PlanPath -Encoding utf8 -NoNewline
}

function Get-PondPlanActiveFile {
    <#
    .SYNOPSIS
        Returns the active file for a lane group.
    .DESCRIPTION
        The active file is the family member with the highest plan feedback
        sequence number (original = 0, -feedback1 = 1, etc.).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$Files
    )

    if ($Files.Count -eq 0) { return $null }

    $sorted = @($Files | Sort-Object { (Get-PondFilePlanSequence -FileName $_.Name) }, Name -Descending)
    return $sorted[0]
}

function Test-PlanHasDecisionRequired {
    <#
    .SYNOPSIS
        Returns $true if the plan content signals a human decision is needed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $decisionRequired = $Content -match '(?im)^\*\*DecisionRequired\*\*:\s*(?:yes|true|required)\b'
    $questionsSection = $Content -match '(?im)^## Questions\s*$'
    return $decisionRequired -or $questionsSection
}

function Test-PlanTransientFailure {
    <#
    .SYNOPSIS
        Returns $true if a failure should be treated as a transient timeout
        and retried in the current pond.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$ActiveFile,

        [int]$TimeoutMinutes = 30
    )

    $log = @(Get-PlanPondLog -PlanPath $ActiveFile.FullName)
    if ($log.Count -eq 0) { return $false }

    # (a) The latest PondLog entry is a timeout or mentions one.
    $latest = $log | Select-Object -Last 1
    $condA = $latest -and (
        $latest.action -eq 'external-timeout' -or
        ($latest.detail -and $latest.detail -match 'timeout')
    )

    # (b) The spawn and external-fail/external-timeout timestamps are within
    #     two minutes of the configured timeout length.
    $condB = $false
    $spawn = @($log | Where-Object { $_.action -eq 'spawn' }) | Select-Object -Last 1
    $fail  = @($log | Where-Object { $_.action -in @('external-fail','external-timeout') }) | Select-Object -Last 1
    if ($spawn -and $fail) {
        [datetimeoffset]$spawnTs = [datetimeoffset]::MinValue
        [datetimeoffset]$failTs  = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$spawn.ts, [ref]$spawnTs) -and [datetimeoffset]::TryParse([string]$fail.ts, [ref]$failTs)) {
            $duration = $failTs - $spawnTs
            $condB = [Math]::Abs($duration.TotalMinutes - $TimeoutMinutes) -le 2
        }
    }

    # (c) The plan explicitly labels the failure as transient.
    $condC = $Content -match '(?im)^\*\*FailureType\*\*:\s*transient\b'

    # (d) Any legacy evidence line mentions timeout-related language.
    $condD = $false
    $evidenceRe = '(?im)^\*\*(Reviewed|Audit|QA|Implementation|ReviewSummary|AuditSummary|QASummary)\*\*:\s*(?<value>[^\r\n]+)'
    foreach ($m in [regex]::Matches($Content, $evidenceRe)) {
        $value = $m.Groups['value'].Value
        if ($value -match 'timeout|timed out|exceeded|deadline|transient|killed') {
            $condD = $true
            break
        }
    }

    return ($condA -and $condB) -or $condC -or $condD
}

function Add-PondBlockedNote {
    <#
    .SYNOPSIS
        Marks a plan as blocked and notes which feedback file it is waiting on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath,

        [Parameter(Mandatory)]
        [string]$BlockedBy,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$WaitingFor
    )

    $content = Get-Content -LiteralPath $PlanPath -Raw
    $headers = [ordered]@{
        Blocked       = 'true'
        BlockedBy     = $BlockedBy
        BlockedReason = $Reason
        WaitingFor    = $WaitingFor
        Status        = 'blocked'
    }

    foreach ($header in $headers.GetEnumerator()) {
        $pattern = "(?im)^\*\*$([regex]::Escape($header.Key))\*\*:\s*[^\r\n]+"
        $line = "**$($header.Key)**: $($header.Value)"
        if ($content -match $pattern) {
            $content = $content -replace $pattern, $line
        } else {
            $content = $content.TrimEnd() + "`n`n$line`n"
        }
    }

    $content | Set-Content -LiteralPath $PlanPath -Encoding utf8 -NoNewline
}

function New-PondFeedbackPlan {
    <#
    .SYNOPSIS
        Creates a new feedback plan in the Code queue for a failed plan.
    .DESCRIPTION
        The feedback plan carries the failure reason and becomes the active
        work item for the Coder. It is linked to the original plan through the
        **ParentPlan** and **PlanType** headers.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,

        [Parameter(Mandatory)]
        [PondContext]$Context,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$ActiveFile,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $codeDir = Join-Path $Context.TaskRoot 'Code'
    $null = New-Item -ItemType Directory -Path $codeDir -Force -ErrorAction SilentlyContinue

    $family = Get-PondFilePlanFamily -FileName $ActiveFile.Name
    $stem = $ActiveFile.BaseName -replace '-feedback\d*$', ''

    $maxSeq = 0
    foreach ($queue in @('Code','Review','Audit','QA','Working')) {
        $dir = Join-Path $Context.TaskRoot $queue
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $candidates = Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { (Get-PondFilePlanFamily -FileName $_.Name) -eq $family }
        foreach ($f in $candidates) {
            $seq = Get-PondFilePlanSequence -FileName $f.Name
            if ($seq -gt $maxSeq) { $maxSeq = $seq }
        }
    }

    # Prepend a date prefix only when the stem does not already start with one.
    if ($stem -notmatch '^\d{4}[-.]\d{2}[-.]\d{2}') {
        $stem = "$(Get-Date -Format 'yyyy.MM.dd')-$stem"
    }

    $feedbackBase = "$stem-feedback$($maxSeq + 1)"
    $feedbackName = "$feedbackBase.md"
    $feedbackPath = Join-Path $codeDir $feedbackName

    $header = switch ($Pond.Name) {
        'Review' { 'Reviewed' }
        'Audit'  { 'Audit' }
        'QA'     { 'QA' }
        'Code'   { 'Implementation' }
        default  { $Pond.Name }
    }

    $content = @(
        "# Feedback plan: $stem"
        ''
        '**Status**: ready'
        "**Scope**: Feedback for $stem"
        '**PlanType**: feedback'
        "**ParentPlan**: $($ActiveFile.Name)"
        "**FailedStage**: $($Pond.Name)"
        ''
        "**$header**: failed by $($Pond.Role) - $Reason"
        ''
        '**PondLog**'
        ''
        '```json'
        '[]'
        '```'
    ) -join "`n"

    $content | Set-Content -LiteralPath $feedbackPath -Encoding utf8 -NoNewline

    Add-PondReworkFeedback -PondName $Pond.Name -PlanPath $feedbackPath

    $null = Add-PlanPondLog -PlanPath $feedbackPath -Entry @{
        ts     = (Get-Date -Format 'o')
        pond   = $Pond.Name
        role   = $Pond.Role
        action = 'created'
        detail = "feedback for $($ActiveFile.Name)"
        agent  = 'PondEngine'
    } -ErrorAction Stop

    return (Get-Item -LiteralPath $feedbackPath)
}

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
            $verdict = Get-PondGateVerdict -Content $verdictContent -DecisionHeader $decisionContract.Decision -EvidenceHeader $decisionContract.Evidence
            if (-not $verdict.Found -or $verdict.Failed -or -not $verdict.Passed) { $Context.Success = $false; break }
        }
    }

    if ($Context.Success -and $Pond.Name -eq 'QA') {
        $projectGroups = $files | Group-Object {
            $qaContent = Get-Content -LiteralPath $_.FullName -Raw
            $projectMatch = [regex]::Match($qaContent, '(?im)^\*\*ProjectId\*\*:[ \t]*(?<value>[^\r\n]+)')
            if ($projectMatch.Success) { $projectMatch.Groups['value'].Value.Trim() } else { '' }
        }
        foreach ($projectGroup in $projectGroups) {
            if ([string]::IsNullOrWhiteSpace($projectGroup.Name)) { continue }
            $null = Write-PondProjectQaEvidence -TaskRoot $Context.TaskRoot -ProjectId $projectGroup.Name -PlanFiles @($projectGroup.Group)
        }
    }

    # Determine the active file in the lane (highest feedback sequence).
    $activeFile = Get-PondPlanActiveFile -Files $files
    $activeContent = if ($activeFile) { Get-Content -LiteralPath $activeFile.FullName -Raw } else { '' }

    # Materialize and validate the attempt-scoped result sidecar. The coordinator
    # owns this record and routing never consults stale results from another attempt.
    $gateResult = Get-PondValidatedGateResult -PlanPath $activeFile.FullName -Gate $Pond.Name -TaskRoot $Context.TaskRoot
    if (-not $gateResult) {
        $targetRepo = if ($group.RepoPath) { $group.RepoPath } else { $Context.RepoDir }
        $gateResult = Write-PondGateResult -PlanPath $activeFile.FullName -Gate $Pond.Name -TaskRoot $Context.TaskRoot -ProviderSucceeded $Context.Success -RepoDir $targetRepo
    }
    $Context.Success = ($gateResult.verdict -eq 'pass' -and $gateResult.failureKind -eq 'success')

    $timeoutMinutes = if ($Context.Config -and $null -ne $Context.Config.TimeoutMinutes) { $Context.Config.TimeoutMinutes } else { 30 }

    $finalDest = $null
    $newStatus = 'ready'
    $action = $null
    $retry = 0
    $feedbackFile = $null
    $reason = $null
    $attemptState = Register-PondAttemptOutcome -PlanPath $activeFile.FullName -Gate $Pond.Name -TaskRoot $Context.TaskRoot -Result $gateResult

    if (-not $Context.Success) {
        $reason = [string]$gateResult.evidenceSummary
        $reasonMatch = [regex]::Match($reason, '(?i)^failed by .+?\s+-\s+(?<reason>.+)$')
        if ($reasonMatch.Success) { $reason = $reasonMatch.Groups['reason'].Value.Trim() }
        switch ($attemptState.Directive) {
            'Decision' { $finalDest='Intake'; $newStatus='blocked'; $action='decision-required' }
            'Retry' { $finalDest=$Pond.Name; $newStatus='ready'; $action='retry'; $retry=$attemptState.TransportAttempts }
            'Rework' {
                $finalDest='Code'; $newStatus='ready'; $action='feedback'
                $feedbackFile=Write-PondFeedbackSidecar -PlanPath $activeFile.FullName -Gate $Pond.Name -TaskRoot $Context.TaskRoot -Reason $reason
            }
            'Investigate' { $finalDest='Investigate'; $newStatus='ready'; $action='investigate' }
            default { $finalDest='Paused'; $newStatus='engine-error'; $action='fail' }
        }
    } else {
        $finalDest = $Pond.OnSuccess.MoveTo
        $newStatus = if ($Pond.OnSuccess.MoveTo -eq 'Complete' -or $finalDest -eq 'Complete' -or $finalDest -like 'Complete/*') { 'complete' } else { 'ready' }
        $action = 'complete'
    }

    if ([string]::IsNullOrWhiteSpace($finalDest)) {
        Write-Verbose "Invoke-PondTaskTransition: no transition for pond '$($Pond.Name)'"
        return $Context
    }

    $destDir = Join-Path $Context.TaskRoot $finalDest
    $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue

    $sourcePaths = [System.Collections.Generic.List[string]]::new()
    $sourceQueuePath = Get-PondQueuePath -Pond $Pond -Context $Context
    foreach ($f in $files) {
        $sourcePaths.Add($f.FullName)
        # Claim is local/uncommitted; checkpoint deletion from the canonical source pond.
        $sourcePaths.Add((Join-Path $sourceQueuePath $f.Name))
    }

    if ($feedbackFile) {
        $sourcePaths.Add($feedbackFile.FullName)
    }

    $destFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($file in $files) {
        $dest = Join-Path $destDir $file.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
        $movedFile = Get-Item -LiteralPath $dest
        $destFiles.Add($movedFile)

        # Update the plan's status based on the outcome.
        $c = Get-Content -LiteralPath $dest -Raw
        $statusPattern = '(?im)^\*\*Status\*\*:\s*[^\r\n]+'
        if ($c -match $statusPattern) {
            $c = $c -replace $statusPattern, "**Status**: $newStatus"
        } else {
            $c = $c.TrimEnd() + "`n`n**Status**: $newStatus`n"
        }

        # Track retry count for transient failures.
        if ($action -eq 'retry' -or ($action -eq 'fail' -and $retry -gt 0)) {
            $c = $c -replace '(?im)^\*\*Retry\*\*:\s*\d+\r?\n?', ''
            $c = $c.TrimEnd() + "`n`n**Retry**: $retry`n"
        }

        $c | Set-Content -LiteralPath $dest -Encoding utf8 -NoNewline

        # Append a transition event to the canonical **PondLog** history.
        $detail = $null
        if ($Context.Success) {
            $detail = "moved from $($Pond.Name) to $finalDest"
        } else {
            switch ($action) {
                'decision-required' { $detail = "requires a decision; moved to $finalDest" }
                'retry'             { $detail = "retry $retry of $($Pond.OnFailure.MaxRetries) in $($Pond.Name)" }
                'fail'              { $detail = if ($retry -gt 0) { "exceeded max retries in $($Pond.Name); moved to $finalDest" } else { "failed in $($Pond.Name); moved to $finalDest" } }
                'feedback'          { $detail = if ($feedbackFile) { "blocked in $($Pond.Name); feedback linked at $($feedbackFile.Name)" } else { "blocked in $($Pond.Name)" } }
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

    # Include the new feedback plan in the set of files to be committed.
    if ($feedbackFile) {
        $destFiles.Add($feedbackFile)
    }

    # A successful final project review becomes one self-contained evidence
    # bundle. Include every old/new path so task-repo commits preserve moves.
    if ($Context.Success -and $Pond.Name -eq 'ProjectReview' -and $destFiles.Count -ge 1) {
        $parentDest = $destFiles[0].FullName
        $parentContent = Get-Content -LiteralPath $parentDest -Raw
        $projectIdMatch = [regex]::Match($parentContent, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
        $projectId = if ($projectIdMatch.Success) { $projectIdMatch.Groups['value'].Value.Trim() } else { $destFiles[0].BaseName }
        $children = @(Get-PondPlanDependencies -Content $parentContent)
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
        # The bundle renames and reorganizes files inside Complete/<projectId>.
        # Update destDir so the following safety check inspects the right location.
        $destDir = Join-Path $Context.TaskRoot $finalDest
    }

    # Defensive check: every plan file must now be in the destination queue and no
    # longer in the lane. Do not delete the lane if the move did not complete.
    # ProjectReview bundles rename the parent plan to project.md, so we accept
    # that as a valid destination for the original project file.
    $projectMd = if ($Pond.Name -eq 'ProjectReview') { Join-Path $destDir 'project.md' } else { '' }
    $missingDests = @($files | Where-Object {
        $fileName = if ($_.PSObject.Properties['Name']) { $_.Name } elseif ($_.PSObject.Properties['FullName']) { Split-Path -Leaf $_.FullName } else { [string]$_ }
        if ([string]::IsNullOrWhiteSpace($fileName)) { return $true }
        $expected = Join-Path $destDir $fileName
        if (Test-Path -LiteralPath $expected) { return $false }
        if ($projectMd -and (Test-Path -LiteralPath $projectMd)) { return $false }
        return $true
    })
    $stillInLane = @(Get-ChildItem -LiteralPath $lanePath -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($missingDests.Count -gt 0 -or $stillInLane.Count -gt 0) {
        $missingNames = @($missingDests | ForEach-Object { if ($_.PSObject.Properties['Name']) { $_.Name } else { [string]$_ } })
        $stillNames = @($stillInLane | ForEach-Object { if ($_.PSObject.Properties['Name']) { $_.Name } else { [string]$_ } })
        throw "Pond transition did not fully persist plan files; missing in $finalDest = $($missingNames -join ', '), still in lane = $($stillNames -join ', ')"
    }

    # The lane is an ephemeral lease envelope. Semantic results are already durable.
    Remove-Item -LiteralPath $lanePath -Recurse -Force -ErrorAction SilentlyContinue

    # An Investigator plan completing or failing clears the pending flag so the
    # next even counter value can spawn a fresh investigation if needed.
    if ($Pond.Name -eq 'Investigate') {
        Clear-PondInvestigatorPending -TaskRoot $Context.TaskRoot
    }

    # Commit and push the .salmon task repo and the target code repo for every transition.
    $firstName = $files[0].Name
    $commitMsg = "move: $firstName from $($Pond.Name) to $finalDest"
    Push-PondRepos -Pond $Pond -Context $Context -FinalDest $finalDest -SourcePaths $sourcePaths -DestFiles $destFiles -CommitMessage $commitMsg

    Write-Verbose "Invoke-PondTaskTransition: moved $($files.Count) plan(s) from '$($Pond.Name)' to '$finalDest' (success=$($Context.Success))"
    return $Context
}

