<#
.SYNOPSIS
    Pre-scans Tasks/Code/ for plan files and outputs connascence groups.
.DESCRIPTION
    Reads every plan file in Tasks/Code/, extracts namespace from the filename
    and the optional ConnascenceScope field from the header, then builds
    a conflict graph based on file-target overlap (the Files: field).

    Additionally parses DependsOn fields, builds a dependency DAG, detects
    cycles, and computes the ready set (sessions whose deps are all resolved).

    Outputs a JSON object with:
    - groups: connascence groups (same as before)
    - depGraph: per-file dependency info
    - cycleDetected: true/false
    - cyclePath: list of files in the cycle (if any)
    - readySet: files whose dependencies are all resolved
    - blockedSet: files with at least one unresolved dependency

    Visualization modes:
    - AsDag: Mermaid flowchart of the dependency DAG
    - AsTable: Markdown table of dep status per session

.PARAMETER TaskDir
    Directory to scan for plan files. Defaults to Tasks/Code/ under repo root.
.PARAMETER RepoRoot
    Root of the repository. Defaults to script parent's parent.
.PARAMETER PassThru
    Write output to stdout as JSON instead of returning objects.
.PARAMETER AsDag
    Output a Mermaid flowchart of the dependency DAG to stdout.
.PARAMETER AsTable
    Output a markdown dep-status table to stdout.
.PARAMETER OutputDir
    If specified, write outputs to files instead of stdout:
    - Mermaid: <OutputDir>/plan-dag.md
    - Table: <OutputDir>/plan-deps.md
    - JSON: <OutputDir>/connascence-groups.json
.PARAMETER ModuleCount
    Number of worktree modules in use. When greater than 0, unassigned plans are
    auto-distributed across main + module-1..module-N for balanced dispatch.
.EXAMPLE
    .\Skills\\Orchestration\Get-ConnascenceGroups.ps1 -PassThru | ConvertFrom-Json
.EXAMPLE
    $groups = .\Skills\\Orchestration\Get-ConnascenceGroups.ps1
    $groups.Count
.EXAMPLE
    .\Skills\\Orchestration\Get-ConnascenceGroups.ps1 -AsDag
.EXAMPLE
    .\Skills\\Orchestration\Get-ConnascenceGroups.ps1 -AsTable
.EXAMPLE
    .\Skills\\Orchestration\Get-ConnascenceGroups.ps1 -AsDag -AsTable -OutputDir "Tasks/Logs/"
.EXAMPLE
    .\Skills\\Orchestration\Get-ConnascenceGroups.ps1
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot/../.."),
    [string]$TaskDir = (Join-Path $RepoRoot "Tasks/Code"),
    [switch]$PassThru,
    [switch]$AsDag,
    [switch]$AsTable,
    [string]$OutputDir = "",
    [int]$ModuleCount = 0,
    [string]$IncrementalCompletedNamespace = ""
)

$ErrorActionPreference = "Stop"

# ── Cache support ─────────────────────────────────────────────────────────

$cacheDir = Join-Path $RepoRoot "Tasks" "Logs" ".connascence-cache"
$null = New-Item -ItemType Directory -Path $cacheDir -Force
$cacheFile = Join-Path $cacheDir "cache.json"
$codeFiles = Get-ChildItem "$TaskDir/*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' }
$codeHashes = $codeFiles | ForEach-Object {
    $__hash = Get-FileHash $_.FullName -Algorithm SHA256
    "$($_.Name):$($__hash.Hash)"
}
$completeFiles = Get-ChildItem "$RepoRoot/Tasks/Complete/*.md" -Recurse -ErrorAction SilentlyContinue
$completeHashes = $completeFiles | ForEach-Object {
    $__hash = Get-FileHash $_.FullName -Algorithm SHA256
    "$($_.Name):$($__hash.Hash)"
}
$gitHead = git rev-parse HEAD 2>$null
# Parser self-hash: a change to this script's own content (e.g. a parser fix) must
# invalidate the cache, or stale results computed by the old parser keep being served.
$scriptHash = if ($PSCommandPath) { (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash } else { 'dot-sourced' }
$cacheSignature = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
    (@($codeHashes; $completeHashes; $gitHead; $ModuleCount; $scriptHash) -join '|')
))

