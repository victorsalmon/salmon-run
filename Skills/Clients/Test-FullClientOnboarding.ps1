#!/usr/bin/env pwsh
# End-to-end integration test for the client onboarding pipeline.
# Uses mock email adapter, dry-run mode for repo/email creation.
# Exit code 0 = all tests passed.

param([switch]$LeaveSandbox)

$ErrorActionPreference = "Stop"
$sandbox = "$HOME\Clients\__integration-test__"
$testSlug = "integration-test"
$testName = "Integration Test Inc."

$passed = 0
$failed = 0

function Assert-True {
    param([scriptblock]$Condition, [string]$Message)
    if (& $Condition) {
        $script:passed++
        Write-Host "  [PASS] $Message"
    } else {
        $script:failed++
        Write-Host "  [FAIL] $Message"
    }
}

# Cleanup from prior runs
if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox }
$scheduleFile = "$HOME\intersite-orchestrator\Tasks\Schedule\client-email-$testSlug.json"
if (Test-Path $scheduleFile) { Remove-Item -Force $scheduleFile }

Write-Host "=== Client Onboarding Integration Test ==="
Write-Host ""

# Step 1: Folder scaffold
Write-Host "--- Step 1: New-ClientFolder ---"
$scriptsDir = Split-Path $PSScriptRoot -Parent
$folderScript = Join-Path $PSScriptRoot "New-ClientFolder.ps1"
if (-not (Test-Path $folderScript)) { $folderScript = "$HOME\intersite-orchestrator\Skills\Clients\New-ClientFolder.ps1" }

& $folderScript -ClientSlug $testSlug -ClientName $testName -RootPath "$HOME\Clients" 2>&1 | Out-Null
Assert-True { Test-Path "$sandbox\client-config.json" } "client-config.json created"
Assert-True { Test-Path "$sandbox\credentials" } "credentials directory created"
Assert-True { Test-Path "$sandbox\statements" } "statements directory created"
Assert-True { Test-Path "$sandbox\receipts" } "receipts directory created"
Assert-True { Test-Path "$sandbox\receipts\_manifest.csv" } "receipts manifest created"
Assert-True { Test-Path "$sandbox\tas" } "tas directory created"
Assert-True { Test-Path "$sandbox\reports" } "reports directory created"
Assert-True { Test-Path "$sandbox\PLAYBOOK-integration-test.md" } "PLAYBOOK created"
Assert-True { (Get-Item "$sandbox\.git").Exists } "git repo initialized"

# Step 2: Dry-run email provisioning
Write-Host "--- Step 2: New-ClientEmail (dry-run) ---"
$emailScript = Join-Path $PSScriptRoot "New-ClientEmail.ps1"
if (-not (Test-Path $emailScript)) { $emailScript = "$HOME\intersite-orchestrator\Skills\Clients\New-ClientEmail.ps1" }
$emailResult = & $emailScript -ClientSlug $testSlug -MailboxName "ap" -Domain "$testSlug.ca" -WhatIf 2>&1
Assert-True { $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null } "New-ClientEmail WhatIf exits successfully"
Assert-True { $emailResult -match "Email provisioning plan" -or $emailResult -match "WhatIf" } "New-ClientEmail produces plan output"

# Step 3: Dry-run repo creation
Write-Host "--- Step 3: New-ClientGitHubRepo (dry-run) ---"
$repoScript = Join-Path $PSScriptRoot "New-ClientGitHubRepo.ps1"
if (-not (Test-Path $repoScript)) { $repoScript = "$HOME\intersite-orchestrator\Skills\Clients\New-ClientGitHubRepo.ps1" }
$repoResult = & $repoScript -ClientSlug $testSlug -ClientName $testName -DryRun 2>&1
Assert-True { $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null } "New-ClientGitHubRepo DryRun exits successfully"
Assert-True { $repoResult -match "DryRun" -or $repoResult -match "GitHub Repo Plan" } "New-ClientGitHubRepo produces plan output"

# Step 4: Register email monitor (WhatIf)
Write-Host "--- Step 4: Register-ClientEmailMonitor (what-if) ---"
$monitorScript = Join-Path $PSScriptRoot "Register-ClientEmailMonitor.ps1"
if (-not (Test-Path $monitorScript)) { $monitorScript = "$HOME\intersite-orchestrator\Skills\Clients\Register-ClientEmailMonitor.ps1" }
$monitorResult = & $monitorScript -ClientSlug $testSlug -Email "ap@$testSlug.ca" -WhatIf 2>&1
Assert-True { $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null } "Register-ClientEmailMonitor WhatIf exits successfully"

# Step 5: Orchestrator dry-run
Write-Host "--- Step 5: Initialize-ClientEnvironment (dry-run) ---"
$orchestratorScript = Join-Path $PSScriptRoot "Initialize-ClientEnvironment.ps1"
if (-not (Test-Path $orchestratorScript)) { $orchestratorScript = "$HOME\intersite-orchestrator\Skills\Clients\Initialize-ClientEnvironment.ps1" }
$orchestratorResult = & $orchestratorScript -ClientSlug $testSlug -SkipEmail -SkipRepo -Interactive:$false 2>&1
Assert-True { $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null } "Initialize-ClientEnvironment exits successfully"
Assert-True { $orchestratorResult -match "ONBOARDING REPORT" -or $orchestratorResult -match "Stage" } "Initialize-ClientEnvironment produces report output"

# Summary
Write-Host ""
Write-Host "=== Results: $passed passed, $failed failed ==="
if ($failed -gt 0) { Write-Host "FAILED: Some tests did not pass." }

# Cleanup
if (-not $LeaveSandbox) {
    Write-Host "Cleaning up sandbox..."
    if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox }
    if (Test-Path $scheduleFile) { Remove-Item -Force $scheduleFile }
    Write-Host "Cleanup complete."
}

if ($failed -eq 0) { Write-Host "All tests passed" }
exit $failed
