<#
.SYNOPSIS
    Seed the Hermes named volume with a preconfigured /opt/data overlay and .env secrets.
.DESCRIPTION
    Copies the non-secret Hermes overlay (config.yaml, SOUL.md, AGENTS.md, USER.md) into the
    hermes_data Docker volume and writes a .env file from the supplied bundle entries.
    Intended to be called from Publish-FleetStack after hermes_secrets_bundle is built.
    The official Hermes image runs as hermes uid 10000, so ownership is set accordingly.
#>
function Initialize-HermesData {
    [CmdletBinding(SupportsShouldProcess)]
    param(
    [Parameter(Mandatory = $true)]
    [hashtable]$BundleEntries,

    [string]$OverlaySource,

    [string]$VolumeName = 'hermes_data',

    [string]$HermesUid = '10000'
)

# Resolve overlay source relative to repo root if not provided
if ([string]::IsNullOrWhiteSpace($OverlaySource)) {
    $repoRoot = if (Get-Command Get-InterclawRepoRoot -ErrorAction SilentlyContinue) {
        Get-InterclawRepoRoot
    } else {
        (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    }
    $OverlaySource = Join-Path $repoRoot 'Infrastructure\hermes\overlay'
}

if (-not (Test-Path $OverlaySource)) {
    throw "Initialize-HermesData: Overlay source not found: $OverlaySource"
}

# Ensure volume exists
$existing = Invoke-Docker volume ls --filter "name=^${VolumeName}$" -q
if ([string]::IsNullOrWhiteSpace($existing)) {
    Write-Verbose "  [HERMES] Creating Docker volume: $VolumeName"
    $null = Invoke-Docker volume create $VolumeName
    if ($LASTEXITCODE -ne 0) { throw "Initialize-HermesData: docker volume create $VolumeName failed" }
}

# Copy overlay files into the volume (forward-slash mount source for Docker)
$overlayForward = $OverlaySource -replace '\\', '/'
$copyCmd = "cp /src/* /opt/data/ && chown -R ${HermesUid}:${HermesUid} /opt/data"
Write-Verbose "  [HERMES] Seeding $VolumeName from $OverlaySource"
$null = Invoke-Docker -DockerArgs @(
    'run', '--rm',
    '-v', "${VolumeName}:/opt/data",
    '-v', "${overlayForward}:/src:ro",
    'alpine:latest', 'sh', '-c', $copyCmd
)
if ($LASTEXITCODE -ne 0) { throw "Initialize-HermesData: overlay copy into $VolumeName failed" }

# Build .env content from bundle entries (skip empty values)
$envLines = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $BundleEntries.GetEnumerator()) {
    if (-not [string]::IsNullOrWhiteSpace($entry.Value)) {
        $envLines.Add("$($entry.Name)=$($entry.Value)")
    }
}

# Map Orchestrator persona secrets to Hermes .env keys.
# TELEGRAM_OWNER_USERID lives in Interclaw/FRAD/Orchestrator (from oc-base/OpenClaw personas)
# and becomes the allowed-user allowlist for the Hermes Telegram gateway.
if ($BundleEntries.ContainsKey('TELEGRAM_OWNER_USERID')) {
    $envLines.Add("TELEGRAM_ALLOWED_USERS=$($BundleEntries['TELEGRAM_OWNER_USERID'])")
}
if ($BundleEntries.ContainsKey('TELEGRAM_OWNER_USERNAME')) {
    $envLines.Add("TELEGRAM_HOME_CHANNEL=$($BundleEntries['TELEGRAM_OWNER_USERNAME'])")
}

$envContent = ($envLines -join "`n") + "`n"

# Write .env into the volume via stdin so it never touches the host filesystem
$envCmd = "cat > /opt/data/.env && chmod 600 /opt/data/.env && chown ${HermesUid}:${HermesUid} /opt/data/.env"
Write-Verbose "  [HERMES] Writing .env from bundle into $VolumeName"
$null = Invoke-Docker -StdinInput $envContent -DockerArgs @(
    'run', '-i', '--rm',
    '-v', "${VolumeName}:/opt/data",
    'alpine:latest', 'sh', '-c', $envCmd
)
if ($LASTEXITCODE -ne 0) { throw "Initialize-HermesData: .env write into $VolumeName failed" }

Write-Verbose "  [OK] Hermes /opt/data initialized in $VolumeName"
}
