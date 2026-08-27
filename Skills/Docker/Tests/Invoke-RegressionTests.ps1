<#
.SYNOPSIS
    Run the full Regression Test suite (all Pester tests) and capture structured results.
.DESCRIPTION
    Runs the full Pester test suite (or filtered by -Tag for Regression-Only subset), captures failures, passes, and skips,
    and writes structured JSON output to Tasks/Logs/regression-tests-<date>.json.
    Designed to be called by the refactor pipeline or directly from Domain 8 of the alignment audit.
.PARAMETER Tag
    Filter tests by Pester tag (default: run all tests for full Regression Test coverage). Use "Regression-Only" to run only regression-guard tests.
.PARAMETER WriteDrafts
    Call Write-DraftPlan.ps1 for each failing test.
.PARAMETER PassThru
    Return the structured results object instead of printing console output.
.PARAMETER SuiteOnly
    Compatibility alias — accepted and ignored (this script always runs suite-only).
#>
param(
    [string]$Tag,
    [switch]$WriteDrafts,
    [switch]$PassThru,
    [switch]$SuiteOnly
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = $ScriptDir
while ($RepoRoot) {
    if (Test-Path (Join-Path $RepoRoot "AGENTS.md") -PathType Leaf) { break }
    if (Test-Path (Join-Path $RepoRoot ".git") -PathType Container) { break }
    $parent = Split-Path $RepoRoot -Parent
    if ($parent -eq $RepoRoot) { $RepoRoot = $null; break }
    $RepoRoot = $parent
}
if (-not $RepoRoot) { $RepoRoot = Join-Path $HOME "intersite-orchestrator" }

$TestDir = $ScriptDir
$LogDir = Join-Path $RepoRoot "Tasks\Logs"
$null = New-Item -ItemType Directory -Path $LogDir -Force
$DateStamp = Get-Date -Format "yyyy-MM-dd"
$LogPath = Join-Path $LogDir "regression-tests-$DateStamp.json"

Write-Host "=== Regression Tests ===" -ForegroundColor Cyan
Write-Host "  Running Pester suite (Tag=$($Tag ?? 'all'))..." -ForegroundColor Yellow

try {
    if ($Tag) { $suiteResult = Invoke-Pester -Path $TestDir -Tag $Tag -PassThru -ErrorAction SilentlyContinue }
    else { $suiteResult = Invoke-Pester -Path $TestDir -PassThru -ErrorAction SilentlyContinue }
} catch {
    Write-Warning "  Pester suite execution failed: $_"
    $suiteResult = $null
}

$Failures = @(); $Skips = @(); $SuiteSummary = $null

if ($suiteResult) {
    $SuiteSummary = [PSCustomObject]@{
        totalCount = $suiteResult.TotalCount; passedCount = $suiteResult.PassedCount
        failedCount = $suiteResult.FailedCount; skippedCount = $suiteResult.SkippedCount
        tag = if ($Tag) { $Tag } else { "all" }
    }
    if ($suiteResult.FailedCount -gt 0 -and $suiteResult.Tests) {
        $Failures = $suiteResult.Tests | Where-Object { $_.Passed -eq $false -and $_.Skipped -eq $false } | ForEach-Object {
            $errMsg = if ($_.ErrorRecord) { $_.ErrorRecord[0].Exception.Message } else { "Unknown error" }
            [PSCustomObject]@{ Describe = $_.Describe; It = $_.Name; Error = $errMsg }
        }
    }
    if ($suiteResult.SkippedCount -gt 0 -and $suiteResult.Tests) {
        $Skips = $suiteResult.Tests | Where-Object { $_.Skipped } | ForEach-Object {
            [PSCustomObject]@{ Describe = $_.Describe; It = $_.Name }
        }
    }
    Write-Host "  Total: $($suiteResult.TotalCount) | Passed: $($suiteResult.PassedCount) | Failed: $($suiteResult.FailedCount) | Skipped: $($suiteResult.SkippedCount)" -ForegroundColor $(if ($suiteResult.FailedCount -eq 0) { "Green" } else { "Red" })
    if ($Failures.Count -gt 0) { Write-Host "  Failures:" -ForegroundColor Red; $Failures | ForEach-Object { Write-Host "    - [$($_.Describe)] $($_.It): $($_.Error)" -ForegroundColor Gray } }
    if ($Skips.Count -gt 0) { Write-Host "  Skipped tests:" -ForegroundColor Yellow; $Skips | ForEach-Object { Write-Host "    - [$($_.Describe)] $($_.It)" -ForegroundColor Gray } }
    if ($WriteDrafts -and $Failures.Count -gt 0) {
        $draftPlanScript = Join-Path $RepoRoot "Skills\\Orchestration\Workflows\Audit\Write-DraftPlan.ps1"
        if (Test-Path $draftPlanScript) {
            $detailLines = $Failures | ForEach-Object { "[$($_.Describe)] $($_.It): $($_.Error)" }
            try { & $draftPlanScript -Domain "domain-4" -Severity high -BlastRadius critical -Title "Pester test failures detected" -Detail "$($Failures.Count) test(s) failed. Details: $($detailLines -join ' | ')" -Files @("Skills/Docker/Tests/") }
            catch { Write-Warning "Write-DraftPlan failed: $_" }
        }
    }
} else {
    Write-Host "  Suite did not return results (possible environment issue)" -ForegroundColor Yellow
    $SuiteSummary = [PSCustomObject]@{ totalCount = 0; passedCount = 0; failedCount = 0; skippedCount = 0; tag = if ($Tag) { $Tag } else { "all" }; error = "Suite execution returned no results" }
}

$Result = [PSCustomObject]@{ timestamp = (Get-Date -Format "o"); command = "Invoke-RegressionTests.ps1"; repoRoot = $RepoRoot; parameters = @{ Tag = $Tag; WriteDrafts = [bool]$WriteDrafts; SuiteOnly = [bool]$SuiteOnly }; summary = $SuiteSummary; failures = @($Failures); skips = @($Skips) }
$Result | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
Write-Host "  Results written: $LogPath" -ForegroundColor Cyan
$bColor = if ($SuiteSummary.failedCount -gt 0) { "Red" } else { "Green" }
Write-Host "Regression Tests: $($SuiteSummary.passedCount)/$($SuiteSummary.totalCount) passed, $($SuiteSummary.failedCount) failed, $($SuiteSummary.skippedCount) skipped" -ForegroundColor $bColor
if ($PassThru) { return $Result }
