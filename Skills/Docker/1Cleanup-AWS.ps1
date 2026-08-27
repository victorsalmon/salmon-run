<#
.SYNOPSIS
    Bulk IAM cleanup utility. Removes all OC-* users from AWS IAM.
#>
# ==============================================================================
# Interclaw — AWS IAM CLEANUP (v1.0)
# ==============================================================================
# Lists all <Project>-* IAM users, optionally disables/deletes their access keys,
# and deletes the users. Uses the same SSO credentials as other scripts.
#
# Usage:
#   pwsh -File 1Cleanup-AWS.ps1 [-SsoProfile <name>] [-WhatIf] [-Force]
#
#   -WhatIf      Show what would be deleted without making changes
#   -Force       Skip confirmation prompts
#   -SsoProfile  AWS SSO profile name (default: $env:AWS_SSO_PROFILE)
# ==============================================================================

param(
    [string]$SsoProfile = $env:AWS_SSO_PROFILE,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$env:PSModulePath = "$RepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $RepoRoot

Import-InterclawModule Core
Import-InterclawModule Provision

Write-Host "--- AWS IAM CLEANUP ---" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($SsoProfile)) {
    Write-Host "  [ERROR] AWS SSO profile not set. Pass -SsoProfile or set AWS_SSO_PROFILE env var." -ForegroundColor Red
    exit 1
}

Write-Host "  SSO Profile: $SsoProfile" -ForegroundColor Gray
if ($WhatIf) {
    Write-Host "  Mode: WHAT-IF (no changes will be made)" -ForegroundColor Yellow
}

Write-Host "`n[AWS] Listing IAM users..." -ForegroundColor Yellow

$UsersResult = Invoke-NativeCommand { aws iam list-users --profile $SsoProfile --output json 2>$null }
if (-not $UsersResult.Success) {
    Write-Host "  [ERROR] Could not list IAM users. Check SSO credentials." -ForegroundColor Red
    exit 1
}
$UsersJson = $UsersResult.Output

$AllUsers = ($UsersJson | ConvertFrom-Json).Users
$OcUsers = $AllUsers | Where-Object { $_.UserName -like "*-BASE-*" -or $_.UserName -like "*-SENTRY" -or $_.UserName -like "*-REKOGNITIONFALLBACK" }

if ($OcUsers.Count -eq 0) {
    Write-Host "  No IAM users found. Nothing to clean up." -ForegroundColor Green
    exit 0
}

Write-Host "  Found $($OcUsers.Count) user(s):`n" -ForegroundColor White

