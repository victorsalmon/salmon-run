<#
.SYNOPSIS
    Lightweight deploy staleness checker — checks code, secrets, and pattern drift per container.
.DESCRIPTION
    Reads the deploy manifest, checks git for source changes, calls Fleet API endpoints for
    secret and pattern staleness, and outputs a decision table with recommended actions.

    Supports -Execute to apply recommendations and -Build to rebuild images first.
.PARAMETER Containers
    Comma-separated container names to check. Default: all containers from the deploy manifest.
.PARAMETER FleetUrl
    Fleet API base URL. Default: http://localhost:29999
.PARAMETER FleetToken
    Fleet API authentication token.
.PARAMETER Execute
    Apply recommended actions (refresh-secrets, redeploy).
.PARAMETER Build
    Rebuild images for code-stale containers before redeploying (requires -Execute).
.PARAMETER Phases
    Hashtable controlling which phases run: @{Check=$true; Build=$true; RefreshSecrets=$true; Redeploy=$true}
.PARAMETER Json
    Output results as JSON instead of a table.
.PARAMETER Csv
    Output results as CSV.
.PARAMETER WhatIf
    Show what would be done without doing it.
.PARAMETER LogPath
    Path to write the session log.
.EXAMPLE
    .\deploy-lite.ps1
    Check all containers and show decision table.
.EXAMPLE
    .\deploy-lite.ps1 -Execute -WhatIf
    Show planned actions without executing.
.EXAMPLE
    .\deploy-lite.ps1 -Execute -Build
    Rebuild and redeploy all stale containers.
.NOTES
    Requires: PowerShell 7+, git, Docker (for -Build), deploy-manifest.json in Tasks/Logs/
    Module dependencies: SalmonRun.Core, SalmonRun.Paths, SalmonRun.Deploy (for Get-ImageSourceHash)
#>

param(
    [string]$Containers = "",
    [string]$FleetUrl = "http://localhost:29999",
    [string]$FleetToken = "",
    [switch]$Execute,
    [switch]$Build,
    [hashtable]$Phases = @{},
    [switch]$Json,
    [switch]$Csv,
    [switch]$WhatIf,
    [string]$LogPath = "",
    [int]$FleetTimeoutSec = 30
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$PSNativeCommandArgumentPassing = 'Legacy'

# ==============================================================================
# Bootstrap: repo root detection and module loading
# ==============================================================================
$ScriptName = Split-Path -Leaf $PSCommandPath
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$__modulesDir = Join-Path $__ocRepoRoot "Skills" "Docker" "Modules"

if ($env:PSModulePath -notlike "*$__modulesDir*") {
    $env:PSModulePath = "$__modulesDir;$env:PSModulePath"
}
if (-not (Get-Module SalmonRun.Core)) {
    $__ocCorePsd1 = Join-Path $__modulesDir "SalmonRun.Core" "SalmonRun.Core.psd1"
    Import-Module -Name $__ocCorePsd1 -Force -DisableNameChecking
}

# Set up logging
$script:LogLines = [System.Collections.Generic.List[string]]::new()
$script:HadErrors = $false

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $script:LogLines.Add($line)
    if ($Level -eq "ERROR") { Write-Warning $Message }
    elseif ($Level -eq "WARN") { Write-Warning $Message }
    else { Write-Information -MessageData $Message -Tags $Level }
}

$script:FleetTimeoutSec = $FleetTimeoutSec

Write-Log "$ScriptName started"

# ==============================================================================
# Container-to-source-path mapping
# ==============================================================================
$script:ContainerSourcePaths = @{
    "is-fleet"         = @("Infrastructure/fleet.Dockerfile", "Infrastructure/fleet/", "Skills/Docker/Modules/SalmonRun.Fleet/")
}

# Container-to-bundle-type mapping for pattern staleness
$script:ContainerBundleTypes = @{
    "is-fleet"         = "Fleet"
}

