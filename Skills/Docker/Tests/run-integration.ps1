# Test harness — Regression-Only guard
# The batch form (`Invoke-Pester <tests-dir> -Tag "Regression-Only"`) throws
# "Unsupported Operating system!" from Pester 6.0.1 GetPesterOs/TestDrive on this
# host (pre-existing, ~41 containers / 691 failures — see
# Tasks/Archive/Manual/2026-08-02/2026-08-01-pester-batch-tag-run-unsupported-os.md).
# The per-file fallback below is the canonical invocation: run the tag-filtered
# suite file-by-file, which passes. Re-test the batch form after a Pester upgrade
# and remove the fallback when the batch form works.
param(
    [switch]$RunIntegration,
    [switch]$RegressionGuard,
    [switch]$Apply
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path.TrimEnd('\')
$testDir = $PSScriptRoot

function Test-EnvReady {
    $ready = $true
    $checks = @()

    $awsResult = & aws sts get-caller-identity --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $checks += [PSCustomObject]@{ Check = "AWS SSO"; Status = "Ready" }
    } else {
        $checks += [PSCustomObject]@{ Check = "AWS SSO"; Status = "Not available"; Detail = "aws sts get-caller-identity failed" }
        $ready = $false
    }

    $dockerResult = & docker info --format "{{.ServerVersion}}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $checks += [PSCustomObject]@{ Check = "Docker daemon"; Status = "Ready"; Detail = "v$($dockerResult.Trim())" }
    } else {
        $checks += [PSCustomObject]@{ Check = "Docker daemon"; Status = "Not available" }
        $ready = $false
    }

    if ($ready) {
        $stackResult = & docker stack ls --format "{{.Name}}" 2>&1
        if ($LASTEXITCODE -eq 0 -and $stackResult) {
            $checks += [PSCustomObject]@{ Check = "Docker Swarm stacks"; Status = "Ready"; Detail = "$($stackResult -join ', ')" }
        } else {
            $checks += [PSCustomObject]@{ Check = "Docker Swarm stacks"; Status = "Not available" }
            $ready = $false
        }
    }

    return [PSCustomObject]@{
        Ready = $ready
        Checks = $checks
    }
}

