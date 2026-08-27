<#
.SYNOPSIS
    Removes Docker volumes orphaned by a previous stack deployment.
#>
function Remove-OrphanedVolumes {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$StackName,

        [Parameter(Mandatory)]
        [array]$AgentConfigs,

        [string[]]$ProtectPatterns = @(),

        [switch]$CleanDoublePrefixed,

        [switch]$UseLabels
    )

    $ProtectPatterns = @() + $ProtectPatterns
    Write-Information -MessageData "`n[CleanupStaleVolumes] Scanning for orphaned volumes..." -Tags "WARN"

    $ExpectedVolumes = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($AgentCfg in $AgentConfigs) {
        $svcName = Get-AgentServiceName -Role $AgentCfg.Role -Index $AgentCfg.Index
        [void]$ExpectedVolumes.Add("${StackName}_agent_config_${svcName}")
        [void]$ExpectedVolumes.Add("${StackName}_agent_persist_${svcName}")
    }
    if ($AgentConfigs.Count -gt 1) {
        [void]$ExpectedVolumes.Add("${StackName}_memory_shared")
    }
    [void]$ExpectedVolumes.Add("${StackName}_interclaw_workspace")
    [void]$ExpectedVolumes.Add("${StackName}_proxy_audit")
    # Sidecar data volumes declared by the generated compose must be preserved
    # even when the matching service is temporarily down (otherwise a post-deploy
    # cleanup race can wipe seeded data).
    @(
        "${StackName}_hermes_data"
        "${StackName}_docusign_data"
        "${StackName}_accounting_data"
        "${StackName}_interclaw_logs"
        "${StackName}_marketer_data"
        "${StackName}_ts_funnel_data"
    ) | ForEach-Object { [void]$ExpectedVolumes.Add($_) }

    # Ã¢"â‚¬Ã¢"â‚¬ Phase 2: Build volume list Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬
    if ($UseLabels) {
        Write-Information -MessageData "  [MODE] Using label-based detection for stack '$StackName'" -Tags "INFO"
        $AllStackVolumes = docker volume ls --filter "label=com.interclaw.stack=$StackName" --format "{{.Name}}" 2>$null
    } else {
        $AllStackVolumes = docker volume ls --format "{{.Name}}" 2>$null |
            Where-Object { $_ -match "^${StackName}_" }
    }

    # Ã¢"â‚¬Ã¢"â‚¬ Phase 3: Clean double-prefixed volumes Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬
    # These match ^${StackName}_ but have the stack name twice (e.g., FRAD_FRAD_*).
    # Remove them first and exclude from the orphan scan to avoid double-counting.
    $DoublePrefixCount = 0
    if ($CleanDoublePrefixed) {
        $AllStackVolumes = $AllStackVolumes | Where-Object {
            if ($_ -match "^${StackName}_${StackName}_") {
                $volName = $_
                $null = Invoke-DockerWithLogging -Command { docker volume rm $volName 2>&1 } -OperationLabel "Removing double-prefixed volume $volName"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [DOUBLE-PREFIX] Removed double-prefixed volume: $_" -ForegroundColor Magenta
                    Write-SetupLog "Double-prefixed volume removed: $_"
                    $DoublePrefixCount++
                } else {
                    Write-Information -MessageData "  [WARN] Could not remove double-prefixed volume $_ (in use?)" -Tags "WARN"
                    Write-SetupLog "Failed to remove double-prefixed volume: $_" -Level WARN
                }
                $false # exclude from orphan scan
            } else {
                $true # keep for orphan scan
            }
        }
        if ($DoublePrefixCount -eq 0) {
            Write-Information -MessageData "  [OK] No double-prefixed volumes found." -Tags "INFO"
        }
    }

    # Ã¢"â‚¬Ã¢"â‚¬ Phase 4: Remove orphans Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬Ã¢"â‚¬
    $OrphanCount = 0
    foreach ($VolName in $AllStackVolumes) {
        if (-not $ExpectedVolumes.Contains($VolName)) {
            $Protected = $false
            foreach ($Pattern in $ProtectPatterns) {
                if ($VolName -match [regex]::Escape($Pattern)) {
                    Write-Information -MessageData "  [WARN] Preserving legacy volume: $VolName (protect pattern: $Pattern)" -Tags "WARN"
                    Write-SetupLog "Preserving legacy volume: $VolName (protected)"
                    $Protected = $true
                    break
                }
            }
            if ($Protected) { continue }

            $capturedVolName = $VolName
            $null = Invoke-DockerWithLogging -Command { docker volume rm $capturedVolName 2>&1 } -OperationLabel "Removing orphaned volume $VolName"
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [CLEANUP] Removed orphaned volume: $VolName" -ForegroundColor Magenta
                Write-SetupLog "Orphaned volume removed: $VolName"
                $OrphanCount++
            } else {
                Write-Information -MessageData "  [WARN] Could not remove orphaned volume $VolName (in use?)" -Tags "WARN"
                Write-SetupLog "Failed to remove orphaned volume: $VolName" -Level WARN
            }
        }
    }

    if ($OrphanCount -eq 0 -and $DoublePrefixCount -eq 0) {
        Write-Information -MessageData "  [OK] No orphaned volumes found." -Tags "INFO"
    }
}

