<#
.DEPRECATED
    This script is an ad-hoc diagnostic tool with no known automated callers.
    Volume diagnostics are now covered by Initialize-AgentVolumes.ps1 (which
    validates volume state during deploy) and Diagnose-VolumeHealth.ps1 in
    SalmonRun.Deploy. Retained for manual troubleshooting only.

.SYNOPSIS
    Diagnose Docker volumes for Interclaw stack — detect duplicates, orphans, double-prefixed volumes.
.DESCRIPTION
    Dumps all Docker volumes for the given stack name, groups them by pattern,
    and reports anomalies. Exits 0 if clean, non-zero if issues found.

    See docs/Reference/stackname-stability-audit.md for the
    full audit of $script:StackName stability across the deploy pipeline.
.PARAMETER StackName
    The Docker Swarm stack name (e.g., FRAD). Required.
.EXAMPLE
    pwsh Scripts/diagnose-volumes.ps1 -StackName FRAD
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StackName
)

$ErrorActionPreference = "Continue"
$AnomalyFound = $false

# Define expected volume patterns for the stack
$ExpectedSet = [System.Collections.Generic.HashSet[string]]::new()

# Expected agent patterns: {StackName}_agent_{config|persist}_oc-{role}
# Note: We can't enumerate all agents without the AgentConfigs, so we detect
# pattern-matching volumes and infer what's expected from what exists.

Write-Host "`n=== Volume Diagnostic Report: $StackName ===" -ForegroundColor Cyan
Write-Host "Scanning all Docker volumes matching '${StackName}_'..." -ForegroundColor Gray

# Dump all volumes with metadata
$AllVolumes = docker volume ls --format "{{.Name}}\t{{.Driver}}\t{{.CreatedAt}}" 2>$null
$StackVolumes = $AllVolumes | Where-Object { $_ -match "^${StackName}_" }

if (-not $StackVolumes) {
    Write-Host "  [INFO] No volumes found for stack '$StackName'." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($StackVolumes.Count) total ${StackName}_ prefixed volumes." -ForegroundColor Gray
Write-Host ""

# Parse all volumes into classification buckets
$Expected = @()
$DoublePrefixed = @()
$Legacy = @()
$Unmatched = @()

# Build expected set dynamically from what we see (config/persist patterns with oc- roles)
# Also collect agent roles seen
$SeenRoles = [System.Collections.Generic.HashSet[string]]::new()
foreach ($Line in $StackVolumes) {
    $Name = ($Line -split "`t")[0]

    # Check for double-prefixed first
    if ($Name -match "^${StackName}_${StackName}_") {
        $DoublePrefixed += $Name
        continue
    }

    # Check for expected agent config/persist volumes
    if ($Name -match "^${StackName}_agent_(config|persist)_oc-(\w+)") {
        $null = $SeenRoles.Add($matches[2])
        $Expected += $Name
        continue
    }

    # Expected shared volumes
    if ($Name -eq "${StackName}_memory_shared" -or $Name -eq "${StackName}_interclaw_workspace") {
        $Expected += $Name
        continue
    }

    # Legacy naming patterns
    if ($Name -match '_BASE_\d+$') {
        $Legacy += $Name
        continue
    }
    if ($Name -match '_agent_config_oc-\w+-\d+$|_agent_persist_oc-\w+-\d+$') {
        # Old indexed naming (oc-orch-0, oc-veri-1) — legacy
        $Legacy += $Name
        continue
    }

    # Starts with StackName but doesn't match known patterns
    $Unmatched += $Name
}

# Report classifications
Write-Host "--- Classification ---" -ForegroundColor Cyan
Write-Host "  Expected volumes:             $($Expected.Count)" -ForegroundColor Green
Write-Host "  Double-prefixed volumes:      $($DoublePrefixed.Count)" -ForegroundColor $(if ($DoublePrefixed.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Legacy naming volumes:        $($Legacy.Count)" -ForegroundColor $(if ($Legacy.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Unmatched volumes:            $($Unmatched.Count)" -ForegroundColor $(if ($Unmatched.Count -gt 0) { "Yellow" } else { "Green" })

# Expected volumes
Write-Host ""
Write-Host "--- Expected ---" -ForegroundColor Green
if ($Expected.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor Gray
} else {
    $Expected | ForEach-Object { Write-Host "  [OK] $_" -ForegroundColor Green }
}

# Double-prefixed volumes
if ($DoublePrefixed.Count -gt 0) {
    $AnomalyFound = $true
    Write-Host ""
    Write-Host "--- DOUBLE-PREFIXED (anomaly) ---" -ForegroundColor Red
    $DoublePrefixed | ForEach-Object { Write-Host "  [DOUBLE-PREFIX] $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Recommended cleanup:" -ForegroundColor Yellow
    Write-Host "    docker volume rm $($DoublePrefixed -join ' ')" -ForegroundColor Gray
    Write-Host "    # Or: Remove-OrphanedVolumes -StackName $StackName -AgentConfigs `$cfg -CleanDoublePrefixed" -ForegroundColor Gray
}

# Legacy volumes
if ($Legacy.Count -gt 0) {
    $AnomalyFound = $true
    Write-Host ""
    Write-Host "--- LEGACY NAMING (anomaly) ---" -ForegroundColor Yellow
    $Legacy | ForEach-Object { Write-Host "  [LEGACY] $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  These volumes use old naming patterns. They should be removed if no longer needed:" -ForegroundColor Yellow
    Write-Host "    docker volume rm $($Legacy -join ' ')" -ForegroundColor Gray
}

# Unmatched volumes
if ($Unmatched.Count -gt 0) {
    $AnomalyFound = $true
    Write-Host ""
    Write-Host "--- UNMATCHED (potential orphans) ---" -ForegroundColor Yellow
    $Unmatched | ForEach-Object { Write-Host "  [UNMATCHED] $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  These volumes start with ${StackName}_ but don't match known patterns." -ForegroundColor Yellow
    Write-Host "  Investigate before removing:" -ForegroundColor Yellow
    Write-Host "    docker volume inspect $($Unmatched[0]) (example)" -ForegroundColor Gray
}

# Summary
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total ${StackName}_ volumes:  $($StackVolumes.Count)" -ForegroundColor Gray
Write-Host "  Expected:                    $($Expected.Count)" -ForegroundColor Green
Write-Host "  Double-prefixed:             $($DoublePrefixed.Count)" -ForegroundColor $(if ($DoublePrefixed.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Legacy naming:               $($Legacy.Count)" -ForegroundColor $(if ($Legacy.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Unmatched:                   $($Unmatched.Count)" -ForegroundColor $(if ($Unmatched.Count -gt 0) { "Yellow" } else { "Green" })

if ($AnomalyFound) {
    Write-Host "`n[RESULT] Anomalies detected. Review the report above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[RESULT] All volumes healthy — no anomalies detected." -ForegroundColor Green
    exit 0
}
