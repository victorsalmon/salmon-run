function Test-PlanDependencySatisfied {
    <#
    .SYNOPSIS
        Checks whether a named dependency has reached a downstream completed pond.
    .DESCRIPTION
        A dependency is satisfied when a plan with a matching name or namespace
        exists in one of the canonical completion ponds: Complete, Archive, or
        ProjectReview. The match is by filename (with or without .md) or by
        leading namespace prefix.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Dependency,

        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $dep = $Dependency.Trim()
    if ([string]::IsNullOrWhiteSpace($dep)) { return $true }

    $depFile = if ($dep -notlike '*.md') { "$dep.md" } else { $dep }
    $depNs = $dep -replace '\.md$',''

    $completionPonds = @('Tasks/Complete', 'Tasks/Archive', 'Tasks/ProjectReview')
    foreach ($pondRel in $completionPonds) {
        $pondDir = if ($pondRel -match '^Tasks[/\\](.+)$') { Join-Path $Context.TaskRoot $Matches[1] } else { Join-Path $Context.TaskRoot $pondRel }
        if (-not (Test-Path -LiteralPath $pondDir)) { continue }

        $files = Get-ChildItem -Path "$pondDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }
        foreach ($file in $files) {
            if ($file.Name -eq $depFile) { return $true }
            $nameNoExt = $file.BaseName
            if ($nameNoExt -like "$depNs*") { return $true }
            if ($depNs -like "$nameNoExt*") { return $true }
        }
    }

    return $false
}