# Startup validation: verify all container source paths exist
foreach ($__entry in $script:ContainerSourcePaths.GetEnumerator()) {
    $__paths = if ($__entry.Value -is [string]) { @($__entry.Value) } else { $__entry.Value }
    foreach ($__p in $__paths) {
        if (-not (Test-Path -LiteralPath $__p)) {
            Write-Log "Container '$($__entry.Key)': source path '$__p' does not exist on disk — staleness detection may be inaccurate." -Level WARN
        }
    }
}

# ==============================================================================
# Task 1: Load deploy manifest and determine git state
# ==============================================================================
function Get-DeployManifest {
    $manifestPath = Join-Path $__ocRepoRoot "Tasks" "Logs" "deploy-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Deploy manifest not found at $manifestPath. Run full deploy.ps1 first."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    return $manifest
}

function Get-GitState {
    $headCommit = & git rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to get HEAD commit: $headCommit" }
    $headBranch = & git rev-parse --abbrev-ref HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to get branch: $headBranch" }
    return @{
        Commit = $headCommit.Trim()
        Branch = $headBranch.Trim()
    }
}

# ==============================================================================
# Task 2: Check code staleness per container
# ==============================================================================
function Get-CodeStaleness {
    param(
        [string]$DeployCommit,
        [string[]]$ContainerList
    )
    $result = @{}
    foreach ($container in $ContainerList) {
        $paths = $script:ContainerSourcePaths[$container]
        if (-not $paths) {
            $paths = @("Infrastructure/$container/")
        }
        $filesChanged = @()
        foreach ($path in $paths) {
            $fullPath = Join-Path $__ocRepoRoot $path
            if (-not (Test-Path -LiteralPath $fullPath -ErrorAction SilentlyContinue)) { continue }
            $relativePath = $path -replace '\\', '/'
            $logOutput = & git log --oneline "$DeployCommit..HEAD" -- "$relativePath" 2>&1
            if ($LASTEXITCODE -eq 0 -and $logOutput) {
                $filesChanged += $logOutput.Trim()
            }
        }
        $codeStale = $filesChanged.Count -gt 0

        # Also compute current source hash for manifest comparison
        $hashResult = $null
        try {
            Import-InterclawModule Deploy -ErrorAction SilentlyContinue
            $dockerfilePath = $null
            $targetDir = $null
            $containerBuildInfo = @{
                "is-fleet"         = @("fleet.Dockerfile", "Infrastructure")
            }
            if ($containerBuildInfo.ContainsKey($container)) {
                $info = $containerBuildInfo[$container]
                $dockerfileName = $info[0]
                $targetRelDir = $info[1]
                $dockerfilePath = Join-Path $__ocRepoRoot $targetRelDir $dockerfileName
                $targetDir = Join-Path $__ocRepoRoot $targetRelDir
            }
            if ($dockerfilePath -and (Test-Path -LiteralPath $dockerfilePath)) {
                $hashResult = Get-ImageSourceHash -DockerfilePath $dockerfilePath -TargetDir $targetDir -ImageName $container
            }
        } catch {
            Write-Log "Could not compute source hash for $container`: $_" -Level WARN
        }

        $result[$container] = @{
            code_stale   = $codeStale
            files_changed = ($filesChanged -join "; ")
            source_hash  = $hashResult
        }
    }
    return $result
}

