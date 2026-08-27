<#
.DEPRECATED
    Superseded by Write-NamespaceLog (SalmonRun.WorkflowEvents).
    This function wrote to docs/Memory/ files which is no longer
    the canonical pattern. Use Write-NamespaceLog -Namespace <domain> instead
    to append to Tasks/Logs/<namespace>.log.

    Resolve-MemoryRepo is kept for backward compatibility with _project-map.json
    path resolution. New code should resolve repo paths directly.
#>

function New-MemoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MemoryFilePath,
        [Parameter(Mandatory = $true)]
        [string]$Container,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$Section,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Entries,
        [Parameter(Mandatory = $false)]
        [ValidateSet('append', 'update')]
        [string]$Mode = 'append',
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    $filename = Split-Path -Leaf $MemoryFilePath
    if ($filename -notmatch '^mem-(.+)-(.+)\.md$') {
        throw "Filename must match mem-<container>-<project>.md pattern, got: $filename"
    }
    $fileContainer = $Matches[1]
    $fileProject = $Matches[2]
    if ($Container -ne $fileContainer) { throw "Container '$Container' does not match filename container '$fileContainer'" }
    if ($Project -ne $fileProject) { throw "Project '$Project' does not match filename project '$fileProject'" }

    $newLines = @()
    foreach ($entry in $Entries) {
        $newLines += "- **$($entry.Key)**: $($entry.Value)"
    }

    if ($Mode -eq 'update' -and -not (Test-Path $MemoryFilePath)) {
        throw "File $MemoryFilePath does not exist — cannot update"
    }

    if ($Mode -eq 'append' -and -not (Test-Path $MemoryFilePath)) {
        $content = @()
        $content += "# Memory: $Container / $Project"
        $content += ""
        $content += "## $Section"
        $content += ""
        $content += $newLines -join "`n"
        $content += ""
        $output = $content -join "`n"
        if ($DryRun) { Write-Host "[DRY RUN] Would create file with:$([Environment]::NewLine)$output" }
        else { Set-Content -LiteralPath $MemoryFilePath -Value $output -NoNewline }
        return
    }

    $existing = Get-Content -LiteralPath $MemoryFilePath -Raw
    $sectionPattern = "^## $([regex]::Escape($Section))$"

    if ($existing -match "(?ms)(^## $([regex]::Escape($Section))`r?`n)(.*?)(`r?`n## |`r?`n\z)") {
        $before = $Matches[1]
        $body = $Matches[2]
        if ($Mode -eq 'append') {
            $newBody = "$body`n$($newLines -join "`n")"
        } else {
            foreach ($entry in $Entries) {
                $keyPattern = "- \*\*$([regex]::Escape($entry.Key))\*\*:"
                if ($body -match "(?m)^- \*\*$([regex]::Escape($entry.Key))\*\*:.*$") {
                    $body = $body -replace "(?m)^- \*\*$([regex]::Escape($entry.Key))\*\*:.*$", "- **$($entry.Key)**: $($entry.Value)"
                } else {
                    $body = "$body`n- **$($entry.Key)**: $($entry.Value)"
                }
            }
            $newBody = $body
        }
        $existing = $existing -replace "(?ms)(^## $([regex]::Escape($Section))`r?`n)(.*?)(`r?`n## |`r?`n\z)", "`${1}$newBody`$3"
    } elseif ($Mode -eq 'append') {
        $existing = $existing.TrimEnd() + "`n`n## $Section`n`n$($newLines -join "`n")`n"
    } else {
        throw "Section '$Section' not found in $MemoryFilePath — cannot update"
    }

    if ($DryRun) { Write-Host "[DRY RUN] Would write:$([Environment]::NewLine)$existing" }
    else { Set-Content -LiteralPath $MemoryFilePath -Value $existing -NoNewline }
}

function Resolve-MemoryRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName,
        [Parameter(Mandatory = $false)]
        [string]$Filename
    )
    $mapPath = "$env:USERPROFILE\intersite-orchestrator\Documentation\Memory\_project-map.json"
    if (-not (Test-Path $mapPath)) {
        throw "Project map not found at $mapPath"
    }
    $map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
    $repo = $map.repos | Where-Object { $_.name -eq $RepoName }
    if (-not $repo) {
        throw "Repo '$RepoName' not found in _project-map.json"
    }
    $basePath = $repo.path -replace '^~', $env:USERPROFILE
    $memoryDir = Join-Path -Path $basePath -ChildPath $repo.memory_rel
    if ($Filename) {
        return Join-Path -Path $memoryDir -ChildPath $Filename
    }
    return $memoryDir
}
