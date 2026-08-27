<#
.SYNOPSIS
    Generates fleet compose and deploys the Docker Swarm stack.
.DESCRIPTION
    Calls Generate-FleetCompose, deploys via docker stack deploy, runs pre-flight
    secret verification, waits for stack stabilization, and cleans up stale
    volumes and images. Optionally skips deploy with -SkipDeploy.
.PARAMETER SkipDeploy
    Generate compose file but do not deploy the stack.
.OUTPUTS
    None.
#>
function Publish-FleetStack {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for Docker Swarm secrets')]
    [CmdletBinding(DefaultParameterSetName = 'Individual')]
    [OutputType([void])]
    param(
        [switch]$SkipDeploy,
        [string]$TargetDir,
        [array]$AgentConfigs,
        [string]$ProjectCode,
        [string]$StackName,
        [Parameter(ParameterSetName = 'OptionsObject')]
        [PSCustomObject]$DeployOptions,
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallTailscale = "true",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallFleet = "true",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallWorkspaceRepos = "",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallBrowserless = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallBookkeeping = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallMarketer = "false",
        [Parameter(ParameterSetName = 'Individual')]
        [string]$InstallHermes = "false",
        [string]$InstallAqe = "true",
        [string]$InstallMonitoring = "false",
        [string]$SovereigntyTier = "global",
        [string]$ImageVersion = "local",
        [switch]$PreserveFleet
    )
Set-StrictMode -Off
    if (-not $script:StackName -and -not $StackName) {
        throw "Deploy state not initialized. Call Invoke-InterclawDeployment first."
    }
    if ($PSCmdlet.ParameterSetName -eq 'OptionsObject' -and $DeployOptions) {
        $InstallTailscale = $DeployOptions.InstallTailscale
        $InstallFleet = $DeployOptions.InstallFleet
        $InstallWorkspaceRepos = $DeployOptions.InstallWorkspaceRepos
        $InstallBrowserless = $DeployOptions.InstallBrowserless
        $InstallBookkeeping = $DeployOptions.InstallBookkeeping
        $InstallMarketer = if ($DeployOptions.PSObject.Properties.Match('InstallMarketer')) { $DeployOptions.InstallMarketer } else { $InstallMarketer }
        $InstallHermes = if ($DeployOptions.PSObject.Properties.Match('InstallHermes')) { $DeployOptions.InstallHermes } else { $InstallHermes }
        $InstallAqe = $DeployOptions.InstallAqe
        $InstallMonitoring = $DeployOptions.InstallMonitoring
    }
    # Backward compatibility: use script scope if parameter not provided
    if (-not $PSBoundParameters.ContainsKey('StackName')) { $StackName = $script:StackName }
    if (-not $PSBoundParameters.ContainsKey('TargetDir')) { $TargetDir = (Get-InterclawRepoRoot) }
    if (-not $PSBoundParameters.ContainsKey('AgentConfigs')) { $AgentConfigs = $script:AgentConfigs }
    if (-not $PSBoundParameters.ContainsKey('ProjectCode')) { $ProjectCode = $script:ProjectCode }
    if (-not $PSBoundParameters.ContainsKey('SovereigntyTier')) { $SovereigntyTier = $script:SovereigntyTier }
    if ($PSBoundParameters.ContainsKey('PreserveFleet')) { $env:INTERCLAW_PRESERVE_FLEET = if ($PreserveFleet) { "true" } else { "false" } }

    # Helper: the bundle manifest's EnvMap is keyed by the bundle's canonical
    # (often lowercase) key and valued by the env var / AWS SM name. This maps
    # a source key back to the bundle key so Set-ContainerSecretBundle stores
    # entries in the schema's expected shape.
    function Resolve-BundleKeyFromEnvMap {
        param([string]$SourceKey, [hashtable]$EnvMap)
        if ($EnvMap) {
            foreach ($pair in $EnvMap.GetEnumerator()) {
                if ($pair.Value -eq $SourceKey) { return $pair.Key }
            }
        }
        return $SourceKey
    }

$SsoProfile = $env:AWS_SSO_PROFILE
Write-SetupLog "Phase 5: Generating fleet compose and deploying Docker stack"
$TotalServices = $AgentConfigs.Count
Write-Verbose "`n[FleetCompose] Generating fleet compose ($TotalServices agents)..."

$newFleetComposeParams = @{
    Agents = $AgentConfigs; ProjectCode = $ProjectCode; InstallTailscale = $InstallTailscale; InstallFleet = $InstallFleet; InstallWorkspaceRepos = $InstallWorkspaceRepos; InstallBrowserless = $InstallBrowserless; InstallBookkeeping = $InstallBookkeeping; InstallMarketer = $InstallMarketer; InstallHermes = $InstallHermes; InstallAqe = $InstallAqe; InstallMonitoring = $InstallMonitoring; OutputPath = (Join-Path $TargetDir "Infrastructure/docker-compose.interclaw.yml"); SovereigntyTier = $SovereigntyTier; BundleManifest = (Get-BundleManifest); BundleNameFleet = ((Get-BundleManifest).Fleet.BundleName); BookkeepingBundleName = (Get-BookkeepingBundleName); BookkeepingBundleSuffix = (Get-BookkeepingBundleSuffix); PreserveFleet = $PreserveFleet
}
$FleetComposePath = New-FleetCompose @newFleetComposeParams
Write-Verbose "  [OK] Fleet compose generated: $FleetComposePath"`

    if ($SkipDeploy) {
        Write-SetupLog "Phase 5 (compose generation only) complete"
        return
    }

Write-Verbose "`n[FleetDeploy] Deploying Interclaw Stack: $StackName..."

# Set per-agent env vars for compose variable substitution (first agent for compat)
$FirstAgent = $AgentConfigs[0]
Set-Item -Path "Env:\INTERCLAW_AGENT_NAME" -Value $FirstAgent.AgentName
Set-Item -Path "Env:\HOST_PORT_GATEWAY" -Value "$(Get-AgentHostPort -Role $FirstAgent.Role -Index $FirstAgent.Index)"
$baseImage = (Get-InterclawConstants).InterclawImage
Set-Item -Path "Env:\ORCHESTRATOR_IMAGE" -Value $baseImage
Set-Item -Path "Env:\ORCHESTRATOR_FLEET_IMAGE" -Value "fleet:$ImageVersion"

# Pre-deploy: remove existing stack BEFORE rotating Swarm secrets. Bundle secrets
# (Bookkeeper, web_mcp, hermes, etc.) cannot be updated while in use by a running
# service. Removing the stack first makes Set-SwarmSecretSafe rotations safe.
if ($env:INTERCLAW_PRESERVE_FLEET -eq "true" -or $PreserveFleet) {
    Write-Verbose "  [PREFLIGHT] PreserveFleet enabled - skipping early stack removal"
    Write-SetupLog "Pre-deploy: early stack removal skipped (PreserveFleet)"
} else {
    $EarlyStackLs = Invoke-NativeCommand { docker stack ls --format "{{.Name}}" 2>$null }
    $EarlyStackExists = if ($EarlyStackLs.Success) { ($EarlyStackLs.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $StackName }) } else { $null }
    if ($EarlyStackExists) {
        Write-Verbose "  [PREFLIGHT] Removing existing stack '$StackName' before secret rotation..."
        Write-SetupLog "Pre-deploy: removing existing stack $StackName before secret rotation"
        $null = Invoke-NativeCommand { docker stack rm $StackName 2>&1 }
        $RemovalTimeout = 60
        $RemovalElapsed = 0
        while ($RemovalElapsed -lt $RemovalTimeout) {
            $RemainResult = Invoke-NativeCommand { docker stack ls --format "{{.Name}}" 2>$null }
            $Remaining = if ($RemainResult.Success) { ($RemainResult.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $StackName }) } else { $null }
            if (-not $Remaining) { break }
            Start-Sleep -Seconds 2
            $RemovalElapsed += 2
        }
        if ($RemovalElapsed -ge $RemovalTimeout) {
            Write-SetupLog "WARN: Early stack $StackName removal timed out after ${RemovalTimeout}s - proceeding" -Level WARN
            Write-Verbose "  [WARN] Early stack removal timed out - proceeding anyway."
        } else {
            Write-Verbose "  [OK] Existing stack '$StackName' removed before secret rotation (${RemovalElapsed}s)."
            Write-SetupLog "Pre-deploy: existing stack $StackName removed before secret rotation (${RemovalElapsed}s)"
        }
        Start-Sleep -Seconds 3
    }
}