# ==============================================================================
# Task 3: Call Fleet staleness endpoints
# ==============================================================================
function Get-FleetToken {
    param([string]$Token)
    if ($Token) { return $Token }
    if ($env:FLEET_API_TOKEN) { return $env:FLEET_API_TOKEN }
    $tokenFile = Join-Path $env:USERPROFILE ".ORCHESTRATOR" "fleet-api-token.txt"
    if (Test-Path -LiteralPath $tokenFile) {
        return (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
    return $null
}

function Invoke-FleetApi {
    param(
        [string]$Url,
        [string]$Method = "POST",
        [object]$Body = $null,
        [string]$Token,
        [int]$TimeoutSec = $script:FleetTimeoutSec
    )
    $params = @{
        Uri             = $Url
        Method          = $Method
        ContentType     = "application/json"
        ErrorAction     = "Stop"
        SkipCertificateCheck = $true
        TimeoutSec      = $TimeoutSec
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Compress -Depth 5) }
    if ($Token) { $params.Headers = @{ Authorization = "Bearer $Token" } }
    try {
        return Invoke-RestMethod @params
    } catch {
        $endpointLabel = ($Url -split '\?')[0]
        throw "Fleet API unreachable at $endpointLabel — is the fleet service running? ($($_.Exception.Message))"
    }
}

function Get-FleetStaleness {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [string]$DeployCommit,
        [string[]]$ContainerList,
        [hashtable]$ExpectedHashes
    )
    $endpoint = "$BaseUrl/api/deploy/check-staleness"
    $body = @{
        containers        = $ContainerList
        deploy_git_commit = $DeployCommit
        expected_hashes   = $ExpectedHashes
    }
    try {
        $result = Invoke-FleetApi -Url $endpoint -Method POST -Body $body -Token $Token
        return $result
    } catch {
        Write-Log "check-staleness endpoint unavailable ($($_.Exception.Message)), falling back to check-freshness" -Level WARN
        try {
            $freshnessEndpoint = "$BaseUrl/api/secret/check-freshness"
            $freshBody = @{ containers = $ContainerList }
            $freshResult = Invoke-FleetApi -Url $freshnessEndpoint -Method POST -Body $freshBody -Token $Token
            return @{ staleness = $null; freshness = $freshResult }
        } catch {
            Write-Log "check-freshness also unavailable: $($_.Exception.Message)" -Level ERROR
            return $null
        }
    }
}

# ==============================================================================
# Task 4: Compute pattern drift from git diff of bundle-manifest.ps1
# ==============================================================================
function Get-PatternDrift {
    param(
        [string]$DeployCommit,
        [string[]]$ContainerList
    )
    $result = @{}
    $manifestPath = "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1"
    $fullPath = Join-Path $__ocRepoRoot ($manifestPath -replace '/', '\')

    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-Log "bundle-manifest.ps1 not found at $fullPath" -Level WARN
        foreach ($c in $ContainerList) { $result[$c] = @{ pattern_changed = $false; added_keys = @(); removed_keys = @() } }
        return $result
    }

    $headManifest = Get-Content -LiteralPath $fullPath -Raw
    $deployManifest = & git show "$DeployCommit`:$manifestPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Could not load deploy-commit manifest (git show $DeployCommit`:$manifestPath): $deployManifest" -Level WARN
        foreach ($c in $ContainerList) { $result[$c] = @{ pattern_changed = $false; added_keys = @(); removed_keys = @() } }
        return $result
    }

    # Extract SourceKeys per bundle type using simple regex
    function Get-SourceKeysFromManifest {
        param([string]$Content, [string]$BundleType)
        $pattern = "(?s)$BundleType\s*=\s*@\{.*?SourceKeys\s*=\s*@\(([^)]*)\).*?\}"
        $match = [regex]::Match($Content, $pattern)
        if (-not $match.Success) { return @() }
        $keysStr = $match.Groups[1].Value
        $keys = [regex]::Matches($keysStr, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        return $keys
    }

    foreach ($container in $ContainerList) {
        $bundleType = $script:ContainerBundleTypes[$container]
        if (-not $bundleType) {
            $result[$container] = @{ pattern_changed = $false; added_keys = @(); removed_keys = @() }
            continue
        }

        $headKeys = Get-SourceKeysFromManifest -Content $headManifest -BundleType $bundleType
        $deployKeys = Get-SourceKeysFromManifest -Content $deployManifest -BundleType $bundleType

        $headSet = [System.Collections.Generic.HashSet[string]]::new([string]::CompareOrdinal)
        $deploySet = [System.Collections.Generic.HashSet[string]]::new([string]::CompareOrdinal)
        foreach ($k in $headKeys) { $null = $headSet.Add($k) }
        foreach ($k in $deployKeys) { $null = $deploySet.Add($k) }

        $addedKeys = $headSet | Where-Object { -not $deploySet.Contains($_) }
        $removedKeys = $deploySet | Where-Object { -not $headSet.Contains($_) }
        $patternChanged = ($addedKeys.Count -gt 0) -or ($removedKeys.Count -gt 0)

        $result[$container] = @{
            pattern_changed = $patternChanged
            added_keys      = @($addedKeys)
            removed_keys    = @($removedKeys)
        }
    }
    return $result
}

