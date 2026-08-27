<#
.SYNOPSIS
    Creates custom field definitions in Attio CRM via the Attio API.
#>
#Requires -Version 7.0
# ==============================================================================
# Scripts/New-AttioCustomFields.ps1
# ==============================================================================
# Creates custom fields on the Attio `people` object via the v2 REST API.
# Fields: verification_status (select), email_confidence (number),
#         lead_score (number), campaign_status (select).
# Idempotent: skips fields that already exist.
#
# Usage:
#   .\Scripts\New-AttioCustomFields.ps1
#   .\Scripts\New-AttioCustomFields.ps1 -ApiKey "sk-xxx"
# ==============================================================================

param(
    [string]$ApiKey,
    [string]$BaseUrl = "https://api.attio.com/v2"
)

$ErrorActionPreference = "Stop"

# --- Bootstrap ---
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$__ocRepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot
Import-InterclawModule Core
Import-InterclawModule Secrets

# --- Resolve API key ---
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = $env:ATTIO_WRITE_KEY
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    try {
        $ApiKey = Get-SecretFromAws -KeyName "ATTIO_WRITE_KEY" -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [WARN] AWS SM lookup failed for ATTIO_WRITE_KEY: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "  [FAIL] No ATTIO_WRITE_KEY found. Set -ApiKey, env:ATTIO_WRITE_KEY, or ensure AWS SM is reachable." -ForegroundColor Red
    exit 1
}

$Headers = @{
    "Authorization" = "Bearer $ApiKey"
    "Content-Type"  = "application/json"
}

# --- Field definitions ---
$Fields = @(
    @{
        slug  = "verification_status"
        title = "Verification Status"
        type  = "select"
        config = @{
            options = @(
                @{ name = "Verified"; slug = "verified" }
                @{ name = "Bounced";  slug = "bounced" }
                @{ name = "Unknown";  slug = "unknown" }
            )
        }
    }
    @{
        slug  = "email_confidence"
        title = "Email Confidence"
        type  = "number"
        config = @{
            min_value = 0.0
            max_value = 1.0
        }
    }
    @{
        slug  = "lead_score"
        title = "Lead Score"
        type  = "number"
        config = @{
            min_value = 0.0
            max_value = 100.0
        }
    }
    @{
        slug  = "campaign_status"
        title = "Campaign Status"
        type  = "select"
        config = @{
            options = @(
                @{ name = "Contacted";  slug = "contacted" }
                @{ name = "Responded";  slug = "responded" }
                @{ name = "Booked";     slug = "booked" }
                @{ name = "Converted";  slug = "converted" }
                @{ name = "Dropped";    slug = "dropped" }
            )
        }
    }
)

$ObjectType = "people"
$ListUri = "$BaseUrl/v2/objects/$ObjectType/attributes"
$CreateUri = "$BaseUrl/v2/objects/$ObjectType/attributes"

Write-Host "  [..] Checking existing attributes on '$ObjectType' object..." -ForegroundColor Gray

# --- Fetch existing attributes (for idempotency) ---
$ExistingSlugs = @()
try {
    $ExistingResp = Invoke-RestMethod -Uri $ListUri -Method GET -Headers $Headers -ErrorAction Stop
    $ExistingSlugs = $ExistingResp.data | ForEach-Object { $_.slug }
    Write-Host "  [OK] Found $($ExistingSlugs.Count) existing attributes" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Could not list attributes: $_" -ForegroundColor Red
    exit 1
}

# --- Create missing fields ---
$ExitCode = 0
foreach ($Field in $Fields) {
    $Slug = $Field.slug
    if ($Slug -in $ExistingSlugs) {
        Write-Host "  [SKIP] '$Slug' already exists" -ForegroundColor DarkGray
        continue
    }

    $Body = $Field | ConvertTo-Json -Depth 10
    Write-Host "  [..] Creating '$Slug' ($($Field.type))..." -ForegroundColor Gray

    try {
        $Resp = Invoke-RestMethod -Uri $CreateUri -Method POST -Headers $Headers -Body $Body -ContentType "application/json" -ErrorAction Stop
        Write-Host "  [OK] Created '$Slug'" -ForegroundColor Green
    } catch {
        $Status = $_.Exception.Response.StatusCode.value__
        $Detail = $_.ErrorDetails.Message
        Write-Host "  [FAIL] '$Slug' — HTTP $Status : $Detail" -ForegroundColor Red
        $ExitCode = 1
    }
}

if ($ExitCode -eq 0) {
    Write-Host "`n  [OK] All fields processed successfully" -ForegroundColor Green
} else {
    Write-Host "`n  [WARN] Some fields failed — check output above" -ForegroundColor Yellow
}

exit $ExitCode