# docker stack deploy --prune handles old service/network removal automatically.
# Ensure all referenced Docker Swarm secrets exist before deploy.
# For Global tier, optional provider keys (openrouter, minimax) may not have been
# created by 1Secrets.ps1 if the env var was empty. Create placeholder secrets
# so the compose file's external secret references don't fail.
# Global tier secrets are bundled in per-agent secret bundles
# (created during provisioning in New-AgentIamUser). The pre-flight
# verification below validates all compose-level secrets exist.

# Create ATTIO_READ_KEY Swarm secret from AWS Secrets Manager (mounted on all agents for CRM lookup)
$AttioReadKey = Get-SecretFromAws -KeyName "ATTIO_READ_KEY"
if (-not [string]::IsNullOrWhiteSpace($AttioReadKey)) {
    Set-SwarmSecretSafe -SecretName "ATTIO_READ_KEY" -SecretValue (ConvertTo-SecureString $AttioReadKey -AsPlainText -Force) -Label "attio_read_key"
    Write-Verbose "  [OK] Created ATTIO_READ_KEY secret from AWS Secrets Manager."
    Write-SetupLog "Created ATTIO_READ_KEY secret from AWS Secrets Manager"
}
else {
    # Safe probe: empty output means the secret does not exist yet - absence is a valid state handled by the caller.
    $AttioReadExists = Invoke-Docker secret ls --filter name=ATTIO_READ_KEY -q 2>$null
    if ([string]::IsNullOrWhiteSpace($AttioReadExists)) {
        Write-Verbose "  [WARN] ATTIO_READ_KEY not found in AWS SM or Swarm - BASE will not have Attio read access."
        Write-SetupLog "ATTIO_READ_KEY not found in AWS SM or Swarm" -Level WARN
    }
    else {
        Write-Verbose "  [OK] ATTIO_READ_KEY Swarm secret exists."
        Write-SetupLog "ATTIO_READ_KEY Swarm secret exists"
    }
}

# Create a single proxy secrets bundle instead of individual secrets
Write-Verbose "  [PROXY] Creating proxy secrets bundle..."
$ProxyManifest = (Get-BundleManifest).Proxy
if (-not $ProxyManifest) { throw "Publish-FleetStack: Proxy manifest not found - Secrets module failed to load" }
$ProxySecretKeys = $ProxyManifest.SourceKeys + @("PROXY_AWS_ACCESS_KEY_ID", "PROXY_AWS_SECRET_ACCESS_KEY")