# ==============================================================================
# Task 5: Build decision table
# ==============================================================================
function Build-DecisionTable {
    param(
        [hashtable]$CodeStaleness,
        $FleetStaleness,
        [hashtable]$PatternDrift,
        [string[]]$ContainerList
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($container in $ContainerList) {
        $code = $CodeStaleness[$container]
        $codeStale = $code -and $code.code_stale
        $sourceHash = if ($code) { $code.source_hash } else { $null }

        # Determine secret staleness from Fleet response
        $secretsStale = $false
        if ($FleetStaleness -and $FleetStaleness.staleness -and $FleetStaleness.staleness.$container) {
            $secretsStale = $FleetStaleness.staleness.$container.secrets_stale -eq $true
        } elseif ($FleetStaleness -and $FleetStaleness.freshness -and $FleetStaleness.freshness.$container) {
            $secretsStale = $FleetStaleness.freshness.$container.fresh -ne $true
        }

        $pattern = $PatternDrift[$container]
        $patternChanged = $pattern -and $pattern.pattern_changed

        # Determine action
        $actions = @()
        if ($codeStale) { $actions += "redeploy" }
        if ($secretsStale -or $patternChanged) { $actions += "refresh-secrets" }
        if ($actions.Count -eq 0) { $actions += "skip" }

        $actionStr = $actions -join " + "
        if ($codeStale) { $actionStr += " (build required)" }

        $row = @{
            Container      = $container
            Code           = if ($codeStale) { "STALE" } else { "OK" }
            Secrets        = if ($secretsStale) { "STALE" } else { "OK" }
            Pattern        = if ($patternChanged) { "CHANGED" } else { "OK" }
            Action         = $actionStr
            FilesChanged   = if ($code) { $code.files_changed } else { "" }
            AddedKeys      = if ($pattern) { $pattern.added_keys -join ", " } else { "" }
            RemovedKeys    = if ($pattern) { $pattern.removed_keys -join ", " } else { "" }
        }
        $rows.Add($row)
    }
    return $rows
}

# ==============================================================================
# Task 6: Implement -Execute flag
# ==============================================================================
function Invoke-RefreshSecrets {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [string[]]$ContainersToRefresh
    )
    if ($ContainersToRefresh.Count -eq 0) { return }
    $endpoint = "$BaseUrl/api/secret/refresh-containers"
    $body = @{ containers = $ContainersToRefresh }
    Write-Log "Refreshing secrets for: $($ContainersToRefresh -join ', ')"
    if ($WhatIf) { Write-Log "  [WHATIF] Would call $endpoint"; return }
    try {
        $result = Invoke-FleetApi -Url $endpoint -Method POST -Body $body -Token $Token
        Write-Log "Secrets refresh completed"
    } catch {
        Write-Log "Secrets refresh failed: $($_.Exception.Message)" -Level ERROR
        $script:HadErrors = $true
    }
}

function Invoke-Redeploy {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [string[]]$ContainersToRedeploy
    )
    if ($ContainersToRedeploy.Count -eq 0) { return }
    $endpoint = "$BaseUrl/api/deploy/redeploy-containers"
    $body = @{ containers = $ContainersToRedeploy }
    Write-Log "Redeploying: $($ContainersToRedeploy -join ', ')"
    if ($WhatIf) { Write-Log "  [WHATIF] Would call $endpoint"; return }
    try {
        $result = Invoke-FleetApi -Url $endpoint -Method POST -Body $body -Token $Token
        Write-Log "Redeploy completed"
    } catch {
        Write-Log "Redeploy failed: $($_.Exception.Message)" -Level ERROR
        $script:HadErrors = $true
    }
}

