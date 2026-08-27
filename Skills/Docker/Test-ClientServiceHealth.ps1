param(
    [switch]$PassThru,
    [switch]$Quiet,
    [string]$ClientName,
    [string]$ManifestPath = "$PSScriptRoot/../../Infrastructure/manifests/client-services.json"
)

<#
.SYNOPSIS
    Checks required Docker Swarm service replicas for all (or a named) client.

.DESCRIPTION
    Reads Infrastructure/manifests/client-services.json and verifies that every
    required Docker service for each client has desired_replicas == running_replicas.
    Reports healthy, degraded, and down clients.

    Also checks base_services (is-fleet) as
    infrastructure critical path — it must be up for any client to function.

.PARAMETER PassThru
    Return the result objects instead of printing a report.

.PARAMETER Quiet
    Suppress all output. Useful for scripting — implies -PassThru.

.PARAMETER ClientName
    Check only the named client (fuzzy match against name or display_name).

.PARAMETER ManifestPath
    Path to client-services.json. Defaults alongside this script.

.EXAMPLE
    ./Test-ClientServiceHealth.ps1

    Reports health for all clients.

.EXAMPLE
    ./Test-ClientServiceHealth.ps1 -ClientName "upscale"

    Checks only Upscale Havens (fuzzy match).

.EXAMPLE
    ./Test-ClientServiceHealth.ps1 -PassThru | ConvertTo-Json

    Returns structured JSON for programmatic consumption.
#>

$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if ($Quiet -or $PassThru) { return @() }
    Write-Host "WARN: docker not found on PATH — cannot check service health" -ForegroundColor Yellow
    return
}

$manifest = Get-Content -Raw -LiteralPath (Resolve-Path $ManifestPath) | ConvertFrom-Json
$allServices = $manifest.base_services.services + @($manifest.clients | ForEach-Object { $_.services.required })

function Get-ServiceStatus {
    $raw = docker service ls --format "{{.Name}} {{.Replicas}}" 2>$null
    if (-not $raw) { return @{} }
    $lines = @($raw) | ForEach-Object { $_ -split "`n" }
    $status = @{}
    foreach ($line in $lines) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -lt 2) { continue }
        $fullName = $parts[0]
        if ($parts[1] -match '(\d+)\s*/\s*(\d+)') {
            $entry = @{ running = [int]$Matches[1]; desired = [int]$Matches[2] }
            # Store by full (stack-prefixed) name
            $status[$fullName] = $entry
            # Also store by short (role-stable) name, stripping <STACK>_ prefix
            $underscoreIdx = $fullName.IndexOf('_')
            if ($underscoreIdx -gt 0) {
                $shortName = $fullName.Substring($underscoreIdx + 1)
                $status[$shortName] = $entry
            }
        }
    }
    return $status
}

$serviceStatus = Get-ServiceStatus

function Test-ClientHealthy {
    param($RequiredServices)
    $results = @{}
    foreach ($svc in $RequiredServices) {
        $info = $serviceStatus[$svc]
        if (-not $info) {
            $results[$svc] = "down (no service found)"
        } elseif ($info.running -eq 0) {
            $results[$svc] = "down (0/$($info.desired) replicas running)"
        } elseif ($info.running -lt $info.desired) {
            $results[$svc] = "degraded ($($info.running)/$($info.desired) replicas running)"
        } else {
            $results[$svc] = "up ($($info.running)/$($info.desired))"
        }
    }
    return $results
}

function Write-ClientReport {
    param(
        $Client,
        $Results,
        [int]$RequiredCount,
        [int]$UpCount
    )
    $label = "$($Client.display_name) ($($Client.name))"
    if ($RequiredCount -eq 0) {
        Write-Host "  [SKIP] $label — no required services" -ForegroundColor DarkGray
        return
    }
    if ($UpCount -eq $RequiredCount) {
        Write-Host "  [OK]   $label" -ForegroundColor Green
    } elseif ($UpCount -eq 0) {
        Write-Host "  [DOWN] $label" -ForegroundColor Red
    } else {
        Write-Host "  [DEGRADED] $label" -ForegroundColor Yellow
    }
    foreach ($kv in $Results.GetEnumerator() | Sort-Object Name) {
        $icon = switch -Regex ($kv.Value) {
            '^up\s*\(' { "  ✓ "; $fg = "Green" }
            '^degraded' { "  ⚠ "; $fg = "Yellow" }
            '^down\s*\(' { "  ✗ "; $fg = "Red" }
            default { "  ? "; $fg = "Gray" }
        }
        $prefix = $icon
        Write-Host "$prefix$($kv.Key): $($kv.Value)" -ForegroundColor $fg
    }
}

# --- Base services check ---
if (-not ($Quiet -or $PassThru)) {
    Write-Host "`n=== Base Fleet Services (critical path) ===" -ForegroundColor Cyan
}
$baseResults = Test-ClientHealthy -RequiredServices $manifest.base_services.services
$baseUp = ($baseResults.Values | Where-Object { $_ -like 'up*' }).Count
$baseTotal = $manifest.base_services.services.Count

if ($Quiet -or $PassThru) { } elseif ($baseUp -eq $baseTotal) {
    Write-Host "  [OK]   All base services up" -ForegroundColor Green
} else {
    Write-Host "  [DOWN] Base services degraded" -ForegroundColor Red
}
foreach ($kv in $baseResults.GetEnumerator() | Sort-Object Name) {
    if ($Quiet -or $PassThru) { continue }
    $fg = if ($kv.Value -like 'up*') { "Green" } elseif ($kv.Value -like 'degraded*') { "Yellow" } else { "Red" }
    $icon = if ($kv.Value -like 'up*') { "  ✓ " } elseif ($kv.Value -like 'degraded*') { "  ⚠ " } else { "  ✗ " }
    Write-Host "$icon$($kv.Name): $($kv.Value)" -ForegroundColor $fg
}

# --- Per-client checks ---
$targets = if ($ClientName) {
    $manifest.clients | Where-Object { $_.name -like "*$ClientName*" -or $_.display_name -like "*$ClientName*" }
} else { $manifest.clients }

$resultsOutput = @()
foreach ($client in $targets) {
    $req = @($client.services.required)
    if ($req.Count -eq 0) {
        if ($PassThru -or $Quiet) {
            $resultsOutput += [PSCustomObject]@{
                client = $client.name
                display = $client.display_name
                status = "skip"
                required = @()
                service_results = @{}
            }
        }
        continue
    }
    $svcResults = Test-ClientHealthy -RequiredServices $req
    $up = ($svcResults.Values | Where-Object { $_ -like 'up*' }).Count
    $down = ($svcResults.Values | Where-Object { $_ -like 'down*' }).Count
    $total = $req.Count
    $status = if ($up -eq $total) { "healthy" } elseif ($down -eq $total) { "down" } else { "degraded" }

    if (-not ($Quiet -or $PassThru)) {
        Write-Host "`n=== $($client.display_name) ===" -ForegroundColor Cyan
        Write-ClientReport -Client $client -Results $svcResults -RequiredCount $total -UpCount $up
    }

    if ($PassThru -or $Quiet) {
        $resultsOutput += [PSCustomObject]@{
            client = $client.name
            display = $client.display_name
            path = $client.path
            status = $status
            required = $req
            service_results = $svcResults
        }
    }
}

if ($PassThru -or $Quiet) {
    return $resultsOutput | ForEach-Object { $_ }
}
