<#
.SYNOPSIS
  Export new opencode sessions to Tasks/Complete/Prompts/ and rebuild the plan-association manifest.
  Safe to run repeatedly — skips already-exported sessions.
.DESCRIPTION
  Run this anytime to pull in new conversations from the opencode local database.
  Exports are JSON files named <date> - <title>.json containing full user prompts + agent responses.
  The _association-manifest.json maps each prompt to plan files it references.
.EXAMPLE
  .\Export-OpenCodeSessions.ps1                          # normal run
  .\Export-OpenCodeSessions.ps1 -Force                   # re-export everything
  .\Export-OpenCodeSessions.ps1 -SkipAssociation         # export only, skip manifest
  .\Export-OpenCodeSessions.ps1 -KeepRecent 30           # keep only the 30 most recent exports
#>

param(
  [switch]$Force,
  [switch]$SkipAssociation,
  [int]$KeepRecent = 0
)

$promptsDir = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\Tasks\Complete\Prompts")

# ── Step 1: Export new sessions ──────────────────────────────────────────────
$exported = 0
$skipped = 0

$sessions = opencode session list --format json 2>$null | ConvertFrom-Json
foreach ($s in $sessions) {
  $ts = [DateTimeOffset]::FromUnixTimeMilliseconds($s.created)
  $date = $ts.ToString("yyyy-MM-dd")
  $title = $s.title -replace '[<>:"/\\|?*]', '_' -replace '\s+', ' '
  $filename = "$date - $title.json"
  if ($filename.Length -gt 200) { $filename = $filename.Substring(0, 200) + ".json" }
  $path = Join-Path $promptsDir $filename

  $shouldExport = $Force -or -not (Test-Path $path)
  if ($shouldExport) {
    opencode export $s.id 2>$null | Out-File -FilePath $path -Encoding utf8
    $exported++
  } else {
    $skipped++
  }
}

Write-Host "$exported new, $skipped skipped"

# ── Step 1b: Prune old exports if -KeepRecent ────────────────────────────────
if ($KeepRecent -gt 0) {
  $allFiles = Get-ChildItem $promptsDir -Filter "*.json" | Where-Object { $_.Name -notlike '_*' }
  if ($allFiles.Count -gt $KeepRecent) {
    $allFiles | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepRecent | Remove-Object -Force
    Write-Host "Pruned to $KeepRecent most recent"
  }
}

# ── Step 2: Build association manifest ───────────────────────────────────────
if (-not $SkipAssociation) {
  Write-Host "Building association manifest..."
  
  $tasksRoot = Resolve-Path "$promptsDir\..\.."
  $planFiles = @{}
  Get-ChildItem -LiteralPath $tasksRoot -Recurse -Filter "*.md" -File | Where-Object {
    $_.FullName -notmatch '\\Prompts\\' -and $_.FullName -notmatch '\\node_modules\\' -and $_.Name -ne 'todo.md' -and $_.Name -ne '.gitkeep'
  } | ForEach-Object {
    $planFiles[$_.Name] = @{
      FullName = $_.FullName.Replace($tasksRoot, '').TrimStart('\')
      LastWriteTime = [DateTimeOffset]$_.LastWriteTimeUtc
    }
  }

  $associations = @{}
  Get-ChildItem $promptsDir -Filter "*.json" | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
    $promptName = $_.Name
    $content = Get-Content $_.FullName -Raw -Encoding UTF8

    $planWrites = @()
    $refPattern = 'Tasks/(?:Code|Working)/[^"`\s>]+\.md'
    $refMatches = [regex]::Matches($content, $refPattern)
    foreach ($m in $refMatches) { $planWrites += $m.Value.Replace('/', '\') }

    $createdMatch = [regex]::Match($content, '"created"\s*:\s*(\d{13})')
    $sessionTime = if ($createdMatch.Success) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$createdMatch.Groups[1].Value) } else { $null }

    $timeMatched = @()
    if ($sessionTime) {
      $searchDirs = @((Join-Path $tasksRoot "Code"), (Join-Path $tasksRoot "Working"))
      foreach ($dir in $searchDirs) {
        if (Test-Path $dir) {
          Get-ChildItem -LiteralPath $dir -Filter "*.md" -File | Where-Object {
            [Math]::Abs(($sessionTime - [DateTimeOffset]$_.LastWriteTimeUtc).TotalMinutes) -le 30
          } | ForEach-Object { $timeMatched += $_.Name }
        }
      }
    }

    $unique = ($planWrites + $timeMatched) | Sort-Object -Unique
    if ($unique.Count -gt 0) {
      $associations[$promptName] = @{
        AssociatedPlans = $unique
      }
    }
  }

  $manifest = @{
    Generated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    TotalPrompts = (Get-ChildItem $promptsDir -Filter "*.json" | Where-Object { $_.Name -notlike '_*' }).Count
    MatchedPrompts = $associations.Keys.Count
    Associations = $associations
  }
  $manifest | ConvertTo-Json -Depth 5 | Out-File (Join-Path $promptsDir "_association-manifest.json") -Encoding utf8
  Write-Host "Manifest: $($associations.Keys.Count) prompts matched to plans"
}
