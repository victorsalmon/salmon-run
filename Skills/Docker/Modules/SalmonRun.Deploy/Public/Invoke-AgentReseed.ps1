<#
.SYNOPSIS
    Re-seeds agent config volumes with updated .md files and restarts services.
.DESCRIPTION
    Discovers running agent services from a Docker Swarm stack, resolves {OWNER_*}
    placeholders in .md files, batch-copies them into each agent's config volume,
    and optionally force-restarts the service to pick up changes.
.PARAMETER StackName
    Docker stack name. Auto-detected via Get-StackName if not provided.
.PARAMETER Roles
    Agent roles to reseed (e.g. @("BASE")). Default: all roles discovered in stack.
.PARAMETER File
    Specific file(s) to re-seed (e.g. "agents.md"). Default: all role files + shared files.
.PARAMETER OwnerPlaceholders
    Hashtable of {OWNER_*} placeholder values. Auto-loaded via Get-OwnerPlaceholders if omitted.
.PARAMETER Restart
    Whether to force-restart service after reseed. Default: $true.
.PARAMETER Force
    Skip confirmation prompts (for unattended use).
.OUTPUTS
    Hashtable with keys Total, Succeeded, Failed.
.EXAMPLE
    Invoke-AgentReseed -Restart -Force
    Re-seeds all agents in the auto-detected stack and restarts them.
.EXAMPLE
    Invoke-AgentReseed -Roles @("BASE") -Restart:$false
    Re-seeds BASE config volume without restarting the service.