function Get-ClassificationReport {
    param([switch]$PassThru)
    $classifications = @()
    Get-ChildItem -Path $testDir -Recurse -Filter "*.Tests.ps1" -File | ForEach-Object {
        $relPath = $_.FullName.Replace($repoRoot, '').TrimStart('\')
        $lines = Get-Content -Path $_.FullName
        $inDescribe = $null
        $hasDocker = $false
        $hasAws = $false
        $hasEnvDep = $false
        foreach ($line in $lines) {
            if ($line -match 'Describe\s+"([^"]+)"') {
                if ($inDescribe) {
                    $reasons = @()
                    if ($hasAws) { $reasons += "direct-aws-call" }
                    if ($hasDocker) { $reasons += "direct-docker-call" }
                    if ($hasEnvDep) { $reasons += "env-dependency" }
                    $classifications += [PSCustomObject]@{
                        File = $relPath
                        Describe = $inDescribe
                        Tags = @(if ($reasons.Count -gt 0) { "Integration" } else { "Unit" })
                        Reason = if ($reasons.Count -gt 0) { $reasons -join ', ' } else { "mocked" }
                    }
                }
                $inDescribe = $matches[1]
                $hasDocker = $false; $hasAws = $false; $hasEnvDep = $false
            }
            if ($line -match '\bdocker\b' -and $line -notmatch 'Mock|function\s+docker|#') { $hasDocker = $true }
            if ($line -match '\baws\b' -and $line -notmatch 'Mock|function\s+aws|#') { $hasAws = $true }
            if ($line -match '\$env:AWS_|Get-SecretFromAws|Invoke-Docker|docker\s+stack|docker\s+service|HydrationIntegration|RuntimeSmokeTest') { $hasEnvDep = $true }
        }
        if ($inDescribe) {
            $reasons = @()
            if ($hasAws) { $reasons += "direct-aws-call" }
            if ($hasDocker) { $reasons += "direct-docker-call" }
            if ($hasEnvDep) { $reasons += "env-dependency" }
            $classifications += [PSCustomObject]@{
                File = $relPath
                Describe = $inDescribe
                Tags = @(if ($reasons.Count -gt 0) { "Integration" } else { "Unit" })
                Reason = if ($reasons.Count -gt 0) { $reasons -join ', ' } else { "mocked" }
            }
        }
    }
    return ($classifications | Sort-Object File, Describe)
}

if ($RunIntegration) {
    Write-Host "=== Integration Test Runner ===" -ForegroundColor Cyan
    $envCheck = Test-EnvReady
    $envCheck.Checks | ForEach-Object {
        $color = if ($_.Status -eq "Ready") { "Green" } else { "Red" }
        Write-Host "  $($_.Check): " -NoNewline
        Write-Host "$($_.Status)" -ForegroundColor $color
        if ($_.Detail) { Write-Host "    $($_.Detail)" -ForegroundColor Gray }
    }

    if (-not $envCheck.Ready) {
        Write-Host "`nEnvironment not fully ready — skipping tests that require missing dependencies" -ForegroundColor Yellow
    }

    Write-Host "`nRunning integration tests..." -ForegroundColor Cyan
    $results = Invoke-Pester -Path $testDir -Tag "Integration" -PassThru

    Write-Host "`n=== Integration Test Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: $($results.PassedCount)" -ForegroundColor Green
    Write-Host "  Failed: $($results.FailedCount)" -ForegroundColor Red
    Write-Host "  Skipped: $($results.SkippedCount)" -ForegroundColor Yellow
    Write-Host "  Total: $($results.TotalCount)" -ForegroundColor White

    if (-not $envCheck.Ready) {
        Write-Host "`nNote: Some tests may have been skipped due to missing environment dependencies." -ForegroundColor Yellow
    }
    return
}

function Invoke-RegressionOnlyGuard {
    <#
    .SYNOPSIS
        Runs the Regression-Only tagged suite file-by-file.
    .DESCRIPTION
        Batch mode (`Invoke-Pester <dir> -Tag "Regression-Only"`) throws
        "Unsupported Operating system!" in Pester 6.0.1 GetPesterOs/TestDrive on
        this host. Per-file runs pass — this wrapper is the canonical invocation
        (see header comment).
    #>
    $testsDir = $PSScriptRoot
    $files = Get-ChildItem "$testsDir/*.Tests.ps1"
    $failed = @()
    foreach ($f in $files) {
        $r = Invoke-Pester -Path $f.FullName -Tag "Regression-Only" -PassThru -Output Minimal
        if ($r.FailedCount -gt 0) { $failed += $f.Name }
    }
    if ($failed.Count -gt 0) { throw "Regression-Only failures: $($failed -join ', ')" }
}

if ($RegressionGuard) {
    Write-Host "=== Regression-Only Guard (per-file fallback) ===" -ForegroundColor Cyan
    Invoke-RegressionOnlyGuard
    Write-Host "Regression-Only guard passed" -ForegroundColor Green
    return
}

$report = Get-ClassificationReport
Write-Host "=== Unit vs Integration Classification Report ===" -ForegroundColor Cyan
$report | Group-Object File | ForEach-Object {
    Write-Host "File: $($_.Name)" -ForegroundColor Yellow
    $_.Group | ForEach-Object {
        $tagColor = if ($_.Tags -contains "Integration") { "Red" } else { "Green" }
        Write-Host "  $($_.Describe): " -NoNewline
        Write-Host "$($_.Tags -join ',')" -ForegroundColor $tagColor
        if ($_.Reason -ne "mocked") {
            Write-Host "    Reason: $($_.Reason)" -ForegroundColor Gray
        }
    }
}
$unitCount = ($report | Where-Object { $_.Tags -contains "Unit" }).Count
$intCount = ($report | Where-Object { $_.Tags -contains "Integration" }).Count
Write-Host "`nTotal: $($report.Count) Describe blocks" -ForegroundColor Cyan
Write-Host "Unit: $unitCount | Integration: $intCount" -ForegroundColor Cyan
