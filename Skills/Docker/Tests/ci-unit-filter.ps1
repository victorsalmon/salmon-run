param(
    [switch]$PassThru,
    [switch]$Apply
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path.TrimEnd('\')
$testDir = Join-Path $PSScriptRoot "."
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
                $classifications += [PSCustomObject]@{
                    File = $relPath
                    Describe = $inDescribe
                    Tags = @()
                    Reason = @()
                }
            }
            $inDescribe = $matches[1]
            $hasDocker = $false
            $hasAws = $false
            $hasEnvDep = $false
        }
        if ($line -match '\bdocker\b' -and $line -notmatch '#|//|Mock|function\s+docker') { $hasDocker = $true }
        if ($line -match '\baws\b' -and $line -notmatch '#|//|Mock|function\s+aws') { $hasAws = $true }
        if ($line -match '\$env:AWS_|Get-SecretFromAws|Invoke-Docker|docker\s+stack|docker\s+service') { $hasEnvDep = $true }
        if ($line -match 'INTERCLAW_RUN_INTEGRATION_TESTS|RuntimeSmokeTest|HydrationIntegration') { $hasEnvDep = $true }
    }
    if ($inDescribe) {
        $reasons = @()
        if ($hasAws) { $reasons += "direct-aws-call" }
        if ($hasDocker) { $reasons += "direct-docker-call" }
        if ($hasEnvDep) { $reasons += "env-dependency" }
        $tag = if ($reasons.Count -gt 0) { "Integration" } else { "Unit" }
        $classifications += [PSCustomObject]@{
            File = $relPath
            Describe = $inDescribe
            Tags = @($tag)
            Reason = if ($reasons.Count -gt 0) { $reasons } else { @("mocked-or-no-deps") }
        }
    }
}

$classifications = $classifications | Sort-Object File, Describe

if (-not $PassThru -and -not $Apply) {
    # Interactive console report — Write-Host is deliberate here (colored terminal output, not pipeline data).
    Write-Host "=== Unit vs Integration Classification Report ===" -ForegroundColor Cyan
    Write-Host ""
    $classifications | Group-Object File | ForEach-Object {
        Write-Host "File: $($_.Name)" -ForegroundColor Yellow
        $_.Group | ForEach-Object {
            $tagColor = if ($_.Tags -contains "Integration") { "Red" } else { "Green" }
            Write-Host "  $($_.Describe): " -NoNewline
            Write-Host "$($_.Tags)" -ForegroundColor $tagColor
            if ($_.Reason.Count -gt 0 -and $_.Reason[0] -ne "mocked-or-no-deps") {
                Write-Host "    Reason: $($_.Reason -join ', ')" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }
    Write-Host "Total: $($classifications.Count) Describe/Context blocks" -ForegroundColor Cyan
    $unitCount = ($classifications | Where-Object { $_.Tags -contains "Unit" }).Count
    $intCount = ($classifications | Where-Object { $_.Tags -contains "Integration" }).Count
    Write-Host "Unit: $unitCount | Integration: $intCount" -ForegroundColor Cyan
    return
}

if ($PassThru) { return $classifications }