#>
function Invoke-AgentReseed {
    [OutputType([hashtable])]
    param(
        [string]$StackName,
        [string[]]$Roles,
        [string[]]$File,
        [hashtable]$OwnerPlaceholders,
        [bool]$Restart = $true,
        [switch]$Force
    )

    if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) { Write-SetupLog "Invoke-AgentReseed start" -Level INFO }

    # --- Auto-detect StackName ---
    if (-not $StackName) {
        if (Get-Command Get-StackName -ErrorAction SilentlyContinue) {
            $StackName = Get-StackName
        }
        if (-not $StackName) {
            throw "Could not resolve stack name. Pass -StackName or ensure Get-StackName is available."
        }
    }

    Write-Information -MessageData "`n=== Invoke-AgentReseed: Stack=$StackName ===" -Tags "INFO"

    # --- Auto-load OwnerPlaceholders ---
    if (-not $OwnerPlaceholders) {
        if (Get-Command Get-OwnerPlaceholders -ErrorAction SilentlyContinue) {
            $OwnerPlaceholders = Get-OwnerPlaceholders
        }
    }

    # --- Determine project root ---
    $ProjectRoot = if (Get-Command Get-InterclawRepoRoot -ErrorAction SilentlyContinue) { Get-InterclawRepoRoot } elseif ($script:ModuleRoot) { Resolve-Path "$script:ModuleRoot\..\..\..\.." } else { $PWD.Path }

    # --- Discover agent (role, index) pairs from the stack ---
    $servicePs = docker stack ps $StackName --filter "desired-state=Running" --format "{{.Name}}" 2>$null
    $agentPairs = [System.Collections.Generic.List[pscustomobject]]::new()
    $seenKeys = @{}

    foreach ($line in $servicePs) {
        if ($line -match '^\w+_oc-(\w+)(?:-(\d+))?\.\d+$') {
            $role = $matches[1].ToUpper()
            $index = if ($matches[2]) { [int]$matches[2] } else { 0 }
            $key = "${role}-${index}"
            if (-not $seenKeys.ContainsKey($key)) {
                $seenKeys[$key] = $true
                if (-not $Roles -or $Roles.Count -eq 0 -or $Roles -contains $role) {
                    $agentPairs.Add([pscustomobject]@{ Role = $role; Index = $index })
                }
            }
        }
    }

    if ($agentPairs.Count -eq 0) {
        Write-Information -MessageData "  [WARN] No agent services found in stack '$StackName'" -Tags "WARN"
        if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) { Write-SetupLog "Invoke-AgentReseed: no agents found in stack $StackName" -Level WARN }
        return @{ Total = 0; Succeeded = 0; Failed = 0 }
    }

    $agentLabels = ($agentPairs | ForEach-Object { "$($_.Role)-$($_.Index)" }) -join ', '
    Write-Information -MessageData "  Agents: $($agentPairs.Count) found ($agentLabels)" -Tags "INFO"

    # --- Load file maps ---
    $roleFileMap = if (Get-Command Get-RoleFileMap -ErrorAction SilentlyContinue) { Get-RoleFileMap } else { $null }
    $sharedFiles = if (Get-Command Get-SharedFiles -ErrorAction SilentlyContinue) { Get-SharedFiles } else { @() }

    $totalAgents = $agentPairs.Count
    $succeededAgents = 0
    $failedAgents = 0

    foreach ($agent in $agentPairs) {
        $role = $agent.Role
        $index = $agent.Index
        $svcName = Get-AgentServiceName -Role $role -Index $index
        $configVol = Get-AgentVolumeName -StackName $StackName -VolumeType agent_config -Role $role -Index $index

        Write-Information -MessageData "`n  [Agent] $role-$index ($svcName)" -Tags "WARN"
        Write-Information -MessageData "    Volume: $configVol" -Tags "INFO"

        try {
            $volExists = docker volume ls -q -f "name=$configVol" 2>$null
            if (-not $volExists) {
                Write-Information -MessageData "    [SKIP] Volume not found: $configVol" -Tags "INFO"
                $succeededAgents++
                continue
            }

            # --- Determine files to seed ---
            $roleFiles = if ($roleFileMap -and $roleFileMap.ContainsKey($role)) { $roleFileMap[$role] } elseif ($roleFileMap) { $roleFileMap["BASE"] } else { @() }
            $filesToSeed = if ($File -and $File.Count -gt 0) { $File } else { $roleFiles + $sharedFiles }

            # --- Build file batch with placeholder resolution ---
            $roleDir = Join-Path $ProjectRoot "Agents" $role
            $sharedDir = Join-Path $ProjectRoot "Agents" "Shared"
            $configFiles = [System.Collections.Generic.List[hashtable]]::new()
            $tempFiles = [System.Collections.Generic.List[string]]::new()
            $configSeen = @{}

            foreach ($fileName in $filesToSeed) {
                $targetName = $fileName
                $sourcePath = Join-Path $roleDir $fileName

                if (-not (Test-Path $sourcePath)) {
                    $sharedPath = Join-Path $sharedDir $fileName
                    if (Test-Path $sharedPath) {
                        $sourcePath = $sharedPath
                        $targetName = if ($fileName -eq "User.md") { "user.md" } else { $fileName.ToLower() }
                    }
                }

                if (-not (Test-Path $sourcePath)) {
                    Write-Information -MessageData "    [SKIP] File not found: $fileName" -Tags "INFO"
                    continue
                }

                if ($configSeen.ContainsKey($targetName)) { continue }
                $configSeen[$targetName] = $true

                if ($OwnerPlaceholders -and $OwnerPlaceholders.Count -gt 0) {
                    $content = Get-Content $sourcePath -Raw -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        $resolved = Resolve-StringPlaceholders -Text $content -PlaceholderMap $OwnerPlaceholders
                        $tmpFile = Join-Path $env:TEMP "oc-reseed-$([Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"
                        [System.IO.File]::WriteAllText($tmpFile, $resolved, [System.Text.UTF8Encoding]::new($false))
                        $tempFiles.Add($tmpFile)
                        $configFiles.Add(@{ Source = $tmpFile; Target = $targetName })
                        continue
                    }
                }

                $configFiles.Add(@{ Source = $sourcePath; Target = $targetName })
            }

            # --- Batch copy to config volume ---
            if ($configFiles.Count -gt 0) {
                $copyResult = Copy-FilesToVolume -VolumeName $configVol -Files $configFiles.ToArray() `
                    -Description "Reseed: $role-$index ($($configFiles.Count) files)"

                if (-not $copyResult) {
                    throw "Copy-FilesToVolume returned false for $role-$index"
                }
            }

            Write-Information -MessageData "    [OK] Seeded $($configFiles.Count) files" -Tags "INFO"

            # --- Restart service ---
            if ($Restart) {
                $fullSvcName = "${StackName}_${svcName}"
                Write-Information -MessageData "    Restarting $fullSvcName..." -Tags "WARN"

                if (Get-Command Restart-FleetService -ErrorAction SilentlyContinue) {
                    Restart-FleetService -ServiceName $fullSvcName
                }
                else {
                    $output = docker service update --force $fullSvcName 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "docker service update --force failed: $output"
                    }
                }

                Write-Information -MessageData "    [OK] $fullSvcName restarted" -Tags "INFO"
            }

            $succeededAgents++
            if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) { Write-SetupLog "Invoke-AgentReseed: $role-$index succeeded" -Level INFO }
        }
        catch {
            Write-Information -MessageData "    [FAIL] $role-$index : $($_.Exception.Message)" -Tags "ERROR"
            if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) { Write-SetupLog "Invoke-AgentReseed: $role-$index failed: $($_.Exception.Message)" -Level ERROR }
            $failedAgents++
        }
        finally {
            foreach ($tf in $tempFiles) {
                Remove-Item $tf -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $summary = @{
        Total     = $totalAgents
        Succeeded = $succeededAgents
        Failed    = $failedAgents
    }

    Write-Information -MessageData "`n=== Reseed complete: $succeededAgents/$totalAgents succeeded ($failedAgents failed) ===" -Tags "INFO"
    if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) { Write-SetupLog "Invoke-AgentReseed complete: $succeededAgents/$totalAgents succeeded" -Level INFO }

    return $summary
}

