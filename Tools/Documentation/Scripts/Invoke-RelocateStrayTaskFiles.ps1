<#
.SYNOPSIS
    Relocate any .md task files that were written to the wrong repo's Tasks/Code or Tasks/Review back to salmon-orchestrator.

.DESCRIPTION
    The task queue is centralized in salmon-orchestrator. Other repos should never contain Tasks/Code/*.md or Tasks/Review/*.md files. This guard scans C:\Repos\*\Tasks\Code and C:\Repos\*\Tasks\Review for stray .md files and moves them into the corresponding salmon-orchestrator directory, prefixing the filename with the source repo name if it is not already prefixed.
#>
param(
    [string]$OrchestratorRoot = 'C:/Repos/salmon-orchestrator'
)

$ErrorActionPreference = 'Stop'

$sourceDirs = @('Tasks\Code', 'Tasks\Review')
$repoRoots = Get-ChildItem 'C:\Repos' -Directory |
    Where-Object { $_.Name -ne 'salmon-orchestrator' -and (Test-Path (Join-Path $_.FullName '.git') -PathType Container) }

$moved = @()

foreach ($repo in $repoRoots) {
    foreach ($dir in $sourceDirs) {
        $srcDir = Join-Path $repo.FullName $dir
        if (-not (Test-Path $srcDir -PathType Container)) { continue }
        $mdFiles = Get-ChildItem $srcDir -Filter '*.md' -File -ErrorAction SilentlyContinue
        if (-not $mdFiles) { continue }
        $prefix = $repo.Name
        foreach ($file in $mdFiles) {
            $baseName = $file.Name
            if ($baseName -notlike "$prefix-*") {
                $baseName = "$prefix-$baseName"
            }
            $destDir = Join-Path $OrchestratorRoot $dir
            $null = New-Item -ItemType Directory -Path $destDir -Force
            $destPath = Join-Path $destDir $baseName
            $counter = 1
            while (Test-Path $destPath) {
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($baseName)
                $ext = [System.IO.Path]::GetExtension($baseName)
                $baseName = "$stem-$counter$ext"
                $destPath = Join-Path $destDir $baseName
                $counter++
            }
            Move-Item -Path $file.FullName -Destination $destPath
            $moved += $destPath
        }
    }
}

if ($moved) {
    Write-Host "Relocated $($moved.Count) stray task file(s):"
    $moved | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "No stray task files found."
}

return $moved