$ProxyBundleEntries = @{}
$ProxyMissing = @()
# Map env var names to canonical schema suffix; keys not in the map retain their original casing
$ProxyKeyToSuffixMap = @{
    "ATTIO_READ_KEY"           = "ATTIO_READ_KEY"
    "ATTIO_WRITE_KEY"          = "attio_write_key"
    "ATTIO_ARCHIVE_KEY"        = "attio_archive_key"
    "APOLLO_SEARCH"            = "apollo_search"
    "APOLLO_ENRICH"            = "apollo_enrich"
    "ZEROBOUNCE_API_KEY"       = "zerobounce_api_key"
    "BROWSERLESS_API_KEY"      = "browserless_api_key"
    "SMARTLEAD_API_KEY"        = "SMARTLEAD_API_KEY"
    "PROXY_AWS_ACCESS_KEY_ID"  = "proxy_aws_id"
    "PROXY_AWS_SECRET_ACCESS_KEY" = "proxy_aws_secret"
    "HUNTER_API_KEY"           = "HUNTER_API_KEY"
    "OPENROUTER_API_KEY"       = "openrouter_api_key"
    "GCP_SERVICE_SECRET"       = "gcp_service_secret"
    "GDRIVE_FOLDER_ID"         = "gdrive_folder_id"
    "GDRIVE_FOLDER_NAME"       = "gdrive_folder_name"
    "WAVE_CLIENT_ID"           = "wave_client_id"
    "WAVE_CLIENT_SECRET"       = "wave_client_secret"
    "WAVE_ACCESS_TOKEN"        = "wave_access_token"
    "WAVE_ORG_ID1"             = "wave_org_id1"
    "WAVE_ORG_NAME1"           = "wave_org_name1"
    "WAVE_ORG_ID2"             = "wave_org_id2"
    "WAVE_ORG_NAME2"           = "wave_org_name2"
    "ZOHO_BOOKS_ID"            = "ZOHO_BOOKS_ID"
    "ZOHO_BOOKS_SECRET"        = "ZOHO_BOOKS_SECRET"
    "ZOHO_BOOKS_REFRESH"       = "ZOHO_BOOKS_REFRESH"
}
foreach ($ProxyKey in $ProxySecretKeys) {
    $ProxyValue = Get-Item -Path "Env:\$ProxyKey" -ErrorAction SilentlyContinue
    if ($null -ne $ProxyValue) {
        $ProxyValue = $ProxyValue.Value
    }
    if ([string]::IsNullOrWhiteSpace($ProxyValue)) {
        $ProxyValue = Get-SecretFromAws -KeyName $ProxyKey
    }
    # Second fallback: Docker Swarm secrets (for IAM-generated proxy keys)
    if ([string]::IsNullOrWhiteSpace($ProxyValue) -and $ProxyKeyToSuffixMap.ContainsKey($ProxyKey)) {
        $SwarmKey = $ProxyKeyToSuffixMap[$ProxyKey]
        # Safe probe: empty output means the secret does not exist yet - absence is a valid state handled by the caller.
        $secretId = Invoke-Docker secret ls --filter name=$SwarmKey -q 2>$null | Select-Object -First 1
        if ($secretId) {
            # Safe swallow: Invoke-NativeCommand captures exit code via .Success; stderr is discarded to avoid polluting captured output.
            $result = Invoke-NativeCommand { docker run --rm -v "${SwarmKey}:/tmp/secret" alpine:latest cat /tmp/secret 2>$null }
            if ($result.Success -and $result.Output) {
                $ProxyValue = $result.Output
                Write-Verbose "  [OK] $ProxyKey resolved from Docker Swarm secret $SwarmKey"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ProxyValue)) {
        $SwarmKey = if ($ProxyKeyToSuffixMap.ContainsKey($ProxyKey)) { $ProxyKeyToSuffixMap[$ProxyKey] } else { $ProxyKey }
        $ProxyBundleEntries[$SwarmKey] = $ProxyValue
    }
    else {
        $ProxyMissing += $ProxyKey
    }
}
if ($ProxyBundleEntries.Count -gt 0) {
    $ProxyBundleName = (Get-BundleManifest).Proxy.BundleName
    if (-not $ProxyBundleName) { throw "Publish-FleetStack: Proxy.BundleName not set - Secrets module failed to load" }
    $null = Set-ContainerSecretBundle -BundleName $ProxyBundleName -Entries $ProxyBundleEntries -Label "proxy_secrets_bundle"
    Write-Verbose "  [OK] Proxy bundle created: $ProxyBundleName ($($ProxyBundleEntries.Count) entries)"
    Write-SetupLog "Proxy bundle created: $ProxyBundleName ($($ProxyBundleEntries.Count) entries)"
}
if ($ProxyMissing.Count -gt 0) {
    Write-Verbose "  [WARN] $($ProxyMissing.Count) proxy secret(s) not found in AWS SM: $($ProxyMissing -join ', ') - proxy will start degraded."
    Write-SetupLog "Proxy secrets missing from AWS SM: $($ProxyMissing -join ', ')" -Level WARN
}

# Create Bookkeeper secrets bundle (GoCardless reconciliation only; Plaid disabled)
if ($InstallBookkeeping -eq "true") {
    Write-Verbose "  [bookkeeping] Creating Bookkeeper secrets bundle..."
    $BookkeeperManifest = (Get-BundleManifest).Bookkeeper
    if (-not $BookkeeperManifest) { throw "Publish-FleetStack: Bookkeeper manifest not found" }
    $BookkeeperSecretKeys = $BookkeeperManifest.SourceKeys
    $BookkeeperBundleEntries = @{}
    $BookkeeperMissing = @()
    foreach ($Key in $BookkeeperSecretKeys) {
        $Value = Get-SecretFromAws -KeyName $Key
        # Fallback: the canonical AWS SM key for the fleet-wide model key is
        # OPENROUTER_ORCH_KEY; expose it inside the bundle as OPENROUTER_API_KEY
        # so container consumers (Bookkeeper handlers, vision OCR) find the
        # expected env var.
        if ([string]::IsNullOrWhiteSpace($Value) -and $Key -eq 'OPENROUTER_API_KEY') {
            $Value = Get-SecretFromAws -KeyName 'OPENROUTER_ORCH_KEY'
        }
        $BundleKey = Resolve-BundleKeyFromEnvMap -SourceKey $Key -EnvMap $BookkeeperManifest.EnvMap
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $BookkeeperBundleEntries[$BundleKey] = $Value
        } else {
            $BookkeeperMissing += $Key
        }
    }
    $null = Set-ContainerSecretBundle -BundleName "bookkeeping_secrets_bundle" -Entries $BookkeeperBundleEntries -Label "bookkeeping_secrets_bundle"
    Write-Verbose "  [OK] Bookkeeper bundle created: bookkeeping_secrets_bundle ($($BookkeeperBundleEntries.Count) entries)"
    Write-SetupLog "Bookkeeper bundle created: bookkeeping_secrets_bundle ($($BookkeeperBundleEntries.Count) entries)"
    if ($BookkeeperMissing.Count -gt 0) {
        Write-Verbose "  [WARN] $($BookkeeperMissing.Count) Bookkeeper secret(s) not found in AWS SM: $($BookkeeperMissing -join ', ') - deploy may be degraded"
        Write-SetupLog "Bookkeeper secrets missing from AWS SM: $($BookkeeperMissing -join ', ')" -Level WARN
    }

    # Hydrate Bookkeeper env vars for compose variable substitution
    $BookkeeperEnvVars = @("GOCARDLESS_PAY_READ", "GOCARDLESS_PAY_RW",
        "RECEIPTS_INTERSITE_EMAIL", "RECEIPTS_INTERSITE_PASS",
        "RECEIPTS_RENTALS_EMAIL", "RECEIPTS_RENTALS_PASS",
        "CLOUDTAX_INTERSITE_T2_URL",
        "ZOHO_BOOKS_ROOMRENTALS_TD", "ZOHO_BOOKS_ROOMRENTALS_RBC",
        "ZOHO_BOOKS_ROOMRENTALS_SCOTIA",         "ZOHO_BOOKS_ROOMRENTALS_VISA",
        "ZOHO_BOOKS_INTERSITE_RBC", "ZOHO_BOOKS_INTERSITE_6258",
        "INTERSITE_HOME_DEPOT_EMAIL", "INTERSITE_HOME_DEPOT_PASSWORD")
    foreach ($VarName in $BookkeeperEnvVars) {
        $ExistingVar = Get-Item -Path "Env:\$VarName" -ErrorAction SilentlyContinue
        if ($null -eq $ExistingVar -or [string]::IsNullOrWhiteSpace($ExistingVar.Value)) {
            $VarValue = Get-SecretFromAws -KeyName $VarName
            if (-not [string]::IsNullOrWhiteSpace($VarValue)) {
                Set-Item -Path "Env:\$VarName" -Value $VarValue
                Write-Verbose "  [OK] Hydrated Bookkeeper env var: $VarName"
            }
        }
    }
}

# Create Hermes secrets bundle and seed hermes_data volume
if ($InstallHermes -eq "true") {
    Write-Verbose "  [HERMES] Creating hermes secrets bundle..."
    $HermesManifest = (Get-BundleManifest).Hermes
    if (-not $HermesManifest) { throw "Publish-FleetStack: Hermes manifest not found" }
    $HermesSecretKeys = $HermesManifest.SourceKeys
    $HermesBundleEntries = @{}
    $HermesMissing = @()
    foreach ($Key in $HermesSecretKeys) {
        $Value = Get-SecretFromAws -KeyName $Key
        # Fallback: fleet-wide model key lives in AWS SM as OPENROUTER_ORCH_KEY.
        if ([string]::IsNullOrWhiteSpace($Value) -and $Key -eq 'OPENROUTER_API_KEY') {
            $Value = Get-SecretFromAws -KeyName 'OPENROUTER_ORCH_KEY'
        }
        $BundleKey = Resolve-BundleKeyFromEnvMap -SourceKey $Key -EnvMap $HermesManifest.EnvMap
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $HermesBundleEntries[$BundleKey] = $Value
        } else {
            $HermesMissing += $Key
        }
    }
    $null = Set-ContainerSecretBundle -BundleName $HermesManifest.BundleName -Entries $HermesBundleEntries -Label $HermesManifest.BundleName
    Write-Verbose "  [OK] Hermes bundle created: $($HermesManifest.BundleName) ($($HermesBundleEntries.Count) entries)"
    Write-SetupLog "Hermes bundle created: $($HermesManifest.BundleName) ($($HermesBundleEntries.Count) entries)"
    if ($HermesMissing.Count -gt 0) {
        Write-Verbose "  [WARN] $($HermesMissing.Count) hermes secret(s) not found in AWS SM: $($HermesMissing -join ', ') - bot features may be degraded"
        Write-SetupLog "Hermes secrets missing from AWS SM: $($HermesMissing -join ', ')" -Level WARN
    }

    # Seed hermes_data volume with overlay + .env so /opt/data exists and the
    # s6-supervised container can cd to it on startup.
    try {
        Initialize-HermesData -BundleEntries $HermesBundleEntries -ErrorAction Stop
    } catch {
        Write-Warning "  [WARN] Initialize-HermesData failed: $($_.Exception.Message)"
        Write-SetupLog "Initialize-HermesData failed: $($_.Exception.Message)" -Level WARN
    }
}

