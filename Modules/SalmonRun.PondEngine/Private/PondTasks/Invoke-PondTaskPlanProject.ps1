function Invoke-PondTaskPlanProject {
    <#
    .SYNOPSIS
        Decomposes a Project plan into child Code plans and a ProjectReview plan.
    .DESCRIPTION
        Reads the project plan from the current lane, parses its **Children**
        header (comma-separated list or markdown bullets), and creates child
        plans under Tasks/Code. It then updates the parent plan with a
        **DependsOn** header listing the child stems so the ProjectReview pond
        can gate on their completion.
    #>
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

    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { $Context.Success = $false; return $Context }

    $codeDir = Join-Path $Context.TaskRoot 'Code'
    $null = New-Item -ItemType Directory -Path $codeDir -Force -ErrorAction SilentlyContinue

    $allChildStems = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        # Determine child task names from the **Children** header.
        $children = @()
        if ($content -match '(?im)^\*\*Children\*\*:\s*(?<value>[^\r\n]+)') {
            $children = @($Matches['value'].Trim() -split ',\s*' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if (@($children).Count -eq 0) {
            # If the project has no explicit children, assume a single child.
            $children = @('child')
        }

        $parentBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $parentNs = Get-PondFileNamespace -FileName $file.Name
        $datePrefix = if ($file.Name -match '^(\d{4}[-. ]?\d{2}[-. ]?\d{2})') { $Matches[1] -replace '[. ]','-' } else { (Get-Date -Format 'yyyy-MM-dd') }

        $childIndex = 0
        foreach ($child in $children) {
            $childIndex++
            $childStem = "$parentBase-$child-$childIndex"
            $childPath = Join-Path $codeDir "$childStem.md"

            $childContent = @"
# Child Plan: $child
**Status**: ready
**Scope**: $parentNs
**Challenge**: Local
**ProjectId**: $parentNs
"@

            $childContent | Set-Content -LiteralPath $childPath -Encoding utf8 -NoNewline
            $allChildStems.Add($childStem)
        }

        # Update the parent plan with a DependsOn list so ProjectReview can gate.
        $dependsOn = ($allChildStems | Select-Object -Unique) -join ', '
        if ($content -match '(?im)^\*\*DependsOn\*\*:\s*[^\r\n]+') {
            $content = $content -replace '(?im)^\*\*DependsOn\*\*:\s*[^\r\n]+', "**DependsOn**: $dependsOn"
        } else {
            $content = $content + "`n`n**DependsOn**: $dependsOn`n"
        }

        if ($content -match '(?im)^\*\*Status\*\*:\s*[^\r\n]+') {
            $content = $content -replace '(?im)^\*\*Status\*\*:\s*[^\r\n]+', "**Status**: ready"
        } else {
            $content = $content + "`n**Status**: ready`n"
        }

        $content | Set-Content -LiteralPath $file.FullName -Encoding utf8 -NoNewline
    }

    $Context.Success = $true
    Write-Verbose "Invoke-PondTaskPlanProject: created $($allChildStems.Count) child plan(s) for '$($group.Namespace)'"
    return $Context
}
