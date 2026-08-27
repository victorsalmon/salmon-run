#Requires -Version 7.2
<#
.SYNOPSIS
    Mutation-testing harness for plugin runbooks.

.DESCRIPTION
    Runs PluginRunbook.Tests.ps1 against a git worktree, then applies a series
    of controlled mutations and re-runs the tests. A mutation is "detected" if
    the test suite fails after the mutation is applied. This proves the
    runbook invariant tests are sensitive to real defects.

.PARAMETER Rounds
    Number of random mutations to run per mutation type. Default 1.

.PARAMETER NoCleanup
    Leave the worktree behind for inspection.
#>
[CmdletBinding()]
param(
    [int]$Rounds = 1,
    [switch]$NoCleanup
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
$TestFile = Join-Path $PSScriptRoot 'PluginRunbook.Tests.ps1'

# Ensure the test file exists and parses before cloning.
$null = [System.Management.Automation.Language.Parser]::ParseFile($TestFile, [ref]$null, [ref]$null)

# Create a unique worktree.
$worktreeName = "mutation-$(Get-Random -Minimum 10000 -Maximum 99999)"
$worktreePath = Join-Path ([System.IO.Path]::GetTempPath()) $worktreeName

if (Test-Path $worktreePath) {
    Remove-Item -Recurse -Force $worktreePath
}

$worktreePath = (New-Item -ItemType Directory -Path $worktreePath).FullName
$null = git -C $RepoRoot worktree add $worktreePath

function Test-Runbooks {
    param(
        [string]$Path = $worktreePath
    )
    $test = Join-Path $Path 'Skills' 'Docker' 'Tests' 'PluginRunbook.Tests.ps1'
    $result = Invoke-Pester -Path $test -PassThru -Output Minimal
    return $result
}

function Copy-TestFile {
    $destDir = Join-Path $worktreePath 'Skills' 'Docker' 'Tests'
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -Path $TestFile -Destination (Join-Path $destDir 'PluginRunbook.Tests.ps1') -Force
}

function Get-RunbookFiles {
    param([string]$Root = $worktreePath)
    Get-ChildItem -Path $Root -Filter 'SKILL.md' -Recurse -File |
        Where-Object { $_.FullName -match '\\Plugins\\[^\\]+\\skills\\[^\\]+\\SKILL\.md$' }
}

function Remove-Worktree {
    if (-not $NoCleanup) {
        Set-Location ([System.IO.Path]::GetTempPath())
        git -C $RepoRoot worktree remove $worktreePath --force 2>$null
        if (Test-Path $worktreePath) {
            Start-Sleep -Milliseconds 250
            Remove-Item -Recurse -Force $worktreePath -ErrorAction SilentlyContinue
            if (Test-Path $worktreePath) {
                & cmd /c "rmdir /s /q ""$worktreePath"""
            }
        }
    }
}

try {
    Copy-TestFile

    # Baseline.
    $baseline = Test-Runbooks
    if ($baseline.FailedCount -gt 0) {
        throw "Baseline test run has $($baseline.FailedCount) failures. Fix before mutation testing."
    }

    $mutations = @(
        @{
            Name = 'Wrong runbook name in frontmatter'
            Apply = {
                $rb = Get-RunbookFiles -Root $worktreePath | Get-Random
                $content = Get-Content $rb.FullName -Raw
                $dir = $rb.Directory.Name
                $badName = "$dir-mutated"
                $content = $content -replace "(?m)^name: $([regex]::Escape($dir))`r?`n", "name: $badName`r`n"
                [System.IO.File]::WriteAllText($rb.FullName, $content)
            }
        },
        @{
            Name = 'Missing Plugin line'
            Apply = {
                $rb = Get-RunbookFiles -Root $worktreePath | Get-Random
                $content = Get-Content $rb.FullName -Raw
                $content = $content -replace '\*\*Plugin:\*\* `[^`]+`', ''
                [System.IO.File]::WriteAllText($rb.FullName, $content)
            }
        },
        @{
            Name = 'Master references non-existent child runbook'
            Apply = {
                $masters = Get-RunbookFiles -Root $worktreePath |
                    Where-Object { (Get-Content $_.FullName -Raw) -match '## Included runbooks' }
                if (-not $masters) { throw 'No master runbooks found' }
                $master = $masters | Get-Random
                $content = Get-Content $master.FullName -Raw
                $content = $content -replace '(## Included runbooks\r?\n\r?\n)', "`$1- **does-not-exist** -- mutation test child`r`n"
                [System.IO.File]::WriteAllText($master.FullName, $content)
            }
        },
        @{
            Name = 'Runbook references non-existent canonical skill'
            Apply = {
                $rb = Get-RunbookFiles -Root $worktreePath |
                    Where-Object { (Get-Content $_.FullName -Raw) -match 'Canonical:\s*`+' } |
                    Get-Random
                if (-not $rb) { throw 'No runbooks with canonical skill references found' }
                $content = Get-Content $rb.FullName -Raw
                $content = $content -replace 'Canonical: `Skills/[^`]+`', 'Canonical: `Skills/Does/Not/Exist.md`'
                [System.IO.File]::WriteAllText($rb.FullName, $content)
            }
        },
        @{
            Name = 'skills.json maps a skill to unknown plugin'
            Apply = {
                $skillsJson = Join-Path $worktreePath 'Skills' 'skills.json'
                $skills = Get-Content $skillsJson -Raw | ConvertFrom-Json
                $target = $skills | Where-Object { $_.plugin } | Get-Random
                $target.plugin = 'unknown-plugin-mutation'
                $out = $skills | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($skillsJson, $out)
            }
        },
        @{
            Name = 'Plugin manifest has wrong name'
            Apply = {
                $manifests = Get-ChildItem -Path (Join-Path $worktreePath 'Plugins' '*' '.devin-plugin' 'plugin.json')
                $mf = $manifests | Get-Random
                $content = Get-Content $mf.FullName -Raw
                $content = $content -replace '"name"\s*:\s*"[^"]+"', '"name": "mutated-name"'
                [System.IO.File]::WriteAllText($mf.FullName, $content)
            }
        }
    )

    $results = @()
    foreach ($m in $mutations) {
        for ($i = 1; $i -le $Rounds; $i++) {
            try {
                Set-Location $RepoRoot
                & $m.Apply

                $result = Test-Runbooks
                $detected = $result.FailedCount -gt $baseline.FailedCount

                $results += [PSCustomObject]@{
                    Mutation  = $m.Name
                    Round     = $i
                    Before    = $baseline.FailedCount
                    After     = $result.FailedCount
                    Detected  = $detected
                }

                Write-Host "[$($m.Name) / round $i] failures: $($result.FailedCount) (baseline $($baseline.FailedCount)) => $(if ($detected) { 'DETECTED' } else { 'NOT DETECTED' })" -ForegroundColor $(if ($detected) { 'Green' } else { 'Red' })
            }
            finally {
                # Revert tracked files in the worktree so the next mutation starts clean.
                # The test file is untracked and must be left in place.
                Set-Location ([System.IO.Path]::GetTempPath())
                git -C $worktreePath checkout -- . 2>$null
            }
        }
    }

    $undetected = $results | Where-Object { -not $_.Detected }
    if ($undetected.Count -gt 0) {
        Write-Warning "$(($undetected).Count) mutation(s) were not detected:"
        $undetected | ForEach-Object { Write-Warning "  - $($_.Mutation) (round $($_.Round))" }
    }

    $summary = $results | Group-Object Mutation | ForEach-Object {
        [PSCustomObject]@{
            Mutation      = $_.Name
            Rounds        = $_.Count
            Detected      = ($_.Group | Where-Object { $_.Detected }).Count
            NotDetected   = ($_.Group | Where-Object { -not $_.Detected }).Count
        }
    }

    Write-Output "`nMutation testing summary:`n"
    $summary | Format-Table -AutoSize

    $passed = $results | Where-Object { $_.Detected }
    Write-Output "Total mutations run: $($results.Count); detected: $($passed.Count); undetected: $($undetected.Count)."

    exit $undetected.Count
}
finally {
    Remove-Worktree
}