# Create fleet secrets bundle if not already present (fallback in case Phase 9b was
# checkpoint-skipped). Uses FLEET_GITHUB_TOKEN_READALL from env or AWS SM (per ADR-0043);
# fleet_aws_id and fleet_aws_secret are optional and only populated by Phase 9b's New-FleetIamUser.
# Safe probe: empty output means the secret does not exist yet - absence is a valid state handled by the caller.
$existingSecret = Invoke-Docker secret ls --filter name=fleet_secrets_bundle -q 2>$null
if ($existingSecret -notmatch '\S') {
    Write-Verbose "  [FLEET] fleet_secrets_bundle not found in Swarm - creating fallback bundle..."
    $FleetBundleEntries = @{}
    $SsoProfile = $env:AWS_SSO_PROFILE
    $fleetGitToken = [System.Environment]::GetEnvironmentVariable("FLEET_GITHUB_TOKEN_READALL")
    if ([string]::IsNullOrWhiteSpace($fleetGitToken) -and $SsoProfile) {
        $fleetGitToken = Get-SecretFromAws -KeyName "FLEET_GITHUB_TOKEN_READALL" -SsoProfile $SsoProfile -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($fleetGitToken)) {
        $FleetBundleEntries["FLEET_GITHUB_TOKEN_READALL"] = $fleetGitToken
    }
    $null = Set-ContainerSecretBundle -BundleName "fleet_secrets_bundle" -Entries $FleetBundleEntries -Label "fleet_secrets_bundle"
    Write-Verbose "  [OK] Fleet bundle created (fallback): fleet_secrets_bundle ($($FleetBundleEntries.Count) entries)"
    Write-SetupLog "Fleet bundle created (fallback): fleet_secrets_bundle ($($FleetBundleEntries.Count) entries)"
}

    $FleetTokenNames = @{
        "FLEET_API_TOKEN_BROWSERLESS"    = $null
        "FLEET_API_TOKEN_DOCUSIGN"       = $null
        "FLEET_API_TOKEN_IS_BOOKKEEPING"     = $null
        "FLEET_API_TOKEN_FLEET"          = $null
        "FLEET_API_TOKEN_MONITOR"        = $null
        "FLEET_API_TOKEN_MONITORING"     = $null
        "FLEET_API_TOKEN_FUNNEL"         = $null
        "FLEET_API_TOKEN_MARKETER"       = $null
        "FLEET_API_TOKEN_HERMES"         = $null
    }
$FleetServiceTokenValues = @{}
$TokenPersistFailures = @()
foreach ($tokenName in $FleetTokenNames.Keys) {
    $tokenResult = Get-ServiceApiToken -TokenName $tokenName
    if (-not $tokenResult.Persisted) { $TokenPersistFailures += $tokenName }
    $FleetServiceTokenValues[$tokenName] = $tokenResult.Value
    Set-SwarmSecretSafe -SecretName $tokenName -SecretValue (ConvertTo-SecureString $tokenResult.Value -AsPlainText -Force)
    Write-Verbose "  [FLEET] Published Swarm secret: $tokenName"
}
if ($TokenPersistFailures.Count -gt 0) {
    Write-SetupLog "WARN: Fleet API token(s) not persisted to AWS Secrets Manager: $($TokenPersistFailures -join ', ') - tokens will rotate on next deploy; review IAM/secrets permissions" -Level WARN
    Write-Verbose "  [WARN] Tokens not persisted to AWS SM: $($TokenPersistFailures -join ', ')"
}

# Add service tokens to agent bundles (exclude MONITOR ΓÇö fleet-only)
foreach ($agentCfg in $AgentConfigs) {
    $svcPrefix = Get-AgentSecretPrefix -Project $ProjectCode -Role $agentCfg.Role -Index $agentCfg.Index
    $bundleName = "${svcPrefix}_secrets_bundle"
    # Safe probe: empty output means the bundle does not exist yet - absence is a valid state handled by the caller.
    $existingBundle = Invoke-Docker secret ls --filter "name=$bundleName" -q 2>$null
    if (-not $existingBundle) { continue }
    # Safe swallow: Invoke-NativeCommand captures exit code via .Success (checked below); stderr discarded to avoid polluting captured output.
    $bundleContent = Invoke-NativeCommand { docker run --rm -v "${bundleName}:/tmp/secret" alpine:latest cat /tmp/secret 2>$null }
    if (-not $bundleContent.Success) { continue }
    try {
        $bundle = $bundleContent.Output | ConvertFrom-Json
        $serviceTokenNames = @("FLEET_API_TOKEN_BROWSERLESS", "FLEET_API_TOKEN_DOCUSIGN", "FLEET_API_TOKEN_IS_BOOKKEEPING")
        foreach ($st in $serviceTokenNames) {
            if ($FleetServiceTokenValues[$st]) {
                $bundle | Add-Member -NotePropertyName $st -NotePropertyValue $FleetServiceTokenValues[$st] -Force -ErrorAction SilentlyContinue
            }
        }
        $entries = @{}
        $bundle.PSObject.Properties | ForEach-Object { $entries[$_.Name] = $_.Value }
        $null = Set-ContainerSecretBundle -BundleName $bundleName -Entries $entries -Label $bundleName
        Write-Verbose "  [FLEET] Added service tokens to agent bundle: $bundleName"
    } catch {
        Write-Verbose "  [FLEET] Could not update agent bundle $bundleName ΓÇö skipping"
    }
}

# Hydrate Zoho env vars for compose variable substitution
foreach ($ZohoVar in @("ZOHO_BOOKS_ID", "ZOHO_BOOKS_SECRET", "ZOHO_BOOKS_REFRESH", "ZOHO_BOOKS_ORG_INTERSITE", "ZOHO_BOOKS_ORG_RENTALS", "ZOHO_BOOKS_FWD_RENTALS", "ZOHO_BOOKS_ROOMRENTALS_TD", "ZOHO_BOOKS_ROOMRENTALS_RBC", "ZOHO_BOOKS_ROOMRENTALS_SCOTIA", "ZOHO_BOOKS_ROOMRENTALS_VISA", "ZOHO_BOOKS_INTERSITE_RBC", "ZOHO_BOOKS_INTERSITE_6258")) {
    $existing = Get-Item -Path "Env:\$ZohoVar" -ErrorAction SilentlyContinue
    if ($null -eq $existing -or [string]::IsNullOrWhiteSpace($existing.Value)) {
        $value = Get-SecretFromAws -KeyName $ZohoVar
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Set-Item -Path "Env:\$ZohoVar" -Value $value
        }
    }
}

# Hydrate Browserless token for compose env var substitution (overlay-only auth)
$BrowserlessToken = Get-SecretFromAws -KeyName "BROWSERLESS_API_KEY"
if (-not [string]::IsNullOrWhiteSpace($BrowserlessToken)) {
    Set-Item -Path "Env:\BROWSERLESS_API_KEY" -Value $BrowserlessToken
    Write-Verbose "  [OK] Browserless token hydrated for deploy."
    Write-SetupLog "BROWSERLESS_API_KEY hydrated from AWS SM"
} elseif ($InstallBrowserless -eq "true") {
    Write-Verbose "  [WARN] BROWSERLESS_API_KEY not found in AWS SM - browserless will start without auth."
    Write-SetupLog "BROWSERLESS_API_KEY not found in AWS SM" -Level WARN
}

