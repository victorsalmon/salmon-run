<#
.SYNOPSIS
    Test script for Apollo.io email finder API integration.
#>
#Requires -Version 7.0
# ==============================================================================
# Scripts/Test-ApolloEmailFinder.ps1
# ==============================================================================
# Tests the Apollo.io People Search API as an email finder by domain.
# Replaces/validates the existing Hunter.io dependency.
#
# Usage:
#   .\Scripts\Test-ApolloEmailFinder.ps1 -Domain "example.com"
#   .\Scripts\Test-ApolloEmailFinder.ps1 -Domain "example.com" -ApiKey "sk-xxx"
# ==============================================================================

param(
    [Parameter(Mandatory)]
    [string]$Domain,

    [string]$ApiKey,

    [int]$Limit = 5,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

# --- Bootstrap ---
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$__ocRepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot
Import-InterclawModule Core
Import-InterclawModule Secrets
Import-InterclawModule Diagnostics

# --- Resolve API key ---
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = $env:APOLLO_SEARCH
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    try {
        $ApiKey = Get-SecretFromAws -KeyName "APOLLO_SEARCH" -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [WARN] AWS SM lookup failed for APOLLO_SEARCH: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "  [FAIL] No APOLLO_SEARCH key found. Set -ApiKey, env:APOLLO_SEARCH, or ensure AWS SM is reachable." -ForegroundColor Red
    exit 1
}

# --- Prepare output ---
$ReportsDir = Get-ReportsDir
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportFile = Join-Path $ReportsDir "apollo-search-$($Domain -replace '[^a-zA-Z0-9.-]', '_')-$Timestamp.json"
$LogFile = Join-Path $ReportsDir "apollo-search-$($Domain -replace '[^a-zA-Z0-9.-]', '_')-$Timestamp.log"

Write-SetupLog -Level INFO -Message "Apollo search started — Domain: $Domain, Limit: $Limit"

# --- Call Apollo API ---
$Body = @{
    api_key                     = $ApiKey
    q_organization_domains      = @($Domain)
    page                        = 1
    per_page                    = $Limit
    person_titles               = @()
} | ConvertTo-Json -Depth 10

$Headers = @{
    "Content-Type" = "application/json"
    "Cache-Control" = "no-cache"
}

$ApolloBaseUrl = $env:APOLLO_API_BASE_URL ?? "https://api.apollo.io/api/v1"
Write-Host "  [POST] $ApolloBaseUrl/people/search" -ForegroundColor Gray

try {
    $Response = Invoke-RestMethod -Uri "$ApolloBaseUrl/people/search" `
        -Method Post `
        -Body $Body `
        -Headers $Headers `
        -ContentType "application/json" `
        -ErrorAction Stop
} catch {
    $Status = $_.Exception.Response.StatusCode.value__
    $Detail = $_.ErrorDetails.Message
    Write-SetupLog -Level ERROR -Message "Apollo API error — Status: $Status, Detail: $Detail"
    Write-Host "  [FAIL] Apollo API returned $Status — $Detail" -ForegroundColor Red
    exit 1
}

# --- Process results ---
$People = $Response.people
if (-not $People -or $People.Count -eq 0) {
    Write-SetupLog -Level WARN -Message "No people found for domain: $Domain"
    Write-Host "  [WARN] No people found for domain: $Domain" -ForegroundColor Yellow
} else {
    Write-Host "  [OK] Found $($People.Count) people for $Domain" -ForegroundColor Green
    $People | ForEach-Object {
        $Name = "$($_.first_name) $($_.last_name)".Trim()
        $Email = $_.email
        $Title = $_.title
        $Confidence = $_.email_confidence
        if ($Confidence -eq $null) { $Confidence = "N/A" }
        Write-Host "    - $Name — $Email ($Title) [confidence: $Confidence]" -ForegroundColor Gray
    }
}

# --- Save report ---
$Report = @{
    timestamp        = (Get-Date -Format "o")
    domain           = $Domain
    total_results    = $Response.pagination.total_entries
    people_count     = if ($People) { $People.Count } else { 0 }
    people           = $People | ForEach-Object {
        @{
            name             = "$($_.first_name) $($_.last_name)".Trim()
            email            = $_.email
            title            = $_.title
            confidence       = $_.email_confidence
            organization     = $_.organization_name
            phone            = $_.phone
            linkedin_url     = $_.linkedin_url
        }
    }
    pagination = @{
        page        = $Response.pagination.page
        per_page    = $Response.pagination.per_page
        total_entries = $Response.pagination.total_entries
        total_pages   = $Response.pagination.total_pages
    }
}

$ReportJson = $Report | ConvertTo-Json -Depth 10
$ReportJson | Set-Content -Path $ReportFile -Encoding UTF8
Write-SetupLog -Level INFO -Message "Report saved: $ReportFile"

# --- Summary log ---
$LogLines = @(
    "========================================"
    "Apollo Email Finder Test"
    "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Domain: $Domain"
    "Limit: $Limit"
    "People Found: $(if ($People) { $People.Count } else { 0 })"
    "Total Matches: $($Response.pagination.total_entries)"
    "----------------------------------------"
)
if ($People) {
    $People | ForEach-Object {
        $LogLines += "$($_.first_name) $($_.last_name) | $($_.email) | $($_.title) | confidence=$($_.email_confidence)"
    }
}
$LogLines += "========================================"
$LogLines -join "`n" | Set-Content -Path $LogFile -Encoding UTF8

Write-Host "  [OK] Log saved: $LogFile" -ForegroundColor Green

if ($PassThru) { return $Report }
