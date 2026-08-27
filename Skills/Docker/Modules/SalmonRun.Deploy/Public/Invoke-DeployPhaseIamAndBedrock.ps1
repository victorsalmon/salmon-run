<#
.SYNOPSIS
    Provisions IAM users and Bedrock access for all agent roles.
.DESCRIPTION
    Runs parallel IAM user creation via 1Provision.ps1 for remaining agents,
    collects results, and writes agent configs with gateway ports.
#>
function Invoke-DeployPhaseIamAndBedrock {
    param(
        [string]$SsoProfile,
        [object]$Sovereignty,
        [string]$ProjectCode,
        [array]$AgentRoles,
        [hashtable]$RoleNameMap,
        [string]$PSScriptRoot,
        [string]$RepoRoot,
        [string]$InstallOpencode,
        [string]$InstallBookkeeping,
        [string]$InstallJsonPath,
        [ref]$AgentConfigsRef,
        [ref]$GatewayTokenRef
    )

    if (-not $env:INTERCLAW_GATEWAY_TOKEN) {
        $persistedDir = "$env:USERPROFILE\.ORCHESTRATOR"
        $persistedTokenFile = Join-Path $persistedDir ".last-gateway-token"
        if (Test-Path $persistedTokenFile) {
            $env:INTERCLAW_GATEWAY_TOKEN = Get-Content $persistedTokenFile -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
            Write-SetupLog "Reusing persisted INTERCLAW_GATEWAY_TOKEN from $persistedTokenFile" -Level INFO
        }
        if (-not $env:INTERCLAW_GATEWAY_TOKEN) {
            $env:INTERCLAW_GATEWAY_TOKEN = New-CryptographicToken -ByteCount 48
            Write-SetupLog "Auto-generated INTERCLAW_GATEWAY_TOKEN (cryptographic) for agent bundle provisioning" -Level INFO
        }
        $null = New-Item -ItemType Directory -Path $persistedDir -Force
        $env:INTERCLAW_GATEWAY_TOKEN | Write-AtomicFile -Path $persistedTokenFile -Encoding utf8
        Restrict-FileAccess -Path $persistedTokenFile
    }
    $GatewayTokenRef.Value = $env:INTERCLAW_GATEWAY_TOKEN
    $InstallAws = "true"

    $remainingRoles = $AgentRoles | Where-Object {
        $agentName = "Agent-$ProjectCode-$($_.Role)-$($_.InstanceId)"
        -not (Test-SetupCheckpoint -Name "AgentProvisioning-$agentName")
    }
    if ($remainingRoles.Count -eq 0) {
        Write-Information -MessageData "  [SKIP] All agents already fully provisioned." -Tags "INFO"
        $AgentConfigsRef.Value = $AgentRoles | ForEach-Object { @{
            Role = $_.Role; Index = $_.Index; InstanceId = $_.InstanceId
            AgentName = "Agent-$ProjectCode-$($_.Role)-$($_.InstanceId)"
            GatewayPort = Get-AgentHostPort -Role $_.Role -Index $_.Index
            CustomName = if ($RoleNameMap.ContainsKey($_.Role)) { $RoleNameMap[$_.Role] } else { $null }
            DisplayName = if ($RoleNameMap.ContainsKey($_.Role)) { "$($RoleNameMap[$_.Role]) ($($_.Role)-$($_.InstanceId))" } else { "$($_.Role)-$($_.InstanceId)" }
        }}
        return
    }
    Write-SetupLog "Remaining agents to provision: $($remainingRoles.Count) / $($AgentRoles.Count)"

    $provisionScriptPath = Join-Path $PSScriptRoot "1Provision.ps1"

    $firstAgent = $remainingRoles | Select-Object -First 1
    if ($firstAgent) {
        $firstCtx = New-AgentContext -ProjectCode $ProjectCode -RoleCode $firstAgent.Role -InstanceId $firstAgent.InstanceId -Index $firstAgent.Index
        & $provisionScriptPath -Phase Secrets -AgentContext $firstCtx
        if ($LASTEXITCODE -ne 0) { throw "Secret hydration failed" }
    }

    $parallelResults = $remainingRoles | ForEach-Object -Parallel {
        $role = $_
        $currentRole = $role.Role
        $currentIndex = $role.Index
        $currentInstanceId = $role.InstanceId
        $currentRoleNameMap = $using:RoleNameMap
        $currentProjectCode = $using:ProjectCode
        $currentPSScriptRoot = $using:PSScriptRoot
        $currentProvisionScript = $using:provisionScriptPath
        $currentRepoRoot = $using:RepoRoot

        $null = Import-Module (Join-Path $currentRepoRoot "Skills" "Docker" "Modules" "SalmonRun.Identity" "SalmonRun.Identity.psd1") -Force -DisableNameChecking
        $null = Import-Module (Join-Path $currentRepoRoot "Skills" "Docker" "Modules" "SalmonRun.Ports" "SalmonRun.Ports.psd1") -Force -DisableNameChecking

        $currentAgentName = "Agent-$currentProjectCode-$currentRole-$currentInstanceId"

        Write-Information -MessageData "`n========================================" -Tags "INFO"
        Write-Information -MessageData "  AGENT $currentRole-$currentInstanceId : $currentAgentName" -Tags "INFO"
        Write-Information -MessageData "========================================" -Tags "INFO"

        $agentCtx = New-AgentContext -ProjectCode $currentProjectCode -RoleCode $currentRole -InstanceId $currentInstanceId -Index $currentIndex

        try {
            $currentGatewayPort = Get-AgentHostPort -Role $currentRole -Index $currentIndex
            $provisionOutput = & $currentProvisionScript -Phase AwsUser -AgentContext $agentCtx -ErrorAction Stop 2>&1
        } catch {
            return @{
                Success = $false
                AgentName = $currentAgentName
                Role = $currentRole
                InstanceId = $currentInstanceId
                Index = $currentIndex
                ErrorMessage = "AWS user provisioning failed for $currentAgentName - $_"
                Phase = "AwsUser"
            }
        }

        $customName = if ($currentRoleNameMap.ContainsKey($currentRole)) { $currentRoleNameMap[$currentRole] } else { $null }

        return @{
            Success = $true
            AgentName = $currentAgentName
            Role = $currentRole
            InstanceId = $currentInstanceId
            Index = $currentIndex
            GatewayPort = $currentGatewayPort
            CustomName = $customName
            DisplayName = if ($customName) { "$customName ($currentRole-$currentInstanceId)" } else { "$currentRole-$currentInstanceId" }
            AgentCtx = $agentCtx
            ErrorMessage = $null
            Phase = $null
        }
    } -ThrottleLimit 5

    $agentConfigs = @()
    $failedAgents = @()

    foreach ($result in $parallelResults) {
        if ($null -eq $result -or -not ($result -is [hashtable])) { continue }
        if ($result.Success) {
            $config = @{
                Role = $result.Role
                Index = $result.Index
                InstanceId = $result.InstanceId
                AgentName = $result.AgentName
                GatewayPort = $result.GatewayPort
                CustomName = $result.CustomName
                DisplayName = $result.DisplayName
                AgentCtx = $result.AgentCtx
            }
            $agentConfigs += $config
            Set-SetupCheckpoint -Name "AgentProvisioning-$($result.AgentName)"
            Write-Information -MessageData "  [OK] $($result.AgentName) provisioned successfully." -Tags "INFO"
        } else {
            $failedAgents += $result
            Write-SetupLog -Message "$($result.AgentName) failed at phase $($result.Phase): $($result.ErrorMessage)" -Level ERROR
        }
    }

    if ($failedAgents.Count -gt 0) {
        $errorSummary = ($failedAgents | ForEach-Object { "  $($_.AgentName) [$($_.Phase)]: $($_.ErrorMessage)" }) -join "`n"
        Write-SetupLog "FAIL: $($failedAgents.Count) agent(s) failed provisioning:`n$errorSummary" -Level ERROR
        throw "$($failedAgents.Count) agent(s) failed provisioning. See log for details."
    }

    $AgentConfigsRef.Value = $agentConfigs
    Write-SetupLog "=== Phase 9a: $($agentConfigs.Count) agent(s) IAM provisioned (parallel) ==="
}