# Hydrate Tailscale key for funnel sidecar
if ($env:INSTALL_FUNNEL -eq "true") {
    $TailscaleKey = Get-SecretFromAws -KeyName "TAILSCALE_KEY" -SsoProfile $SsoProfile
    if (-not [string]::IsNullOrWhiteSpace($TailscaleKey)) {
        $env:TAILSCALE_KEY = $TailscaleKey
        Write-Information -MessageData "  [OK] TAILSCALE_KEY hydrated for tailscale-funnel" -Tags "INFO"
    } else {
        Write-Warning "  [WARN] TAILSCALE_KEY not found in AWS SM - tailscale-funnel will not authenticate"
    }

    # Create Docker config for tailscale serve config
    $FunnelConfigPath = Join-Path $TargetDir "Infrastructure" "funnel.json"
    if (Test-Path $FunnelConfigPath) {
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
        $null = Invoke-Docker config rm funnel_config 2>$null
        $ConfigResult = Invoke-NativeCommand { docker config create funnel_config $FunnelConfigPath 2>&1 }
        if ($ConfigResult.Success) {
            Write-Information -MessageData "  [OK] funnel_config Docker config created from Infrastructure/funnel.json" -Tags "INFO"
            Write-SetupLog "funnel_config Docker config created"
        } else {
            Write-Warning "  [WARN] Failed to create funnel_config - tailscale-funnel may not serve webhooks"
            Write-SetupLog "Failed to create funnel_config Docker config" -Level WARN
        }
    } else {
        Write-Warning "  [WARN] Infrastructure/funnel.json not found at $FunnelConfigPath - tailscale-funnel will not have serve config"
        Write-SetupLog "funnel.json not found at $FunnelConfigPath" -Level WARN
    }
}

# TOCTOU: Secret verification removed ΓÇö docker stack deploy validates secrets itself.
# The pre-verification loop created a window between check and deploy where a
# concurrent process could remove a secret. Docker's own validation during deploy
# is trusted. The deploy command includes --with-registry-auth for image resolution.
Write-Verbose "  [PREFLIGHT] Skipping secret pre-verification ΓÇö docker stack deploy validates secrets itself"
Write-SetupLog "Pre-flight: secret pre-verification skipped (trust Docker validation)"

# Pre-deploy: remove orphaned volumes from stale agent configs before deploy
# to prevent name collisions with new volumes Docker Swarm would auto-create.
Write-Verbose "`n  [PREFLIGHT] Cleaning stale volumes before deploy..."
Write-SetupLog "Pre-flight: removing orphaned volumes before deploy"
Remove-OrphanedVolumes -StackName $StackName -AgentConfigs $AgentConfigs -CleanDoublePrefixed

# Pre-flight: verify all expected agent volumes exist before deploying.
# Auto-creates any missing volumes instead of hard-failing, making the
# system resilient to manual volume deletion or edge cases where
# Initialize-AgentVolumes was skipped.
Write-Verbose "`n  [PREFLIGHT] Verifying expected volumes exist..."
Write-SetupLog "Pre-flight: verifying expected volumes"
$ExpectedVolNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($AgentCfg in $AgentConfigs) {
    $svcName = Get-AgentServiceName -Role $AgentCfg.Role -Index $AgentCfg.Index
    [void]$ExpectedVolNames.Add("${StackName}_agent_config_${svcName}")
    [void]$ExpectedVolNames.Add("${StackName}_agent_persist_${svcName}")
}
if ($AgentConfigs.Count -gt 1) {
    [void]$ExpectedVolNames.Add("${StackName}_memory_shared")
}
[void]$ExpectedVolNames.Add("${StackName}_interclaw_workspace")
$CreatedCount = 0
foreach ($VolName in $ExpectedVolNames) {
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
    $FoundResult = Invoke-NativeCommand { docker volume ls -q -f "name=$VolName" 2>$null }
    $Found = if ($FoundResult.Success) { $FoundResult.Output } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($Found)) { continue }
    $VolType = if ($VolName -match 'memory_shared$') { "memory-shared" } elseif ($VolName -match 'interclaw_workspace$') { "workspace" } elseif ($VolName -match 'agent_config_') { "config" } elseif ($VolName -match 'agent_persist_') { "persist" } else { "other" }
    $null = Invoke-NativeCommand { docker volume create --label com.interclaw.stack=$StackName --label "com.interclaw.volume-type=$VolType" $VolName }
    Write-Verbose "  [AUTO-CREATED] Missing volume: $VolName"
    Write-SetupLog "Pre-flight: auto-created missing volume $VolName"
    $CreatedCount++
}
if ($CreatedCount -gt 0) {
    Write-Verbose "  [OK] $CreatedCount volume(s) auto-created."
} else {
    Write-Verbose "  [OK] All $($ExpectedVolNames.Count) expected volumes exist."
}
Write-SetupLog "Pre-flight: all $($ExpectedVolNames.Count) volumes verified ($CreatedCount auto-created)"

# Pre-deploy: remove existing stack if present to prevent "name conflicts with an existing object"
# errors when stale services from a previous deployment share names with new services.
if ($env:INTERCLAW_PRESERVE_FLEET -eq "true" -or $PreserveFleet) {
    Write-Verbose "  [PREFLIGHT] PreserveFleet enabled ΓÇö skipping stack removal (fleet container must stay running)"
    Write-SetupLog "Pre-deploy: stack removal skipped (PreserveFleet)"
} else {
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
    $StackLsResult = Invoke-NativeCommand { docker stack ls --format "{{.Name}}" 2>$null }
    $ExistingStack = if ($StackLsResult.Success) { ($StackLsResult.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $StackName }) } else { $null }
    if ($ExistingStack) {
        Write-Verbose "  [PREFLIGHT] Removing existing stack '$StackName' before redeploy..."
        Write-SetupLog "Pre-deploy: removing existing stack $StackName"
        $null = Invoke-NativeCommand { docker stack rm $StackName 2>&1 }
        # Wait for stack removal to complete (services may take a moment to clean up)
        $RemovalTimeout = 30
        $RemovalElapsed = 0
        while ($RemovalElapsed -lt $RemovalTimeout) {
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
            $RemainResult = Invoke-NativeCommand { docker stack ls --format "{{.Name}}" 2>$null }
            $Remaining = if ($RemainResult.Success) { ($RemainResult.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $StackName }) } else { $null }
            if (-not $Remaining) { break }
            Start-Sleep -Seconds 2
            $RemovalElapsed += 2
        }
        if ($RemovalElapsed -ge $RemovalTimeout) {
            Write-SetupLog "WARN: Stack $StackName removal timed out after ${RemovalTimeout}s - proceeding with deploy" -Level WARN
            Write-Verbose "  [WARN] Stack removal timed out - proceeding with deploy anyway."
        } else {
            Write-Verbose "  [OK] Existing stack '$StackName' removed (${RemovalElapsed}s)."
            Write-SetupLog "Pre-deploy: existing stack $StackName removed (${RemovalElapsed}s)"
        }

        # Give Docker a moment to release network references from draining services
        Start-Sleep -Seconds 3
    }
}