$cacheHit = $false
$cachedResult = $null
if ([string]::IsNullOrEmpty($IncrementalCompletedNamespace) -and (Test-Path $cacheFile)) {
    $cached = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($cached -and $cached.signature -eq $cacheSignature) {
        $cacheHit = $true
        $cachedResult = $cached.result
    }
}

function Get-FileNamespace {
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -creplace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}[-.]\d{2}[-.]\d{2}-?', ''

    if ($base -match '^(.+?)-\d+') {
        return $matches[1]
    }

    if ($base -match '-') {
        $base = $base -replace '\d+$', ''
        if ([string]::IsNullOrWhiteSpace($base)) { return '' }
        return ($base -replace '^-|-$', '')
    }

    return ''
}

function Get-HeaderField {
    param([string]$Content, [string]$FieldName)
    $m = [regex]::Match($Content, "(?m)^\*\*$FieldName\*\*:\s*(.+?)\s*$")
    if ($m.Success) {
        return $m.Groups[1].Value.Trim()
    }
    return $null
}

function Get-FilesField {
    param([string]$Content)

    function Strip-Markdown($s) {
        $s = $s.Trim()
        # Strip inline code backticks and fenced code markers
        $s = $s -replace '^```\s*','' -replace '\s*```$',''
        $s = $s -replace '^`+','' -replace '`+$',''
        return $s.Trim()
    }

    $inlineMatch = [regex]::Match($Content, '(?m)^\*\*Files\*\*:[ \t]*([^\r\n]+?)[ \t]*\r?$')
    if ($inlineMatch.Success) {
        $inline = $inlineMatch.Groups[1].Value.Trim()
        if ($inline -match '[/.]' -or $inline -eq 'None' -or $inline -eq 'none') {
            return ($inline -split ',' | ForEach-Object { Strip-Markdown $_ }) | Where-Object { $_ -and $_ -ne 'None' -and $_ -ne 'none' }
        }
    }
    $lines = $Content -split "`r?`n"
    $inFiles = $false
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\*\*Files\*\*:') {
            $inFiles = $true
            continue
        }
        if ($inFiles) {
            if ($line -match '^\*\*' -or $line -match '^##\s') { break }
            $bulletMatch = [regex]::Match($line, '^\s*-\s+(.+?)(?:\s+\([^)]+\))?\s*$')
            if ($bulletMatch.Success) {
                $path = Strip-Markdown $bulletMatch.Groups[1].Value
                if ($path -and $path -ne 'None' -and $path -ne 'none') {
                    $result.Add($path)
                }
            }
            if ([string]::IsNullOrWhiteSpace($line) -and $result.Count -gt 0) {
                break
            }
        }
    }
    return @($result)
}

function Get-DependsOn {
    param([string]$Content)
    $result = [System.Collections.Generic.List[hashtable]]::new()
    # Collect the **DependsOn**: header line plus indented continuation lines so both the
    # canonical one-entry-per-line format and the backward-compatible comma-separated
    # single-line format parse uniformly. A blank line or non-indented line ends the field.
    # (See Skills/Workflows/Shared/session-plan-format.md — "One per line".) Previously a
    # single (?m)...(.+)$ regex captured only the first physical line, so multi-line plans
    # parsed as a single dep and dep-gated plans kept being re-dispatched.
    $lines = $Content -split "`r?`n"
    $inDeps = $false
    $collected = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if (-not $inDeps) {
            if ($line -match '^\*\*Depends\s?[Oo]n\*\*:\s*(.*)$') {
                $inDeps = $true
                $collected.Add($matches[1])
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            if ($line -match '^\S') { break }
            $collected.Add($line.Trim())
        }
    }
    # Each collected line is split on commas so a comma-separated header line and
    # one-per-line continuation lines are handled by the same path. Only fragments
    # matching `ref (status: gate)` become dep entries; others are ignored.
    foreach ($fragment in $collected) {
        $entries = $fragment -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($entry in $entries) {
            $entryMatch = [regex]::Match($entry, '^(.+?)\s+\(status:\s+(\w+)\)$')
            if ($entryMatch.Success) {
                $result.Add(@{ Ref = $entryMatch.Groups[1].Value.Trim(); Status = $entryMatch.Groups[2].Value })
            }
        }
    }
    return ,@($result)
}

