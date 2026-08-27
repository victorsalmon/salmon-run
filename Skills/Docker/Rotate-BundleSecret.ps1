<#
.SYNOPSIS
    Rotates a Docker Swarm bundle secret in-place with zero downtime and per-step logging.
.DESCRIPTION
    Replaces the content of a Docker Swarm secret that is currently mounted by one or more
    services. Uses a temp-name swap pattern so the service always has a valid secret mounted.
    Delegates to Invoke-SecretRotation from SalmonRun.Secrets when available; falls back
    to inline docker commands when the module is not loaded.
.PARAMETER BundleName
    Name of the Docker Swarm secret to rotate (e.g. bookkeeping_secrets_bundle).
.PARAMETER ServiceName
    Swarm service name that has the secret mounted (e.g. FRAD_is-bookkeeping).
.PARAMETER SecretValue
    The new JSON string to write into the bundle secret.
.PARAMETER MountTarget
    The target path inside the container (default: same as BundleName).
.EXAMPLE
    PS> .\Rotate-BundleSecret.ps1 -BundleName bookkeeping_secrets_bundle `
        -ServiceName FRAD_is-bookkeeping -SecretValue $newJson
#>
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleName,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceName,
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [SecureString]$SecretValue,
    [string]$MountTarget,
    [switch]$UseFallback,
    [switch]$WhatIf
)

if (-not $MountTarget) { $MountTarget = $BundleName }

$ErrorActionPreference = "Stop"
$timestamp = { param($msg) "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

# Validate bundle name against known manifest
$knownBundles = if (Get-Command Get-BundleManifest -ErrorAction SilentlyContinue -ErrorVariable gcmManifestErr) {
    $m = Get-BundleManifest
    if ($null -eq $m) { @() } else { @($m.PSObject.Properties.Name) }
} else { @() }
if ($gcmManifestErr) { Write-Host (& $timestamp "  [WARN] Get-BundleManifest probe reported errors: $($gcmManifestErr[0].Exception.Message)") }
if ($knownBundles.Count -gt 0 -and $BundleName -notin $knownBundles) {
    Write-Host (& $timestamp "  [WARN] Bundle '$BundleName' not found in Get-BundleManifest keys: $($knownBundles -join ', ')")
}

# Resolve SecureString to plain text for Docker operations
$plainValue = [System.Net.NetworkCredential]::new("", $SecretValue).Password
if ([string]::IsNullOrWhiteSpace($plainValue)) {
    Write-Host (& $timestamp "  [FAIL] Resolved secret value is empty — aborting rotation")
    exit 1
}

Write-Host (& $timestamp "Rotation target: $BundleName on $ServiceName (mount: $MountTarget)")

if ($WhatIf) {
    Write-Host (& $timestamp "  [WHATIF] Would rotate $BundleName on $ServiceName")
    Write-Host (& $timestamp "  [WHATIF] Secret value length: $($plainValue.Length) chars")
    Write-Host (& $timestamp "  [WHATIF] Use -WhatIf:$false to execute")
    Write-Host (& $timestamp "=== WhatIf complete ===")
    return
}

# Prefer Invoke-SecretRotation from SalmonRun.Secrets module when available.
# Always try the module path first; use -UseFallback for explicit fallback.
$useShared = -not $UseFallback -and $null -ne (Get-Command Invoke-SecretRotation -ErrorAction SilentlyContinue -ErrorVariable gcmRotationErr)
if ($gcmRotationErr) { Write-Host (& $timestamp "  [WARN] Invoke-SecretRotation probe reported errors: $($gcmRotationErr[0].Exception.Message)") }

if ($useShared) {
    Write-Host (& $timestamp "Using shared Invoke-SecretRotation from SalmonRun.Secrets ...")
    try { $parsed = $plainValue | ConvertFrom-Json -AsHashtable } catch { throw "Secret bundle value is not valid JSON: $_" }
    if ($parsed -isnot [hashtable] -or $parsed.Count -eq 0) { throw "Secret bundle value parsed as empty or non-hashtable JSON" }
    if (Get-Command Invoke-SecretRotation -ErrorAction SilentlyContinue -ErrorVariable gcmRotationErr2) {
        Invoke-SecretRotation -ServiceName $ServiceName -BundleData $parsed -OldSecretName $BundleName -NewSecretName $BundleName -MountTarget $MountTarget
        Write-Host (& $timestamp "  OK: rotation via Invoke-SecretRotation succeeded")
        Write-Host (& $timestamp "=== Rotation complete ===")
        return
    }
    Write-Host (& $timestamp "  WARN: Invoke-SecretRotation not available despite pre-check — falling through to inline")
}

# Fallback: inline docker commands (for standalone use without module)
Write-Host (& $timestamp "Module not loaded — using fallback docker commands ...")

# Concurrency guard: named mutex prevents concurrent rotations on the same service
$mutexName = "Global\Interclaw-SecretRotation-$ServiceName"
$mutex = $null
$mutexAcquired = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $mutex.WaitOne(120000)
    if (-not $mutexAcquired) {
        throw "Failed to acquire rotation mutex for $ServiceName within 120s — another rotation may be in progress. Use -UseFallback to force inline mode (bypasses mutex check)."
    }

    $tempName = "${BundleName}_rotating"
    $oldSecretRemoved = $false
    $serviceOnTemp = $false
    $priorSecretValue = $null
    # ---- Step 0: Capture prior secret value before modification ----
    # docker secret inspect only returns metadata (Name/ID), never secret content.
    # Read the currently-mounted content from the running container instead.
    Write-Host (& $timestamp "Capturing prior secret value for rollback safety ...")
    try {
        $priorSecretValue = (docker exec $ServiceName sh -c "cat /run/secrets/$MountTarget" 2>$null) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($priorSecretValue)) {
            try {
                $null = $priorSecretValue | ConvertFrom-Json -ErrorAction Stop
                Write-Host (& $timestamp "  OK: prior secret content captured (rollback-safe)")
            } catch {
                Write-Host (& $timestamp "  [WARN] Captured prior value is not valid JSON — rollback will fall back to new value")
                $priorSecretValue = $null
            }
        } else {
            Write-Host (& $timestamp "  [WARN] Could not read prior secret content from container — rollback will fall back to new value")
        }
    } catch { Write-Host (& $timestamp "  WARN: could not capture prior secret value: $_") }

    # ---- Step 1: Create temp secret ----
    Write-Host (& $timestamp "Creating temp secret $tempName ...")
    $null = $plainValue | docker secret create $tempName - 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to create temp secret $tempName" }
    Write-Host (& $timestamp "  OK: temp secret created")
    # Docker secret eventual consistency — the temp secret must be visible to the service update below.
    Start-Sleep -Milliseconds 500

    # ---- Step 2: Swap service from old to temp (atomic) ----
    Write-Host (& $timestamp "Swapping service $ServiceName to temp secret ...")
    docker service update --detach=false --secret-rm=$BundleName --secret-add="source=$tempName,target=$MountTarget" $ServiceName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to swap service to temp secret" }
    $serviceOnTemp = $true
    Write-Host (& $timestamp "  OK: service now using temp secret")

    # ---- Step 3: Remove old secret (required to re-use the name) ----
    Write-Host (& $timestamp "Removing old secret $BundleName ...")
    $rmOldOutput = docker secret rm $BundleName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $oldSecretRemoved = $true
        Write-Host (& $timestamp "  OK: old secret removed")
    } else {
        $oldSecretRemoved = $false
        Write-Host (& $timestamp "  WARN: old secret removal skipped (already removed or in use): $rmOldOutput")
    }
    # Docker secret eventual consistency — allow the removed name to be re-used.
    Start-Sleep -Milliseconds 500

    # ---- Step 4: Re-create with final name ----
    Write-Host (& $timestamp "Re-creating secret $BundleName with new content ...")
    $null = $plainValue | docker secret create $BundleName - 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to re-create secret $BundleName"
    }
    Write-Host (& $timestamp "  OK: secret re-created")

    # ---- Step 5: Verify new secret exists before swapping ----
    # Docker secret eventual consistency — allow the re-created secret to become listable.
    Start-Sleep -Milliseconds 500
    $verifyNewSecret = docker secret ls -q -f "name=$BundleName" 2>$null
    if ([string]::IsNullOrWhiteSpace($verifyNewSecret)) {
        throw "New secret $BundleName was not created despite exit code 0 — Docker eventual consistency issue"
    }

    # ---- Step 6: Swap service from temp back to final name ----
    Write-Host (& $timestamp "Swapping service $ServiceName back to $BundleName ...")
    docker service update --detach=false --secret-rm=$tempName --secret-add="source=$BundleName,target=$MountTarget" $ServiceName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to swap service back to $BundleName" }
    $serviceOnTemp = $false
    Write-Host (& $timestamp "  OK: service now using final secret")

    # ---- Step 7: Clean up temp ----
    Write-Host (& $timestamp "Cleaning up temp secret ...")
    # Best-effort cleanup — failures are cosmetic once the service is back on the final secret.
    $rmTempOutput = docker secret rm $tempName 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host (& $timestamp "  OK: temp secret removed") }
    else { Write-Host (& $timestamp "  WARN: temp secret removal failed: $rmTempOutput") }

    Write-Host (& $timestamp "=== Rotation complete ===")
} catch {
    Write-Host (& $timestamp "  [FAIL] Rotation failed: $_")
    try {
        if ($serviceOnTemp) {
            Write-Host (& $timestamp "  Attempting rollback — service is on temp secret...")
            # Recreate original secret with prior value if available, otherwise use current value
            if ($oldSecretRemoved) {
                if ($priorSecretValue) {
                    Write-Host (& $timestamp "  Restoring original secret content from captured prior revision...")
                    $null = $priorSecretValue | docker secret create $BundleName - 2>&1
                } else {
                    Write-Host (& $timestamp "  Restoring secret with current value (prior revision not available)...")
                    $null = $plainValue | docker secret create $BundleName - 2>&1
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host (& $timestamp "  [WARN] Could not restore original secret — temp secret still on service, service may be degraded")
                } else {
                    # Docker secret eventual consistency — allow the service swap to see the recreated secret.
                    Start-Sleep -Milliseconds 500
                }
            }
            docker service update --detach=false --secret-rm=$tempName --secret-add="source=$BundleName,target=$MountTarget" $ServiceName 2>&1
        }
        Write-Host (& $timestamp "  Cleaning up temp secret...")
        $rmTempRollbackOut = docker secret rm $tempName -ErrorAction SilentlyContinue -ErrorVariable rmTempRollbackErr 2>&1
        if ($rmTempRollbackErr) { Write-Host (& $timestamp "  [WARN] Temp secret cleanup during rollback: $($rmTempRollbackErr[0].Exception.Message)") }
        Write-Host (& $timestamp "  Rollback completed")
    } catch {
        Write-Host (& $timestamp "  [CRITICAL] Rollback also failed: $_")
        Write-Host (& $timestamp "  Manual recovery: docker service update --secret-rm=$tempName --secret-add=source=$BundleName,target=$MountTarget $ServiceName")
        Write-Host (& $timestamp "  Then: docker secret rm $tempName")
    }
    throw
} finally {
    if ($mutex -and $mutexAcquired) {
        try { $null = $mutex.ReleaseMutex() } catch { Write-Debug "Failed to release rotation mutex: $_" }
    }
    if ($mutex) { $mutex.Dispose() }
}