try {
    Push-Location $TargetDir

    # Force-create overlay networks before deploy. Docker stack deploy on Windows
    # Desktop often fails to create them itself. We remove-and-recreate to ensure
    # clean state (no "already exists" conflict) and guarantee they exist for
    # services to attach.
    $NetworkNames = @((Get-NetworkNames).ServiceNet, (Get-NetworkNames).OrchestrationNet, (Get-NetworkNames).ManagementNet)
    if ($env:INSTALL_FUNNEL -eq "true") {
        $NetworkNames += (Get-NetworkNames).FunnelNet
    }

    # Pre-flight: verify Docker Swarm is active before creating overlay networks.
    # Overlay networks require Swarm mode - without it, all 3 retries below will
    # fail identically. Check now to fail fast instead of wasting retry cycles.
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
    $swarmStatusResult = Invoke-NativeCommand { docker info --format '{{.Swarm.LocalNodeState}}' 2>$null }
    $swarmStatus = if ($swarmStatusResult.Success) { $swarmStatusResult.Output } else { "unknown" }
    if ($swarmStatus -ne "active") {
        Write-Information -MessageData "  [NET] Swarm is not active (state: $swarmStatus). Re-initializing..." -Tags "WARN"
        $initResult = Invoke-NativeCommand { docker swarm init --advertise-addr 127.0.0.1 2>&1 }
        if (-not $initResult.Success) {
            throw "Docker Swarm is not active (state: $swarmStatus) and re-initialization failed: $($initResult.Output)"
        }
        Write-Information -MessageData "  [NET] Swarm re-initialized." -Tags "INFO"
        # Windows Docker Desktop with WSL2 backend needs time to initialize
        # the overlay network driver after swarm init.
        Start-Sleep -Seconds 5
    }

    # Pre-flight: verify Docker is in Linux container mode. Overlay networks are
    # only supported with Linux containers. Docker Desktop for Windows defaults
    # to Linux containers but can switch to Windows containers - detect and fail
    # fast with a clear message.
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
    $hostOSTypeResult = Invoke-NativeCommand { docker info --format '{{.OSType}}' 2>$null }
    $hostOSType = if ($hostOSTypeResult.Success) { $hostOSTypeResult.Output } else { $null }
    if ($hostOSType -ne "linux") {
        if ([string]::IsNullOrWhiteSpace($hostOSType)) {
            Write-Information -MessageData "  [WARN] Could not detect Docker host OS type - proceeding assuming Linux containers." -Tags "WARN"
        } else {
            throw "Docker is running in '$hostOSType' container mode. Overlay networks require Linux containers. On Docker Desktop, right-click the tray icon and switch to Linux containers, then re-run."
        }
    }

    # Pre-flight: capture Docker server version for diagnostics
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
    $dockerVersionResult = Invoke-NativeCommand { docker version --format '{{.Server.Version}}' 2>$null }
    $dockerVersion = if ($dockerVersionResult.Success) { $dockerVersionResult.Output } else { "unknown" }
    if ([string]::IsNullOrWhiteSpace($dockerVersion)) { $dockerVersion = "unknown" }

    # Pre-flight: capture Docker Desktop version and Windows info for diagnostics
    $dockerDesktopVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop" -Name DisplayVersion -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayVersion) 2>$null
    if (-not $dockerDesktopVersion) { $dockerDesktopVersion = "unknown" }
    $windowsBuild = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuild -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CurrentBuild) ?? "unknown"

    foreach ($net in $NetworkNames) {
        Write-Information -MessageData "  [NET] Ensuring network: $net" -Tags "INFO"

        # Check if the network already exists and is healthy
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
        $netInspectResult = Invoke-NativeCommand { docker network inspect $net 2>$null }
        $existingInspect = if ($netInspectResult.Success -and -not [string]::IsNullOrWhiteSpace($netInspectResult.Output)) { $netInspectResult.Output | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }
        if ($existingInspect) {
            $netConfig = $existingInspect[0]
            $configOk = $true
            if ($netConfig.Driver -ne "overlay") {
                Write-Information -MessageData "  [WARN] Network $net exists but driver is $($netConfig.Driver) - recreating" -Tags "WARN"
                $configOk = $false
            }
            if ($netConfig.Scope -ne "swarm") {
                Write-Information -MessageData "  [WARN] Network $net exists but scope is $($netConfig.Scope) - recreating" -Tags "WARN"
                $configOk = $false
            }
            if ($net -eq "management_net") {
                if ($netConfig.Internal -ne $true) {
                    Write-Information -MessageData "  [WARN] Network $net exists but is not internal - recreating" -Tags "WARN"
                    $configOk = $false
                }
            } else {
                if ($netConfig.Attachable -ne $true) {
                    Write-Information -MessageData "  [WARN] Network $net exists but is not attachable - recreating" -Tags "WARN"
                    $configOk = $false
                }
            }

            if ($configOk) {
                # Check for stale container references before reusing
                $containerCount = ($netConfig.Containers.PSObject.Properties).Count
                if ($containerCount -gt 0) {
                    $staleContainers = $netConfig.Containers.PSObject.Properties |
                        Where-Object { $_.Name -notlike "${StackName}*" }
                    if ($staleContainers) {
                        Write-Information -MessageData "  [NET] $($staleContainers.Count) stale container(s) found on $net - disconnecting..." -Tags "WARN"
                        foreach ($sc in $staleContainers) {
                            $containerId = $sc.Name
                            $containerName = ($sc.Value.Name -split '/')[-1]
                            Write-Information -MessageData "  [NET] Disconnecting stale container: $containerName ($containerId)" -Tags "INFO"
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
                            $null = Invoke-NativeCommand { docker network disconnect --force $net $containerId 2>$null }
                        }
                    }
                }
                Write-Information -MessageData "  [NET] Already exists and healthy, reusing: $net" -Tags "INFO"
                continue
            }
        }

        # Remove stale network (best effort - may have active endpoints)
        $rmResult = Invoke-NativeCommand { docker network rm $net 2>&1 }
        $rmOutput = $rmResult.Output
        $rmExit = $rmResult.ExitCode
        if ($rmExit -ne 0) {
            if ($rmOutput -match 'not found') {
                Write-Information -MessageData "  [NET] No existing network to remove: $net" -Tags "INFO"
            } else {
                Write-Information -MessageData "  [WARN] Could not remove network ${net}: $rmOutput" -Tags "WARN"
                Write-Information -MessageData "  [NET] Checking if existing network is usable..." -Tags "INFO"
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
                $recheckResult = Invoke-NativeCommand { docker network inspect $net --format '{{.Name}} {{.Driver}} {{.Scope}}' 2>$null }
                $recheck = if ($recheckResult.Success) { $recheckResult.Output } else { "" }
                if ($recheck -match "$net\s+overlay\s+swarm") {
                    Write-Information -MessageData "  [NET] Existing network is usable, reusing: $net" -Tags "INFO"
                    continue
                }
            }
        }

        Write-Information -MessageData "  [NET] Docker version $dockerVersion detected" -Tags "INFO"
        $maxCreateAttempts = 3
        $createAttempts = 0
        $created = $false
        $lastCreateError = $null
        # Note: --scope swarm is intentionally omitted. Overlay networks created
        # while Swarm is active always default to swarm scope. The flag was added
        # in Docker Engine 24.0 and would fail on older versions.
        # Note: $netFlags is an array splatted with @netFlags to avoid the PS7+
        # multi-flag-string-to-native-argument bug.
        while ($createAttempts -lt $maxCreateAttempts -and -not $created) {
            $createAttempts++
            $netFlags = if ($net -eq "management_net") { @("--driver", "overlay", "--internal") } else { @("--driver", "overlay", "--attachable") }
            $createResult = Invoke-NativeCommand { docker network create @netFlags $net 2>&1 }
            $createOutput = $createResult.Output
            $createExit = $createResult.ExitCode
            if ($createExit -eq 0 -and $createOutput) {
                $created = $true
            } else {
                $lastCreateError = if ($createOutput -is [array]) { $createOutput -join " " } else { "$createOutput" }
                if ($createAttempts -lt $maxCreateAttempts) {
                    $delay = Get-BackoffDelay -Attempt $createAttempts -Schedule @(3, 7, 15) -JitterFraction 0.25
                    Write-Information -MessageData "  [RETRY] Network $net creation failed (attempt $createAttempts/$maxCreateAttempts): $lastCreateError - retrying in ${delay}s (base ${baseDelay}s with jitter)..." -Tags "WARN"
                    Start-Sleep -Seconds $delay
                }
            }
        }

        if (-not $created) {
            # Attempt WSL2 reset as a last-resort recovery (Windows Docker Desktop with WSL2 backend)
            $wslResetAttempted = $false
            if ($hostOSType -eq "linux") {
                Write-Information -MessageData "  [NET] WSL2 reset recovery: shutting down WSL2 VM and retrying..." -Tags "WARN"
                Invoke-DockerWithLogging -Command { & wsl --shutdown 2>&1 } -OperationLabel "WSL2 shutdown recovery"
                Start-Sleep -Seconds 5
                $wslResetAttempted = $true
                $createAttempts++
                $createResult = Invoke-NativeCommand { docker network create @netFlags $net 2>&1 }
                $createOutput = $createResult.Output
                $createExit = $createResult.ExitCode
                if ($createExit -eq 0 -and $createOutput) {
                    $created = $true
                    Write-Information -MessageData "  [NET] Network $net created successfully after WSL2 reset." -Tags "INFO"
                } else {
                    $lastCreateError = if ($createOutput -is [array]) { $createOutput -join " " } else { "$createOutput" }
                    Write-Information -MessageData "  [NET] WSL2 reset did not resolve creation failure: $lastCreateError" -Tags "WARN"
                }
            }

            if (-not $created) {
                $inspectResult = Invoke-NativeCommand { docker network inspect $net 2>&1 }
                $inspect = if ($inspectResult.Output) { $inspectResult.Output | Out-String } else { "" }
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
                $swarmDiagResult = Invoke-NativeCommand { docker info --format 'Swarm: {{.Swarm.LocalNodeState}} | Containers: {{.Containers}} | Images: {{.Images}}' 2>$null }
                $swarmDiag = if ($swarmDiagResult.Success) { $swarmDiagResult.Output } else { "unknown" }
                $errorDetail = "Docker version: $dockerVersion | Docker Desktop: $dockerDesktopVersion | Windows build: $windowsBuild | OS: $hostOSType | Last error: $lastCreateError"
                Write-SetupLog "FAIL: Failed to create overlay network '$net' after $maxCreateAttempts attempts. $errorDetail. Swarm state: $swarmDiag" -Level ERROR
                if ($wslResetAttempted) {
                    Write-Information -MessageData "  [NET] WSL2 reset was attempted but did not resolve the issue." -Tags "WARN"
                    Write-Information -MessageData "  [NET] Try restarting Docker Desktop or rebooting, then re-run." -Tags "WARN"
                }
                throw "Failed to create Docker overlay network '$net' after $maxCreateAttempts attempt(s). $errorDetail. Swarm state: $swarmDiag. Inspect: $inspect"
            }
        }

        $maxVerifyAttempts = 5
        $verifyAttempts = 0
        $verified = $false
        while ($verifyAttempts -lt $maxVerifyAttempts -and -not $verified) {
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
            $inspectResult = Invoke-NativeCommand { docker network inspect $net --format '{{.Name}} {{.Driver}} {{.Scope}}' 2>$null }
            $inspectStr = if ($inspectResult.Success) { $inspectResult.Output } else { "" }
            if ($inspectStr -match "$net\s+overlay\s+swarm") {
                $verified = $true
            } else {
                Start-Sleep -Seconds 1
                $verifyAttempts++
            }
        }

        if (-not $verified) {
            $inspectResult = Invoke-NativeCommand { docker network inspect $net 2>&1 }
            $inspect = if ($inspectResult.Output) { $inspectResult.Output | Out-String } else { "" }
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
            $swarmDiagResult = Invoke-NativeCommand { docker info --format 'Swarm: {{.Swarm.LocalNodeState}} | Containers: {{.Containers}}' 2>$null }
            $swarmDiag = if ($swarmDiagResult.Success) { $swarmDiagResult.Output } else { "unknown" }
            $errorDetail = "Docker version: $dockerVersion | Docker Desktop: $dockerDesktopVersion | Windows build: $windowsBuild | OS: $hostOSType"
            Write-SetupLog "FAIL: Overlay network '$net' not verified after $maxVerifyAttempts checks. $errorDetail. Swarm state: $swarmDiag" -Level ERROR
            throw "Docker overlay network '$net' not fully initialized after $maxVerifyAttempts verification attempt(s). $errorDetail. Swarm state: $swarmDiag. Inspect: $inspect"
        }
        Write-Information -MessageData "  [NET] Verified: $net" -Tags "INFO"
    }

    # Generate a random Grafana admin password if monitoring is enabled.
    # The compose template uses ${GF_SECURITY_ADMIN_PASSWORD:-admin} which falls
    # back to 'admin' if the env var is unset ΓÇö injecting it here prevents the
    # default credential from being used.
    if ($InstallMonitoring -eq "true") {
        $grafanaPassword = New-CryptographicToken -ByteCount 24
        Set-Item -Path "Env:\GF_SECURITY_ADMIN_PASSWORD" -Value $grafanaPassword
        Write-Verbose "  [GRAFANA] Generated random admin password"
        Write-SetupLog "Grafana admin password generated"
    }

    # --with-registry-auth ensures credentials for private images are passed.
    $DeployTimeoutSeconds = 300
    Write-SetupLog "Deploying fleet stack (timeout: ${DeployTimeoutSeconds}s)..."
    $deployJob = Start-Job -ScriptBlock { param($fp, $sn) $output = docker stack deploy -c $fp $sn --with-registry-auth 2>&1; $exitCode = $LASTEXITCODE; return @{ Output = $output; ExitCode = $exitCode } } -ArgumentList $FleetComposePath, $StackName
    $deployJob | Wait-Job -Timeout $DeployTimeoutSeconds | Out-Null
    if ($deployJob.State -eq "Running") {
        Stop-Job $deployJob
        Remove-Job $deployJob -ErrorAction SilentlyContinue
        throw "docker stack deploy timed out after ${DeployTimeoutSeconds}s ΓÇö Swarm manager may be in a bad state"
    }
    $deployResult = Receive-Job $deployJob
    Remove-Job $deployJob -ErrorAction SilentlyContinue
    $deployOutput = $deployResult.Output
    $deployExitCode = $deployResult.ExitCode

    if ($deployExitCode -ne 0) {
        Write-Verbose "  [FAIL] Docker stack deploy exited with code $deployExitCode"
        Write-Verbose "  Output: $deployOutput"
        Write-SetupLog "FAIL: Docker stack deployment failed (exit code $deployExitCode): $deployOutput" -Level ERROR

        $SvcList = Invoke-NativeCommand { docker service ls 2>&1 }
        Write-Verbose "`n  [DIAGNOSTICS] Current services:"
        Write-Verbose "$($SvcList.Output)"
        $SvcErrors = Invoke-NativeCommand { docker stack services $StackName 2>&1 }
        Write-Verbose "  [DIAGNOSTICS] Stack services:"
        Write-Verbose "$($SvcErrors.Output)"

        throw "Docker stack deploy failed (exit code $deployExitCode)"
    }

    Write-Verbose "  [SUCCESS] Stack '$StackName' is deploying."
    Write-SetupLog "Docker stack deploy output: $($DeployResult.Output)"

    # Force-purge stale healthcheck from Swarm spec after deploy ΓÇö healthcheck
    # was deliberately removed from compose, but Swarm persists it across deploys.
    # Without purge, Docker continues killing the container based on the stale spec.
    Write-Verbose "  [HEALTHCHECK] Purging stale Swarm healthcheck from is-fleet service..."
    $null = Invoke-NativeCommand { docker service update --health-cmd="" ${StackName}_is-fleet 2>&1 }
    Write-Verbose "  [OK] Stale healthcheck purged from is-fleet Swarm spec."
    Write-SetupLog "Stale Swarm healthcheck purged from is-fleet"
}
catch {
    Write-SetupLog "FAIL: Docker stack deployment failed: $($_.Exception.Message)" -Level ERROR
    Write-Verbose "  [FAIL] Failed to deploy Docker stack: $($_.Exception.Message)"
    Write-SetupLog "Initiating rollback..."
    try {
        $null = Invoke-NativeCommand { docker stack rm $StackName 2>&1 }
        Write-SetupLog "Rollback: removed stack $StackName"
    } catch {
        Write-SetupLog "Rollback: could not remove stack $StackName ΓÇö $_" -Level WARN
    }
    Write-SetupLog "Rollback complete"
    throw "Docker stack deployment failed: $($_.Exception.Message)"
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
}