# ==============================================================================
# Task 7: Image build support
# ==============================================================================
function Invoke-ImageBuild {
    param([string[]]$ContainersToBuild)
    if ($ContainersToBuild.Count -eq 0) { return }

    Import-InterclawModule Images -ErrorAction SilentlyContinue
    if (-not (Get-Command Invoke-FleetImageBuild -ErrorAction SilentlyContinue)) {
        Write-Log "SalmonRun.Images module not available, cannot build images" -Level ERROR
        return
    }

    $buildMap = @{
        "is-fleet"         = "Invoke-FleetImageBuild"
    }

    foreach ($container in $ContainersToBuild) {
        $cmdName = $buildMap[$container]
        if (-not $cmdName) {
            Write-Log "No build function mapped for $container" -Level WARN
            continue
        }
        try {
            $func = Get-Command $cmdName -ErrorAction SilentlyContinue
            if (-not $func) {
                Write-Log "Build function $cmdName not found" -Level WARN
                continue
            }
            Write-Log "Building image for $container..."
            if ($WhatIf) { Write-Log "  [WHATIF] Would invoke $cmdName"; continue }
            & $func
            Write-Log "Image build for $container completed"
        } catch {
            Write-Log "Image build for $container failed: $($_.Exception.Message)" -Level ERROR
            $script:HadErrors = $true
        }
    }
}

