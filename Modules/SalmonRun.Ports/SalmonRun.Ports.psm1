#Requires -Version 7.0

Set-StrictMode -Off

$script:PortRegistryCache = $null

<#
.SYNOPSIS
    Loads and caches the port registry from port-registry.json in the repo root.
.OUTPUTS
    PSCustomObject or $null if not found.
#>
function Get-PortRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$RegistryPath
    )
    if ($script:PortRegistryCache) { return $script:PortRegistryCache }

    if (-not $RegistryPath) {
        $repoRoot = if (Get-Command Get-SalmonRunRepoRoot -ErrorAction SilentlyContinue) {
            Get-SalmonRunRepoRoot
        } elseif ($PSScriptRoot) {
            $tryPath = Join-Path $PSScriptRoot "..\.."
            if (Test-Path (Join-Path $tryPath ".git")) { Resolve-Path $tryPath } else { $null }
        } else { $null }
        if (-not $repoRoot) { $repoRoot = $env:REPO_ROOT }
        if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
        $RegistryPath = Join-Path $repoRoot "port-registry.json"
    }

    if (-not (Test-Path $RegistryPath)) {
        Write-SetupLog "Port registry not found at $RegistryPath -- using defaults" -Level WARN -Agent core -Phase init
        return $null
    }
    $script:PortRegistryCache = Get-Content $RegistryPath -Raw | ConvertFrom-Json
    return $script:PortRegistryCache
}

$script:PortDefaults = @{
    mcp_opencode_health = 21000
    mcp_opencode_server = 21001
    "is-fleet"          = 21002
    mcp_browserless     = 3003
    "is-bookkeeping"     = 21008
    "ops-funnel-proxy"  = 21009
    "is-marketer"       = 21011
    "is-monitoring"     = 21010
}

<#
.SYNOPSIS
    Resolves a service port from the port registry or fallback defaults.
.PARAMETER Service
     Service name (e.g. is-fleet).
.PARAMETER Type
    Port type: internal (container port) or host (published port).
.OUTPUTS
    System.Int32
#>
function Get-ServicePort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Service,
        [ValidateSet("internal", "host")]
        [string]$Type = "internal"
    )
    $registry = Get-PortRegistry
    if (-not $registry) {
        $default = $script:PortDefaults[$Service]
        if ($null -ne $default) {
            Write-SetupLog "Port registry not loaded -- using default for '$Service': $default" -Level WARN -Agent core -Phase init
            return $default
        }
        throw "Port registry not loaded and no default for '$Service'"
    }
    if ($Type -eq "internal") {
        $port = $registry.internal.$Service
    } else {
        $port = $registry.host.$Service
    }
    if ($null -eq $port) {
        throw "Service '$Service' not found in port registry (type: $Type)"
    }
    return [int]$port
}

# Port registry validation on module load
try {
    $reg = Get-PortRegistry
    if ($reg) {
        $internalPorts = $reg.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $duplicates = $internalPorts | Group-Object | Where-Object Count -gt 1
        if ($duplicates) {
            throw "Port registry collision: $($duplicates.Name -join ', ')"
        }
    }

    try {
        $null = Get-ServicePort -Service "is-fleet" -Type "internal"
    } catch {
        Write-SetupLog "Port registry validation skipped -- $($_.Exception.Message)" -Level DEBUG -Agent core -Phase init
    }
} catch {
    Write-SetupLog "Port registry validation deferred -- dependencies may not be available at module load" -Level DEBUG -Agent core -Phase init
}