# Write deploy manifest after successful stack deploy
try {
    Write-DeployManifest -StackName $StackName -TargetDir $TargetDir -AgentConfigs $AgentConfigs -ImageVersion $ImageVersion
} catch {
    Write-SetupLog "WARN: Failed to write deploy manifest: $($_.Exception.Message)" -Level WARN
}

# Clear the fleet startup check marker so it re-runs after a fresh deploy
Remove-Item (Join-Path (Get-ReportsDir) ".startup-check-done") -Force -ErrorAction SilentlyContinue
Write-SetupLog "Cleared startup check marker - fleet will run post-deploy checks on first boot"

# Cleanup orphaned volumes after successful stack deploy (prunes stale volumes from removed services)
Remove-OrphanedVolumes -StackName $StackName -AgentConfigs $AgentConfigs -CleanDoublePrefixed

# Cleanup Docker images not referenced by any current stack service
Write-Verbose "`n[CleanupStaleImages] Scanning for unused Docker images..."
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
$ImageListResult = Invoke-NativeCommand { docker stack services $StackName --format "{{.Image}}" 2>$null }
if (-not $ImageListResult.Success -or [string]::IsNullOrWhiteSpace("$($ImageListResult.Output)")) {
    Write-SetupLog "WARN: Cannot determine active images (docker stack services query failed or returned empty) - skipping stale-image sweep" -Level WARN
    Write-Verbose "  [WARN] Cannot determine active images - skipping stale-image sweep."
} else {
$rawImageList = $ImageListResult.Output -split "`n" | ForEach-Object { if ($_) { $_.Trim() } } | Where-Object { $_ -ne '' } | ForEach-Object { ($_ -split ':')[0] }
$activeImages = [System.Collections.Generic.HashSet[string]]::new()
if ($rawImageList) { $null = $activeImages.UnionWith([string[]]$rawImageList) }
# Safe probe/swallow: Invoke-NativeCommand captures exit code via .Success (caller checks it); stderr suppression keeps captured Output clean.
$AllImagesResult = Invoke-NativeCommand { docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>$null }
$staleIds = if ($AllImagesResult.Success) {
    $AllImagesResult.Output -split "`n" |
        Where-Object { $_ -notmatch '<none>|<missing>' -and -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $parts = $_ -split ' '
            if ($parts.Count -lt 2) { return }
            $RepoTag, $Id = $parts[0], $parts[1]
            if ([string]::IsNullOrWhiteSpace($Id)) { return }
            $Repo = ($RepoTag -split ':')[0]
            if ($Repo -notin $activeImages) { $Id }
        }
} else { @() }
$staleIds = @($staleIds | Where-Object { $_ -ne $null })
if ($staleIds.Count -gt 0) {
    $uniqueStale = [System.Collections.Generic.HashSet[string]]::new([string[]]$staleIds)
    $staleImages = @($uniqueStale)
    Write-Verbose "  [CLEANUP] Removing $($staleImages.Count) stale images..."
    $RmResult = Invoke-NativeCommand { docker image rm $staleImages 2>&1 }
    if ($RmResult.Success) {
        Write-Verbose "  [OK] Cleaned $($uniqueStale.Count) stale images."
        Write-SetupLog "Bulk cleanup: $($uniqueStale.Count) stale images removed"
    } else {
        Write-Verbose "  [OK] Partial cleanup (some images in use by other stacks)."
        Write-SetupLog "Bulk cleanup: partial removal (some images in use)" -Level WARN
    }
} else {
    Write-Verbose "  [OK] No unused images found."
}
}

