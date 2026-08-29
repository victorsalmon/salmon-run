function Get-PondProjectState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)][string]$ProjectId
    )

    $parent = $null
    foreach ($queue in 'ProjectReview','Project','Working') {
        $dir = Join-Path $TaskRoot $queue
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $parent = Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $c = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
                $m = [regex]::Match($c, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
                $m.Success -and $m.Groups['value'].Value.Trim() -eq $ProjectId
            } | Select-Object -First 1
        if ($parent) { break }
    }

    $children = @()
    if ($parent) {
        $content = Get-Content -LiteralPath $parent.FullName -Raw
        $children = @(Get-PondPlanDependencies -Content $content)
    }

    $locations = [ordered]@{}
    foreach ($child in $children) {
        $locations[$child] = $null
        foreach ($queue in 'Code','Review','Audit','QA','Complete','Working','Failed','Paused') {
            $dir = Join-Path $TaskRoot $queue
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $found = Get-ChildItem -LiteralPath $dir -Filter "$child.md" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $locations[$child] = $queue; break }
        }
    }

    [pscustomobject]@{
        ProjectId = $ProjectId
        Parent = $parent
        Children = $children
        Locations = $locations
        AllInQA = ($children.Count -gt 0 -and @($children | Where-Object { $locations[$_] -ne 'QA' }).Count -eq 0)
        AllComplete = ($children.Count -gt 0 -and @($children | Where-Object { $locations[$_] -ne 'Complete' }).Count -eq 0)
    }
}

function Write-PondProjectQaEvidence {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][System.IO.FileInfo[]]$PlanFiles
    )

    $qaDir = Join-Path $TaskRoot 'QA'
    $null = New-Item -ItemType Directory -Path $qaDir -Force
    $path = Join-Path $qaDir "$ProjectId-qa.json"
    [ordered]@{
        projectId = $ProjectId
        passed = $true
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        planCount = $PlanFiles.Count
        plans = @($PlanFiles | ForEach-Object Name)
        evidence = 'QA agent passed the aggregate project batch; see child plan QA and PondLog evidence.'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline
    return $path
}

function Complete-PondProjectBundle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)][string]$ProjectPlanPath
    )

    if (-not (Test-Path -LiteralPath $ProjectPlanPath)) { throw "Project plan not found: $ProjectPlanPath" }
    $content = Get-Content -LiteralPath $ProjectPlanPath -Raw
    $idMatch = [regex]::Match($content, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
    $projectId = if ($idMatch.Success) { $idMatch.Groups['value'].Value.Trim() } else { [IO.Path]::GetFileNameWithoutExtension($ProjectPlanPath) }
    $projectId = ($projectId -replace '[^a-zA-Z0-9_.-]+','-').Trim('-')

    $bundle = Join-Path $TaskRoot "Complete/$projectId"
    $plansDir = Join-Path $bundle 'plans'
    $feedbackDir = Join-Path $bundle 'feedback'
    $qaDir = Join-Path $bundle 'qa'
    foreach ($dir in $bundle,$plansDir,$feedbackDir,$qaDir) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $children = @(Get-PondPlanDependencies -Content $content)

    foreach ($child in $children) {
        $source = Join-Path $TaskRoot "Complete/$child.md"
        if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination (Join-Path $plansDir "$child.md") -Force }
    }

    $sourceFeedback = Join-Path $TaskRoot 'Feedback'
    if (Test-Path -LiteralPath $sourceFeedback) {
        foreach ($feedback in Get-ChildItem -LiteralPath $sourceFeedback -File -ErrorAction SilentlyContinue) {
            if ($children | Where-Object { $feedback.BaseName -like "$_-*" }) {
                Move-Item -LiteralPath $feedback.FullName -Destination (Join-Path $feedbackDir $feedback.Name) -Force
            }
        }
    }

    $qaEvidence = Join-Path $TaskRoot "QA/$projectId-qa.json"
    if (Test-Path -LiteralPath $qaEvidence) { Move-Item -LiteralPath $qaEvidence -Destination (Join-Path $qaDir "$projectId-qa.json") -Force }

    $projectDest = Join-Path $bundle 'project.md'
    Move-Item -LiteralPath $ProjectPlanPath -Destination $projectDest -Force
    $finalContent = Get-Content -LiteralPath $projectDest -Raw
    $reviewPassed = $finalContent -match '(?im)^\*\*(ProjectReviewDecision|ProjectReview)\*\*:\s*(pass(?:ed)?|completed)\b'
    [ordered]@{
        projectId = $projectId
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        milestones = [ordered]@{
            plannedChildren = $children.Count
            codeComplete = $children.Count
            reviewPassed = $children.Count
            qaPassed = (Test-Path -LiteralPath (Join-Path $qaDir "$projectId-qa.json"))
            projectReviewPassed = $reviewPassed
        }
        files = [ordered]@{
            project = 'project.md'
            plans = @($children | ForEach-Object { "plans/$_.md" })
            feedback = @(Get-ChildItem -LiteralPath $feedbackDir -File -ErrorAction SilentlyContinue | ForEach-Object { "feedback/$($_.Name)" })
            qa = @(Get-ChildItem -LiteralPath $qaDir -File -ErrorAction SilentlyContinue | ForEach-Object { "qa/$($_.Name)" })
        }
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Encoding utf8 -NoNewline
    return $bundle
}