$UserSummary = @()
foreach ($User in $OcUsers) {
    $KeysResult = Invoke-NativeCommand { aws iam list-access-keys --user-name $User.UserName --profile $SsoProfile --output json 2>$null }
    $Keys = @()
    if ($KeysResult.Success -and -not [string]::IsNullOrWhiteSpace($KeysResult.Output)) {
        $Keys = @(($KeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
    }

    $PoliciesResult = Invoke-NativeCommand { aws iam list-user-policies --user-name $User.UserName --profile $SsoProfile --output json 2>$null }
    $PolicyNames = @()
    if ($PoliciesResult.Success -and -not [string]::IsNullOrWhiteSpace($PoliciesResult.Output)) {
        $PolicyNames = @(($PoliciesResult.Output | ConvertFrom-Json).PolicyNames)
    }

    $KeyStatuses = @()
    foreach ($Key in $Keys) {
        $KeyStatuses += "  $($Key.AccessKeyId) ($($Key.Status)) created $($Key.CreateDate.ToString('yyyy-MM-dd'))"
    }

    $UserSummary += [PSCustomObject]@{
        UserName    = $User.UserName
        KeyCount    = $Keys.Count
        PolicyCount = $PolicyNames.Count
        Created     = $User.CreateDate.ToString('yyyy-MM-dd')
        Arn         = $User.Arn
    }

    Write-Host "  [$($User.UserName)]" -ForegroundColor Cyan
    Write-Host "    Created: $($User.CreateDate.ToString('yyyy-MM-dd')), Keys: $($Keys.Count), Policies: $($PolicyNames.Count)" -ForegroundColor Gray
    if ($Keys.Count -gt 0) {
        foreach ($Ks in $KeyStatuses) { Write-Host $Ks -ForegroundColor DarkGray }
    }
    if ($PolicyNames.Count -gt 0) {
        Write-Host "    Policies: $($PolicyNames -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($WhatIf) {
    Write-Host "`n[WHAT-IF] The following would be deleted:" -ForegroundColor Yellow
    foreach ($Us in $UserSummary) {
        Write-Host "  - $($Us.UserName): $($Us.KeyCount) key(s), $($Us.PolicyCount) polic(ies)" -ForegroundColor Gray
    }
    exit 0
}

if (-not $Force) {
    $Answer = Read-Host "`nDelete ALL $($OcUsers.Count) users and their keys? (yes/no)"
    if ($Answer -ne "yes") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`n[AWS] Cleaning up users..." -ForegroundColor Yellow
$DeletedCount = 0
$FailedCount = 0
$SkippedCount = 0
$KeyDeletions = 0
$PolicyDeletions = 0

foreach ($User in $OcUsers) {
    Write-Host "`n  Processing $($User.UserName)..." -ForegroundColor Cyan
    $userFailed = $false

    try {
        $KeysResult = Invoke-NativeCommand { aws iam list-access-keys --user-name $User.UserName --profile $SsoProfile --output json 2>$null }
        if (-not $KeysResult.Success) { throw "Failed to list access keys" }
        if (-not [string]::IsNullOrWhiteSpace($KeysResult.Output)) {
            $Keys = @(($KeysResult.Output | ConvertFrom-Json).AccessKeyMetadata)
            foreach ($Key in $Keys) {
                try {
                    Write-Host "    Deleting key $($Key.AccessKeyId)..." -ForegroundColor Gray -NoNewline
                    $DelResult = Invoke-NativeCommand { aws iam delete-access-key --user-name $User.UserName --access-key-id $Key.AccessKeyId --profile $SsoProfile 2>$null | Out-Null }
                    if ($DelResult.Success) {
                        Write-Host " OK" -ForegroundColor Green
                        $KeyDeletions++
                    } else {
                        Write-Host " FAILED" -ForegroundColor Red
                    }
                } catch {
                    Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
                }
            }
        }
    } catch {
        Write-Host "    [ERROR] Listing access keys for $($User.UserName): $_" -ForegroundColor Red
        $userFailed = $true
    }

    try {
        $PoliciesResult = Invoke-NativeCommand { aws iam list-user-policies --user-name $User.UserName --profile $SsoProfile --output json 2>$null }
        if (-not $PoliciesResult.Success) { throw "Failed to list inline policies" }
        if (-not [string]::IsNullOrWhiteSpace($PoliciesResult.Output)) {
            $PolicyNames = @(($PoliciesResult.Output | ConvertFrom-Json).PolicyNames)
            foreach ($PolName in $PolicyNames) {
                try {
                    Write-Host "    Deleting inline policy '$PolName'..." -ForegroundColor Gray -NoNewline
                    $DelResult = Invoke-NativeCommand { aws iam delete-user-policy --user-name $User.UserName --policy-name $PolName --profile $SsoProfile 2>$null | Out-Null }
                    if ($DelResult.Success) {
                        Write-Host " OK" -ForegroundColor Green
                        $PolicyDeletions++
                    } else {
                        Write-Host " FAILED" -ForegroundColor Red
                    }
                } catch {
                    Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
                }
            }
        }
    } catch {
        Write-Host "    [ERROR] Listing inline policies for $($User.UserName): $_" -ForegroundColor Red
        $userFailed = $true
    }

    if (-not $userFailed) {
        try {
            Write-Host "    Deleting user $($User.UserName)..." -ForegroundColor Gray -NoNewline
            $DelUserResult = Invoke-NativeCommand { aws iam delete-user --user-name $User.UserName --profile $SsoProfile 2>$null | Out-Null }
            if ($DelUserResult.Success) {
                Write-Host " OK" -ForegroundColor Green
                $DeletedCount++
            } else {
                Write-Host " FAILED" -ForegroundColor Red
                $FailedCount++
            }
        } catch {
            Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
            $FailedCount++
        }
    } else {
        $SkippedCount++
        Write-Host "    [SKIP] Skipping user deletion for $($User.UserName) due to prior errors" -ForegroundColor Yellow
    }
}

Write-Host "`n--- CLEANUP COMPLETE ---" -ForegroundColor Cyan
Write-Host "  Users deleted: $DeletedCount, Failed: $FailedCount, Skipped: $SkippedCount" -ForegroundColor $(if ($FailedCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Access keys deleted: $KeyDeletions, Inline policies deleted: $PolicyDeletions" -ForegroundColor Gray