Write-SetupLog "Phase 5 complete: stack deployed"
}

# Fleet API Tokens — generate/persist per-service tokens and publish as Swarm secrets.
# Defined at module scope (not nested) so callers and tests can invoke it directly.
function Get-ServiceApiToken {
    param([string]$TokenName)
    $existing = Get-SecretFromAws -KeyName $TokenName
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Verbose "  [FLEET] Token $TokenName found in AWS SM — reusing"
        return [pscustomobject]@{ Value = $existing; Persisted = $true }
    }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $token = [System.Convert]::ToBase64String($bytes) -replace '[+/=]', '' -replace '-', ''
    $smProfile = $env:AWS_SSO_PROFILE
    $smRegion = $env:AWS_SECRETS_REGION ?? "ca-central-1"
    $createResult = Invoke-AwsCommand { aws secretsmanager create-secret --name $TokenName --secret-string $token --profile $smProfile --region $smRegion 2>&1 }
    $persisted = $createResult.Success
    if (-not $createResult.Success) {
        $putResult = Invoke-AwsCommand { aws secretsmanager put-secret-value --secret-id $TokenName --secret-string $token --profile $smProfile --region $smRegion 2>&1 }
        $persisted = $putResult.Success
        if (-not $putResult.Success) {
            Write-SetupLog "ERROR: Fleet API token $TokenName could not be persisted to AWS Secrets Manager (create-secret and put-secret-value both failed). Token will rotate on every deploy and external consumers will break — review IAM/secrets permissions for profile '$smProfile' in region $smRegion." -Level ERROR
        }
    }
    Write-SetupLog "Fleet API token generated: $TokenName (persisted=$persisted)"
    return [pscustomobject]@{ Value = $token; Persisted = $persisted }
}


