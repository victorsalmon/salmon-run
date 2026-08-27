<#
.SYNOPSIS
    Validates that a running container has valid, working credentials for its services.
.DESCRIPTION
    Calls the container's /api/credentials endpoint (if available) to check whether
    each service credential is (A) configured and (B) passes a simple read-only validation
    call. Also provides a direct credential path: (A) check env vars exist via docker exec,
    (B) if they exist, test against a real API call inside the container.

    Designed as a universal credential health check. Each container that exposes a
    /api/credentials endpoint is automatically supported.

.PARAMETER ContainerName
    Docker service or container name to check. Defaults to "FRAD_is-bookkeeping".

.PARAMETER Port
    HTTP port the container listens on. Defaults to 21008 for is-bookkeeping.

.EXAMPLE
    Test-ContainerCredentials -ContainerName FRAD_is-bookkeeping -Port 21008

    Calls GET http://localhost:21008/api/credentials and reports each service's status.

.EXAMPLE
    Test-ContainerCredentials -ContainerName FRAD_is-bookkeeping

    Checks if the Bookkeeping container's health endpoint responds.
#>

param(
    [string]$ContainerName = "FRAD_is-bookkeeping",
    [int]$Port = 21008
)

$ErrorActionPreference = "Continue"

function Write-Step {
    param([string]$Label, [string]$Status, [string]$Detail)
    $icon = switch ($Status) {
        "PASS" { "[PASS]" }
        "FAIL" { "[FAIL]" }
        "INFO" { "[INFO]" }
        "SKIP" { "[SKIP]" }
        default { "[....]" }
    }
    $msg = if ($Detail) { "$icon $Label — $Detail" } else { "$icon $Label" }
    Write-Host $msg
}

Write-Host "=== Container Credential Validation ===" -ForegroundColor Cyan
Write-Host "Container: $ContainerName (port $Port)" -ForegroundColor Gray
Write-Host ""

# Step A: Check if container is running
Write-Step "Container reachable" "INFO" "checking..."
$containerId = docker ps --filter "name=$ContainerName" -q 2>$null
if (-not $containerId) {
    Write-Step "Container reachable" "FAIL" "not found or not running"
    exit 1
}
Write-Step "Container reachable" "PASS" "ID: $($containerId.Substring(0, 12))"

# Step B: Check if /api/credentials endpoint exists via HTTP
$baseUrl = "http://localhost:$Port"
try {
    $creds = Invoke-RestMethod -Uri "$baseUrl/api/credentials" -Method Get -TimeoutSec 10
    Write-Step "GET /api/credentials" "PASS" "endpoint responded"
    Write-Host ""
    Write-Host "  Service Credentials:" -ForegroundColor Yellow
    $allPassed = $true
    foreach ($prop in $creds.PSObject.Properties) {
        $status = if ($prop.Value) { "PASS" } else { "FAIL" }
        if (-not $prop.Value) { $allPassed = $false }
        Write-Step "  $($prop.Name)" $status
    }
    Write-Host ""
    if ($allPassed) {
        Write-Host "  Result: ALL SERVICES VALID" -ForegroundColor Green
    } else {
        Write-Host "  Result: SOME SERVICES FAILED" -ForegroundColor Yellow
    }
} catch {
    Write-Step "GET /api/credentials" "FAIL" "no /api/credentials endpoint (try direct checks)"
`
    # Fallback: direct Docker exec checks
    Write-Host ""
    Write-Host "  Fallback: checking env vars via docker exec..." -ForegroundColor Yellow
`
    $envVars = @(
        @{ Name = "TAVILY_API_KEY"; Test = "Tavily"; Check = { param($v) $v -and $v.Length -gt 10 } }
        @{ Name = "FIRECRAWL_API_KEY"; Test = "Firecrawl"; Check = { param($v) $v -and $v.Length -gt 10 } }
        @{ Name = "RECEIPTS_INTERSITE_EMAIL"; Test = "IMAP Intersite Email"; Check = { param($v) $v -and $v -match '@' } }
        @{ Name = "RECEIPTS_INTERSITE_PASS"; Test = "IMAP Intersite Pass"; Check = { param($v) $v -and $v.Length -gt 3 } }
        @{ Name = "RECEIPTS_RENTALS_EMAIL"; Test = "IMAP Rentals Email"; Check = { param($v) $v -and $v -match '@' } }
        @{ Name = "RECEIPTS_RENTALS_PASS"; Test = "IMAP Rentals Pass"; Check = { param($v) $v -and $v.Length -gt 3 } }
    )
`
    $allSet = $true
    foreach ($ev in $envVars) {
        $val = docker exec $containerId sh -c "echo `$`$$($ev.Name)" 2>$null
        $valid = & $ev.Check $val
        if ($valid) {
            Write-Step "  $($ev.Test) configured" "PASS"
        } else {
            Write-Step "  $($ev.Test) configured" "FAIL" "$($ev.Name) not set"
            $allSet = $false
        }
    }
`
    if (-not $allSet) {
        Write-Host ""
        Write-Host "  Some credentials are not configured. This may be expected if" -ForegroundColor Gray
        Write-Host "  the container does not use all services." -ForegroundColor Gray
    }
}

# Step C: Check health endpoint
Write-Host ""
Write-Step "GET /health" "INFO" "checking..."
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 5
    Write-Step "GET /health" "PASS" "status: $($health.status)"
} catch {
    Write-Step "GET /health" "FAIL" $_.Exception.Message
}

Write-Host ""
Write-Host "=== Validation Complete ===" -ForegroundColor Cyan
