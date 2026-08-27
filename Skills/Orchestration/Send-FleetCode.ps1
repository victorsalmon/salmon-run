<#
.SYNOPSIS
    Sends a prompt to the mcp_opencode fleet container for headless execution.
.DESCRIPTION
    Discovers the mcp_opencode container and dispatches a prompt via its REST
    session API (POST /session on port 21001). Works from inside the Docker
    network (Sentry) and from the host via docker inspect.

    Returns the session ID on success. Exits non-zero on failure.
.PARAMETER Prompt
    The prompt/task to execute in the mcp_opencode container. Mandatory.
.PARAMETER SessionOnly
    Return the session ID without waiting for completion.
.PARAMETER PassThru
    Return a PSCustomObject with SessionId, ExitCode, and Output instead of
    writing to host.
.EXAMPLE
    .\Send-FleetCode.ps1 "Alignment Audit"
.EXAMPLE
    .\Send-FleetCode.ps1 "RunFix deploy.ps1" -SessionOnly
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Prompt,

    [Parameter()]
    [switch]$SessionOnly,

    [Parameter()]
    [switch]$PassThru,

    [Parameter()]
    [string]$ContainerName = "mcp_opencode"
)

$ErrorActionPreference = "Stop"

function Get-Result {
    param([int]$ExitCode, [string]$Output, [string]$SessionId)
    if ($PassThru) {
        return [PSCustomObject]@{ ExitCode = $ExitCode; Output = $Output; SessionId = $SessionId }
    }
    if ($SessionId) { Write-Host "Session: $SessionId" }
    if ($Output) { Write-Host $Output }
    exit $ExitCode
}

# ——— Discovery ———

$baseUrl = $null
$discoveryMethod = "none"

# Detect if running inside a Docker container
$insideContainer = $false
if ($env:CONTAINER) {
    $insideContainer = $true
} elseif ((Test-Path "/proc/1/cgroup") -and (Get-Content "/proc/1/cgroup" -ErrorAction SilentlyContinue) -match "docker") {
    $insideContainer = $true
}

# Strategy 1: Docker DNS (primary — works both inside container and within Docker network)
try {
    $testUri = "http://${ContainerName}:21000/api/health"
    $health = Invoke-RestMethod -Uri $testUri -TimeoutSec 3 -ErrorAction Stop
    if ($health.status -in @("healthy", "starting")) {
        $baseUrl = "http://${ContainerName}:21001"
        $discoveryMethod = "docker-dns"
    }
} catch {
    $discoveryMethod = "host-search"
}

# When inside a container, Docker DNS is the only viable strategy — skip host-only fallbacks
if (-not $baseUrl -and -not $insideContainer) {
    # Strategy 2: From host — find container IP via docker inspect
    try {
        $containers = docker ps --filter "name=${ContainerName}" --format "{{.ID}}" 2>$null
        if ($containers) {
            $containerId = ($containers -split '\s+')[0]
            $networkIp = docker inspect $containerId --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>$null
            if ($networkIp) {
                $health = Invoke-RestMethod -Uri "http://${networkIp}:21000/api/health" -TimeoutSec 3 -ErrorAction Stop
                if ($health.status -in @("healthy", "starting")) {
                    $baseUrl = "http://${networkIp}:21001"
                    $discoveryMethod = "docker-inspect"
                }
            }
        }
    } catch {
        # Fall through
    }

    # Strategy 3: Try localhost if port is published
    if (-not $baseUrl) {
        try {
            $health = Invoke-RestMethod -Uri "http://localhost:21000/api/health" -TimeoutSec 2 -ErrorAction Stop
            if ($health.status -in @("healthy", "starting")) {
                $baseUrl = "http://localhost:21001"
                $discoveryMethod = "localhost"
            }
        } catch {
            # Fall through
        }
    }
}

if (-not $baseUrl) {
    $errorMsg = if ($insideContainer) { "Container-internal DNS resolution failed for '${ContainerName}'. Ensure the target service is running on the same Docker network." } else { "mcp_opencode container not found or unhealthy. Tried Docker DNS, docker inspect, and localhost." }
    Get-Result -ExitCode 1 -Output "ERROR: $errorMsg"
}

# ——— Dispatch ———

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDir "..\Skills\Docker\Modules\SalmonRun.Tempo\Private\Send-OpenCodeSession.ps1")

    $sessionId = New-OpenCodeSession
    if (-not $sessionId) {
        Get-Result -ExitCode 1 -Output "ERROR: mcp_opencode returned no session ID"
    }

    $accepted = Send-OpenCodePrompt -SessionId $sessionId -Prompt $Prompt
    $output = "Dispatched via $discoveryMethod | Session: $sessionId"

    if (-not $accepted) {
        $output += " | Prompt not accepted"
        Get-Result -ExitCode 1 -Output $output -SessionId $sessionId
    }

    if ($SessionOnly) {
        Get-Result -ExitCode 0 -Output $output -SessionId $sessionId
    }

    $pollAttempts = 0
    $maxPoll = 10
    while ($pollAttempts -lt $maxPoll) {
        Start-Sleep -Seconds 3
        $busy = Test-OpenCodeSessionBusy -SessionId $sessionId
        if ($busy -eq "idle") {
            $output += " | Completed"
            break
        }
        $pollAttempts++
    }
    if ($pollAttempts -ge $maxPoll) {
        $output += " | Session still running (polled ${maxPoll}x 3s)"
    }

    Remove-OpenCodeSession -SessionId $sessionId
    Get-Result -ExitCode 0 -Output $output -SessionId $sessionId

} catch {
    Get-Result -ExitCode 1 -Output "ERROR: Dispatch to mcp_opencode failed: $_"
}