# ==============================================================================
# Main execution
# ==============================================================================
try {
    # Resolve phases
    $defaultPhases = @{ Check = $true; Build = $false; RefreshSecrets = $false; Redeploy = $false }
    if ($Execute) {
        if (-not $Build -and -not $Phases.RefreshSecrets -and -not $Phases.Redeploy) { $Build = $true }
        $defaultPhases = @{ Check = $true; Build = $Build; RefreshSecrets = $true; Redeploy = $true }
    }
    if ($Phases.Count -gt 0) { $defaultPhases = $Phases }
    if (-not $defaultPhases.Check) {
        Write-Log "Check phase disabled, nothing to do" -Level WARN
        return
    }

    # Load deploy manifest
    Write-Log "Loading deploy manifest..."
    $manifest = Get-DeployManifest
    $deployCommit = $manifest.deploy_commit
    $manifestContainers = $manifest.containers.PSObject.Properties.Name

    # Resolve container list
    $containerList = if ($Containers) {
        $Containers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    } else { $manifestContainers }

    if ($containerList.Count -eq 0) {
        Write-Log "No containers to check" -Level WARN
        return
    }

    Write-Log "Deploy commit: $deployCommit"
    Write-Log "Containers to check: $($containerList -join ', ')"

    # Get git state
    Write-Log "Checking git state..."
    $gitState = Get-GitState
    Write-Log "Current HEAD: $($gitState.Commit) ($($gitState.Branch))"
    if ($gitState.Commit -eq $deployCommit) {
        Write-Log "HEAD matches deploy commit — no code changes since deploy" -Level WARN
    }

    # Step 1: Check code staleness
    Write-Log "Checking code staleness..."
    $codeStaleness = Get-CodeStaleness -DeployCommit $deployCommit -ContainerList $containerList

    # Step 2: Check Fleet staleness
    $fleetToken = Get-FleetToken -Token $FleetToken
    if ($fleetToken) {
        Write-Log "Fleet API token found, calling Fleet endpoints..."
    } else {
        Write-Log "No Fleet API token available, trying without auth" -Level WARN
    }

    $expectedHashes = @{}
    foreach ($c in $containerList) {
        if ($codeStaleness[$c] -and $codeStaleness[$c].source_hash) {
            $expectedHashes[$c] = $codeStaleness[$c].source_hash
        }
    }

    # Fleet health pre-check before calling staleness endpoints
    try {
        $healthResult = Invoke-WebRequest -Uri "$FleetUrl/api/health" -Method GET -TimeoutSec $script:FleetTimeoutSec -SkipCertificateCheck -ErrorAction SilentlyContinue
        if ($healthResult.StatusCode -ne 200) { throw "Health endpoint returned $($healthResult.StatusCode)" }
    } catch {
        Write-Log "Fleet API unreachable at $FleetUrl/api/health — is the fleet service running? ($($_.Exception.Message)) — secrets and pattern will show UNKNOWN" -Level WARN
    }

    $fleetResult = Get-FleetStaleness -BaseUrl $FleetUrl -Token $fleetToken -DeployCommit $deployCommit -ContainerList $containerList -ExpectedHashes $expectedHashes

    # Step 3: Check pattern drift
    Write-Log "Checking pattern drift..."
    $patternDrift = Get-PatternDrift -DeployCommit $deployCommit -ContainerList $containerList

    # Step 4: Build decision table
    Write-Log "Building decision table..."
    $rows = Build-DecisionTable -CodeStaleness $codeStaleness -FleetStaleness $fleetResult -PatternDrift $patternDrift -ContainerList $containerList

    # Output
    $tableData = $rows | ForEach-Object {
        [PSCustomObject]@{
            Container    = $_.Container
            Code         = $_.Code
            Secrets      = $_.Secrets
            Pattern      = $_.Pattern
            Action       = $_.Action
        }
    }

    if ($Json) {
        $tableData | ConvertTo-Json -Depth 3
    } elseif ($Csv) {
        $tableData | ConvertTo-Csv -NoTypeInformation
    } else {
        $tableData | Format-Table -AutoSize
    }

    # Show details for stale containers
    $staleContainers = $rows | Where-Object { $_.Action -ne "skip" }
    if ($staleContainers.Count -gt 0) {
        Write-Log "Detailed changes:" -Level WARN
        foreach ($row in $staleContainers) {
            if ($row.FilesChanged) { Write-Log "  $($row.Container) files: $($row.FilesChanged)" -Level WARN }
            if ($row.AddedKeys) { Write-Log "  $($row.Container) added keys: $($row.AddedKeys)" -Level WARN }
            if ($row.RemovedKeys) { Write-Log "  $($row.Container) removed keys: $($row.RemovedKeys)" -Level WARN }
        }
    }

    # ==========================================================================
    # Execute phase
    # ==========================================================================
    if ($defaultPhases.Build -or $defaultPhases.RefreshSecrets -or $defaultPhases.Redeploy) {
        $containersNeedingBuild = @($rows | Where-Object { $_.Code -eq "STALE" } | ForEach-Object { $_.Container })
        $containersNeedingRefresh = @($rows | Where-Object { $_.Action -match "refresh-secrets" } | ForEach-Object { $_.Container })
        $containersNeedingRedeploy = @($rows | Where-Object { $_.Action -match "redeploy" } | ForEach-Object { $_.Container })

        if ($defaultPhases.Build -and $containersNeedingBuild.Count -gt 0) {
            Write-Log "=== Phase: Build images ==="
            Invoke-ImageBuild -ContainersToBuild $containersNeedingBuild
        }

        if ($defaultPhases.RefreshSecrets -and $containersNeedingRefresh.Count -gt 0) {
            Write-Log "=== Phase: Refresh secrets ==="
            Invoke-RefreshSecrets -BaseUrl $FleetUrl -Token $fleetToken -ContainersToRefresh $containersNeedingRefresh
        }

        if ($defaultPhases.Redeploy -and $containersNeedingRedeploy.Count -gt 0) {
            Write-Log "=== Phase: Redeploy ==="
            Invoke-Redeploy -BaseUrl $FleetUrl -Token $fleetToken -ContainersToRedeploy $containersNeedingRedeploy
        }
    }

    if ($script:HadErrors) {
        Write-Log "$ScriptName completed with errors" -Level ERROR
        exit 1
    }
    Write-Log "$ScriptName completed"
} catch {
    Write-Log "Fatal error: $_" -Level ERROR
    Write-Error $_
    exit 1
} finally {
    # Write log file
    if (-not $LogPath) {
        $logDir = Join-Path $__ocRepoRoot "Tasks" "Logs"
        $null = New-Item -ItemType Directory -Path $logDir -Force
        $LogPath = Join-Path $logDir "deploy-lite-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    }
    $script:LogLines | Out-File -LiteralPath $LogPath -Encoding utf8
    Write-Log "Log written to $LogPath"
}