function Get-GitRepoRootForPath {
    param([Parameter(Mandatory)][string]$FilePath)
    $dir = Split-Path -Path $FilePath -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    while ($dir) {
        try {
            if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
        } catch {
            Write-Warning "Get-GitRepoRootForPath: invalid path '$dir' derived from '$FilePath'"
            return $null
        }
        $parent = Split-Path -Path $dir -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Resolve-CompleteDep {
    <#
    .SYNOPSIS
        Resolves a `status: complete` dependency by checking the dep plan's
        **Files:** target files' git history in the target repo.
    .DESCRIPTION
        A dep whose plan file sits in Tasks/Complete/ has been reviewed and is
        resolved. Otherwise the dep plan (in Tasks/Review/ or Tasks/Code/) is
        located by ref, its **Files:** field parsed, and each target file's git
        history is checked in its own repository. A plan whose described work
        is not committed (no git history on any target file) is NOT resolved.
    #>
    param(
        [Parameter(Mandatory)][string]$DepRef,
        [string]$RepoRoot,
        [string]$TaskDir
    )
    $completeRoot = Join-Path $RepoRoot "Tasks/Complete"
    $reviewRoot = Join-Path $RepoRoot "Tasks/Review"

    $completeHits = @(Get-ChildItem -Path $completeRoot -Recurse -Filter "*$DepRef*.md" -ErrorAction SilentlyContinue)
    if ($completeHits.Count -gt 0) {
        Write-Host "DEP_RESOLVE dep='$DepRef' status='complete' resolved=true method='complete_dir'"
        return $true
    }

    $reviewHits = @(Get-ChildItem -Path $reviewRoot -Recurse -Filter "*$DepRef*.md" -ErrorAction SilentlyContinue)
    $codeHits = @(Get-ChildItem -Path $TaskDir -Filter "*$DepRef*.md" -ErrorAction SilentlyContinue)
    $depPlan = @($completeHits + $reviewHits + $codeHits) | Select-Object -First 1
    if (-not $depPlan) {
        Write-Warning "CONNASCENCE_BLOCK dep='$DepRef' reason='dep_plan_not_found'"
        return $false
    }

    $content = Get-Content -Path $depPlan.FullName -Raw -ErrorAction SilentlyContinue
    $targetFiles = @(Get-FilesField -Content $content)
    if (-not $targetFiles -or $targetFiles.Count -eq 0) {
        Write-Warning "CONNASCENCE_BLOCK dep='$DepRef' reason='no_files_field_or_repo_unreachable'"
        return $false
    }

    $checkedAny = $false
    foreach ($tf in $targetFiles) {
        if ([string]::IsNullOrWhiteSpace($tf)) { continue }
        $fileRepoRoot = Get-GitRepoRootForPath -FilePath $tf
        if (-not $fileRepoRoot) { continue }
        $checkedAny = $true
        $rel = $tf.Substring($fileRepoRoot.Length).TrimStart('\', '/')
        $log = git -C $fileRepoRoot log --oneline -1 -- $rel 2>$null
        if ($log) {
            Write-Host "DEP_RESOLVE dep='$DepRef' status='complete' resolved=true method='target_files_git' file='$rel'"
            return $true
        }
    }

    if (-not $checkedAny) {
        Write-Warning "CONNASCENCE_BLOCK dep='$DepRef' reason='no_files_field_or_repo_unreachable'"
    }
    Write-Host "DEP_RESOLVE dep='$DepRef' status='complete' resolved=false method='target_files_git'"
    return $false
}

function Test-DependsOnCycle {
    param($DepGraph)
    $gray = 1; $black = 2
    $color = @{}
    $script:CyclePath = @()
    $script:HasCycle = $false

    function Get-MatchingKey {
        param([string]$Ref, [hashtable]$Graph)
        return @($Graph.Keys | Where-Object { $_ -like "*$Ref*" } | Select-Object -First 1)
    }

    function DFS($node) {
        $color[$node] = $gray
        $script:CyclePath += $node
        if ($depGraph.Contains($node) -and $DepGraph[$node].Deps -and $DepGraph[$node].Deps.Count -gt 0) {
            foreach ($dep in $DepGraph[$node].Deps) {
                $matchingKey = Get-MatchingKey -Ref $dep.Ref -Graph $DepGraph
                if (-not $matchingKey) { continue }
                if (-not $color.ContainsKey($matchingKey)) {
                    DFS $matchingKey
                    if ($script:HasCycle) { return }
                } elseif ($color[$matchingKey] -eq $gray) {
                    $script:HasCycle = $true
                    $script:CyclePath += $matchingKey
                    return
                }
            }
        }
        if (-not $script:HasCycle) { $script:CyclePath = $script:CyclePath[0..[math]::Max(0, $script:CyclePath.Length - 2)] }
        $color[$node] = $black
    }

    foreach ($node in $DepGraph.Keys) {
        if (-not $color.ContainsKey($node)) {
            DFS $node
            if ($script:HasCycle) { break }
        }
    }

    return @{ HasCycle = $script:HasCycle; CyclePath = $script:CyclePath }
}

function Get-ReadySet {
    param([hashtable]$DepGraph, [string]$CompletedDir = "Tasks/Complete")
    $ready = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[string]]::new()
    $dangling = [System.Collections.Generic.List[object]]::new()

    $completedFiles = Get-ChildItem -Path $CompletedDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
    $liveFiles = @(Get-ChildItem -Path "Tasks/Code" -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    $liveFiles += Get-ChildItem -Path "Tasks/Review" -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
    $liveFiles = $liveFiles | Select-Object -Unique

    foreach ($node in $DepGraph.Keys) {
        $deps = $DepGraph[$node].Deps
        if (-not $deps -or $deps.Count -eq 0) {
            $ready.Add($node)
        } else {
            $allResolved = $true
            foreach ($dep in $deps) {
                $depMatched = $false
                if ($dep.Status -eq "reviewed") {
                    $depMatched = $null -ne ($completedFiles | Where-Object { $_ -like "*$($dep.Ref)*" })
                } elseif ($dep.Status -eq "complete") {
                    $depMatched = Resolve-CompleteDep -DepRef $dep.Ref -RepoRoot $RepoRoot -TaskDir $TaskDir
                } elseif ($dep.Status -eq "ready") {
                    # 'ready' gate: dep exists in Tasks/Code/ with Status: ready but not yet implemented.
                    # Dependent stays blocked (not dangling) until the dep moves to Complete/.
                    $depMatched = $null -ne ($liveFiles | Where-Object { $_ -like "*$($dep.Ref)*" })
                }
                if (-not $depMatched) {
                    $liveMatch = $liveFiles | Where-Object { $_ -like "*$($dep.Ref)*" }
                    $completeMatch = $completedFiles | Where-Object { $_ -like "*$($dep.Ref)*" }
                    if (-not $liveMatch -and -not $completeMatch) {
                        $dangling.Add([PSCustomObject]@{ Plan = $node; Ref = $dep.Ref; Status = $dep.Status })
                    }
                    $allResolved = $false
                    break
                }
            }
            if ($allResolved) { $ready.Add($node) } else { $blocked.Add($node) }
        }
    }

    return @{ ReadySet = @($ready); BlockedSet = @($blocked); DanglingDeps = @($dangling) }
}

function Format-DepGraphAsMermaid {
    param($DepGraph)
    $depDir = Join-Path $RepoRoot "Tasks/Complete"
    $completedFiles = @(Get-ChildItem -Path $depDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    $liveTaskDir = "Tasks/Code"
    $reviewDir = "Tasks/Review"
    $liveFiles = @(Get-ChildItem -Path $liveTaskDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    $liveFiles += Get-ChildItem -Path $reviewDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
    $liveFiles = $liveFiles | Select-Object -Unique

    $nodeStatus = @{}
    foreach ($node in $DepGraph.Keys) {
        $nodeStatus[$node] = "ready"
        if ($completedFiles | Where-Object { $_ -eq $node }) {
            $nodeStatus[$node] = "complete"
        }
        $deps = $DepGraph[$node].Deps
        if ($deps -and $deps.Count -gt 0) {
            $allResolved = $true
            foreach ($dep in $deps) {
                $depMatched = $false
                if ($dep.Status -eq "reviewed") {
                    $depMatched = $null -ne ($completedFiles | Where-Object { $_ -like "*$($dep.Ref)*" })
                } elseif ($dep.Status -eq "complete") {
                    $depMatched = Resolve-CompleteDep -DepRef $dep.Ref -RepoRoot $RepoRoot -TaskDir $TaskDir
                }
                if (-not $depMatched) { $allResolved = $false; break }
            }
            if (-not $allResolved) { $nodeStatus[$node] = "blocked" }
        } else {
            if ($nodeStatus[$node] -ne "complete") { $nodeStatus[$node] = "root" }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("graph TD")

    foreach ($node in $DepGraph.Keys) {
        $deps = $DepGraph[$node].Deps
        if ($deps -and $deps.Count -gt 0) {
            $nodeClean = $node -replace '\.md$', ''
            $nodeClean = $nodeClean -replace '[^a-zA-Z0-9_-]', '_'
            foreach ($dep in $deps) {
                $depKey = @($DepGraph.Keys | Where-Object { $_ -like "*$($dep.Ref)*" } | Select-Object -First 1)
                if ($depKey) {
                    $depClean = $depKey -replace '\.md$', ''
                    $depClean = $depClean -replace '[^a-zA-Z0-9_-]', '_'
                    $lines.Add("    ${nodeClean}[$($node -replace '\.md$', '')] --> ${depClean}[$($depKey -replace '\.md$', '')]")
                }
            }
        }
    }

    $addedClasses = @{}
    foreach ($node in $DepGraph.Keys) {
        $status = $nodeStatus[$node]
        $nodeClean = $node -replace '\.md$', ''
        $nodeClean = $nodeClean -replace '[^a-zA-Z0-9_-]', '_'
        if (-not $addedClasses.ContainsKey($status)) {
            $color = switch ($status) {
                "root" { "fill:#4CAF50,color:#fff" }
                "ready" { "fill:#2196F3,color:#fff" }
                "blocked" { "fill:#FF9800,color:#fff" }
                "complete" { "fill:#9E9E9E,color:#fff" }
            }
            $lines.Add("    classDef $status $color")
            $addedClasses[$status] = $true
        }
        $lines.Add("    class $nodeClean $status")
    }

    return $lines -join "`n"
}

function Format-DepStatusTable {
    param($DepGraph, $FileModules)
    $depDir = Join-Path $RepoRoot "Tasks/Complete"
    $completedFiles = @(Get-ChildItem -Path $depDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })

    # Normalize PSCustomObject (JSON) to hashtable for uniform access
    if ($DepGraph -and $DepGraph -isnot [hashtable]) {
        $ht = @{}
        foreach ($p in $DepGraph.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        $DepGraph = $ht
    }
    if ($FileModules -and $FileModules -isnot [hashtable]) {
        $ht = @{}
        foreach ($p in $FileModules.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        $FileModules = $ht
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $DepGraph.Keys) {
        $depObj = $DepGraph[$node]
        $deps = $depObj.Deps
        $depNames = @()
        $blockedBy = @()
        $allResolved = $true

        if ($deps -and $deps.Count -gt 0) {
            foreach ($dep in $deps) {
                $depNames += $dep.Ref
                $resolved = $false
                if ($dep.Status -eq "reviewed") {
                    $resolved = $null -ne ($completedFiles | Where-Object { $_ -like "*$($dep.Ref)*" })
                } elseif ($dep.Status -eq "complete") {
                    $resolved = Resolve-CompleteDep -DepRef $dep.Ref -RepoRoot $RepoRoot -TaskDir $TaskDir
                }
                if (-not $resolved) { $allResolved = $false; $blockedBy += $dep.Ref }
            }
        }

        $sessName = $node -replace ".md$", ""
        $mod = if ($FileModules -and $FileModules.ContainsKey($node)) { $FileModules[$node] } else { "unassigned" }
        $depStr = if ($depNames.Count -gt 0) { $depNames -join ", " } else { "---" }
        $resStr = if ($allResolved) { "OK" } else { "NO" }
        $blkStr = if ($blockedBy.Count -gt 0) { $blockedBy -join ", " } else { "---" }
        $rows.Add([PSCustomObject]@{
            Session = $sessName
            Module = $mod
            DependsOn = $depStr
            Resolved = $resStr
            BlockedBy = $blkStr
        })
    }

    $sorted = $rows | Sort-Object Resolved, Module, Session
    $header = "| Session | Module | DependsOn | Resolved | Blocked By |"
    $sep    = "|---------|--------|-----------|----------|------------|"
    $body = $sorted | ForEach-Object {
        "| $($_.Session) | $($_.Module) | $($_.DependsOn) | $($_.Resolved) | $($_.BlockedBy) |"
    }
    return ($header, $sep) + $body -join "`n"
}

# Guard: skip execution when dot-sourced (tests import functions only)
$isDotSourced = $MyInvocation.InvocationName -eq '.'

if (-not $isDotSourced) {
    if (-not $cacheHit) {
        $planFiles = Get-ChildItem -Path $TaskDir -Filter "*.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }

        if (-not $planFiles) {
            $result = @{ groups = @(); fileModules = @{}; unprocessed = @(); depGraph = @{}; cycleDetected = $false; cyclePath = @(); readySet = @(); blockedSet = @(); note = "No plan files found in $TaskDir" }
        } else {
            $plans = [System.Collections.Generic.List[object]]::new()
            $fileModules = @{}
            $moduleHeaders = @{}
            $lockPattern = "(?m)^-\s*Status:\s*locked"

            foreach ($f in $planFiles) {
                $content = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $content) { continue }

                $namespace = Get-FileNamespace -FileName $f.Name
                $connascenceScope = Get-HeaderField -Content $content -FieldName "ConnascenceScope"
                $rawModule = Get-HeaderField -Content $content -FieldName "Module"
                $moduleField = if (-not $rawModule) { 'main' } elseif ($rawModule -match '^\d+$') { "module-$rawModule" } elseif ($rawModule -ieq 'main' -or $rawModule -ieq '0') { 'main' } else { $rawModule }
                $moduleHeaders[$f.Name] = if ($rawModule) { $moduleField } else { $null }
                $filesField = Get-FilesField -Content $content
                $isLocked = $content -match $lockPattern
                $iterStr = if ($f.BaseName -match '(\d+)$') { $matches[1] } else { "0" }
                $iteration = [int]::TryParse($iterStr, [ref]$null) | Out-Null; $iteration = if ($iterStr -match '^\d+$') { [int]$iterStr } else { 0 }
                $dependsOn = Get-DependsOn -Content $content

                $explicitScope = @()
                if ($connascenceScope) {
                    $explicitScope = ($connascenceScope -split ',' | ForEach-Object { $_.Trim() -replace '^`+','' -replace '`+$','' }) | Where-Object { $_ }
            }

            $plans.Add([PSCustomObject]@{
                FileName         = $f.Name
                FullPath         = $f.FullName
                Namespace        = $namespace
                Module           = $moduleField
                Iteration        = $iteration
                Files            = $filesField
                ExplicitScope    = $explicitScope
                IsLocked         = $isLocked
                DependsOn        = @($dependsOn)
            })
            $fileModules[$f.Name] = $moduleField
        }

        $groups = [System.Collections.Generic.List[object]]::new()
        $assigned = [System.Collections.Generic.HashSet[string]]::new()
        $nsGroups = $plans | Group-Object Namespace

        foreach ($nsGroup in $nsGroups) {
            $sortedPlans = @($nsGroup.Group | Sort-Object Iteration)
            $overlapGraph = @{}
            foreach ($plan in $sortedPlans) {
                $overlapGraph[$plan.FileName] = [System.Collections.Generic.List[string]]::new()
            }
            for ($i = 0; $i -lt $sortedPlans.Count; $i++) {
                for ($j = $i + 1; $j -lt $sortedPlans.Count; $j++) {
                    if ($sortedPlans[$i].Module -ne $sortedPlans[$j].Module) { continue }
                    $shared = $sortedPlans[$i].Files | Where-Object { $sortedPlans[$j].Files -contains $_ }
                    if ($shared) {
                        $overlapGraph[$sortedPlans[$i].FileName].Add($sortedPlans[$j].FileName)
                        $overlapGraph[$sortedPlans[$j].FileName].Add($sortedPlans[$i].FileName)
                    }
                }
            }

            $visited = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($plan in $sortedPlans) {
                if ($visited.Contains($plan.FileName)) { continue }
                if ($assigned.Contains($plan.FileName)) { continue }

                $component = [System.Collections.Generic.List[object]]::new()
                $componentFiles = [System.Collections.Generic.HashSet[string]]::new()
                $componentLocked = $false
                $componentModule = $plan.Module
                $stack = [System.Collections.Generic.Stack[string]]::new()
                $stack.Push($plan.FileName)

                while ($stack.Count -gt 0) {
                    $currentName = $stack.Pop()
                    if ($visited.Contains($currentName)) { continue }
                    $null = $visited.Add($currentName)
                    $null = $assigned.Add($currentName)

                    $currentPlan = $sortedPlans | Where-Object { $_.FileName -eq $currentName }
                    if (-not $currentPlan) { continue }
                    $component.Add($currentPlan.FileName)
                    foreach ($f in $currentPlan.Files + $currentPlan.ExplicitScope) {
                        $null = $componentFiles.Add($f)
                    }
                    if ($currentPlan.IsLocked) { $componentLocked = $true }

                    foreach ($neighbor in $overlapGraph[$currentName]) {
                        if (-not $visited.Contains($neighbor)) {
                            $stack.Push($neighbor)
                        }
                    }
                }

                if ($component.Count -gt 0) {
                    $groupId = if ($nsGroup.Name) { "$($nsGroup.Name)-sub$($groups.Count)" } else { "sub$($groups.Count)" }
                    $groups.Add([PSCustomObject]@{
                        GroupId    = $groupId
                        Namespace  = $nsGroup.Name
                        Module     = $componentModule
                        Files      = @($component)
                        Scope      = @($componentFiles | Sort-Object)
                        IsLocked   = $componentLocked
                    })
                }
            }
        }

        $depGraph = [ordered]@{}
        foreach ($plan in $plans) {
            if ($plan.DependsOn.Count -gt 0) {
                $depDeps = @()
                foreach ($d in $plan.DependsOn) {
                    $depDeps += [PSCustomObject]@{ Ref = $d.Ref; Status = $d.Status }
                }
                $depGraph[$plan.FileName] = [PSCustomObject]@{ Deps = $depDeps; Status = if ($plan.IsLocked) { "locked" } else { "ready" } }
            } else {
                $depGraph[$plan.FileName] = [PSCustomObject]@{ Deps = @(); Status = if ($plan.IsLocked) { "locked" } else { "ready" } }
            }
        }

        $crossNamespaceConflicts = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $groups.Count; $i++) {
            for ($j = $i + 1; $j -lt $groups.Count; $j++) {
                $scopeI = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($f in $groups[$i].Scope) { $null = $scopeI.Add($f) }
                $shared = $groups[$j].Scope | Where-Object { $scopeI.Contains($_) }
                if (-not $shared) { continue }

                $hasDep = $false
                foreach ($planName in $groups[$i].Files) {
                    if ($depGraph.Contains($planName)) {
                        foreach ($dep in $depGraph[$planName].Deps) {
                            if ($groups[$j].Files | Where-Object { $_ -like "*$($dep.Ref)*" }) { $hasDep = $true; break }
                        }
                    }
                    if ($hasDep) { break }
                }
                if (-not $hasDep) {
                    foreach ($planName in $groups[$j].Files) {
                        if ($depGraph.Contains($planName)) {
                            foreach ($dep in $depGraph[$planName].Deps) {
                                if ($groups[$i].Files | Where-Object { $_ -like "*$($dep.Ref)*" }) { $hasDep = $true; break }
                            }
                        }
                        if ($hasDep) { break }
                    }
                }

                if (-not $hasDep) {
                    $crossNamespaceConflicts.Add([PSCustomObject]@{
                        GroupA      = $groups[$i].Namespace
                        GroupB      = $groups[$j].Namespace
                        SharedFiles = @($shared)
                    })
                }
            }
        }

        $unassigned = $plans | Where-Object { -not $assigned.Contains($_.FileName) }

        $cycleResult = Test-DependsOnCycle -DepGraph $depGraph
        $readyResult = Get-ReadySet -DepGraph $depGraph -CompletedDir (Join-Path $RepoRoot "Tasks/Complete")

        $result = [PSCustomObject]@{
            groups                   = @($groups)
            fileModules              = $fileModules
            crossNamespaceConflicts  = @($crossNamespaceConflicts)
            unprocessed              = @($unassigned | ForEach-Object { $_.FileName })
            depGraph                 = $depGraph
            cycleDetected            = $cycleResult.HasCycle
            cyclePath                = @($cycleResult.CyclePath)
            readySet                 = @($readyResult.ReadySet)
            blockedSet               = @($readyResult.BlockedSet)
            danglingDeps             = @($readyResult.DanglingDeps)
            note                     = if ($groups.Count -eq 0) { "No connascence groups found" } else { "$($groups.Count) group(s) from $($plans.Count) plan(s)" }
        }

        # Auto-distribute unassigned connascence groups across the requested modules
        if ($ModuleCount -gt 0) {
            $moduleIds = @('main') + (1..$ModuleCount | ForEach-Object { "module-$_" })
            $moduleLoad = @{}
            foreach ($m in $moduleIds) { $moduleLoad[$m] = 0 }
            foreach ($file in $codeFiles) {
                if ($moduleHeaders.ContainsKey($file.Name) -and $moduleHeaders[$file.Name]) {
                    $m = $moduleHeaders[$file.Name]
                    if ($moduleLoad.ContainsKey($m)) { $moduleLoad[$m]++ }
                }
            }

            foreach ($g in $groups) {
                $explicit = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($file in $g.Files) {
                    if ($moduleHeaders.ContainsKey($file) -and $moduleHeaders[$file]) { $null = $explicit.Add($moduleHeaders[$file]) }
                }
                $target = if ($explicit.Count -eq 1) { $explicit | Select-Object -First 1 } else { $null }
                if (-not $target) {
                    $min = [int]::MaxValue
                    foreach ($m in $moduleIds) { if ($moduleLoad[$m] -lt $min) { $min = $moduleLoad[$m]; $target = $m } }
                }
                foreach ($file in $g.Files) { $fileModules[$file] = $target }
                $g.Module = $target
                $moduleLoad[$target] += $g.Files.Count
            }
            $finalLoad = @{}
            foreach ($fm in $fileModules.Values) { if (-not $finalLoad.ContainsKey($fm)) { $finalLoad[$fm] = 0 }; $finalLoad[$fm]++ }
            $result.note += " | distributed across modules: $($($finalLoad.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
        }

        if ($cycleResult.HasCycle) {
            $result.note += " | CYCLE DETECTED: $($cycleResult.CyclePath -join ' → ')"
        }
        if ($readyResult.DanglingDeps -and $readyResult.DanglingDeps.Count -gt 0) {
            $result.note += " | $($readyResult.DanglingDeps.Count) dangling dep(s)"
        }

        # Save to cache (full result, not incremental)
        if ([string]::IsNullOrEmpty($IncrementalCompletedNamespace)) {
            $cachePayload = @{ signature = $cacheSignature; timestamp = (Get-Date -Format 'o'); result = $result } | ConvertTo-Json -Depth 10
            $cachePayload | Set-Content -Path $cacheFile -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }
} else {
    $result = $cachedResult
}
}

# ── Visualization outputs ──────────────────────────────────────────────────

if (-not $isDotSourced -and $AsDag) {
    $depGraphForVis = if ($cacheHit) { $result.depGraph } else { $depGraph }
    if ($depGraphForVis) {
        $mermaid = Format-DepGraphAsMermaid -DepGraph $depGraphForVis
        $bt = [string][char]0x60; $mermaidOutput = "$($bt)$($bt)$($bt)mermaid$($bt)n$mermaid$($bt)n$($bt)$($bt)$($bt)"
        if ($OutputDir) {
        $bt = [string][char]0x60; $nl = [string][char]10; $mermaidOutput = "$($bt)$($bt)$($bt)mermaid$($nl)$mermaid$($nl)$($bt)$($bt)$($bt)"
            $dagFile = Join-Path $OutputDir "plan-dag.md"; $mermaidOutput | Out-File $dagFile -Encoding utf8
        } else {
            Write-Host "`n### Dependency DAG`n"
            Write-Host $mermaidOutput
        }
    }
}

if (-not $isDotSourced -and $AsTable) {
    $depGraphForVis = if ($cacheHit) { $result.depGraph } else { $depGraph }
    $fileModulesForVis = if ($cacheHit) { $result.fileModules } else { $fileModules }
    if ($depGraphForVis) {
        $table = Format-DepStatusTable -DepGraph $depGraphForVis -FileModules $fileModulesForVis
        if ($OutputDir) {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force
            $depFile = Join-Path $OutputDir "plan-deps.md"; $table | Out-File $depFile -Encoding utf8
        } else {
            Write-Host "`n### Dependency Status`n"
            Write-Host $table
        }
    }
}

if (-not $isDotSourced) {
    if ($OutputDir -and $PassThru) {
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
        $jsonFile = Join-Path $OutputDir "connascence-groups.json"; Out-File -LiteralPath $jsonFile -Encoding utf8 -InputObject ($result | ConvertTo-Json -Depth 10)
    }

    if ($PassThru) {
        return $result | ConvertTo-Json -Depth 10
    }
    return $result
}
