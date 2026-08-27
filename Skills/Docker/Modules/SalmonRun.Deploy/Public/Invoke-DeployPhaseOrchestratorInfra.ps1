<#
.SYNOPSIS
    Provisions orchestrator-level infrastructure (IAM roles, policies).
.DESCRIPTION
    Delegates to Invoke-AgentOrchProvisioning using the first agent context
    for shared infrastructure setup like fleet IAM roles and Bedrock.
#>
function Invoke-DeployPhaseOrchestratorInfra {
    param(
        [string]$InstallAws,
        [array]$AgentConfigs,
        [string]$SsoProfile,
        [object]$Sovereignty
    )
    if ($InstallAws -eq "true") {
        $infraAgent = $AgentConfigs | Select-Object -First 1
        if ($infraAgent) {
            Write-Information -MessageData "`n--- ORCHESTRATOR INFRASTRUCTURE (via $($infraAgent.Role) agent) ---" -Tags "INFO"
            $allInstanceIds = $AgentConfigs | ForEach-Object { $_.InstanceId } | Where-Object { $_ }
            try {
                Invoke-AgentOrchProvisioning -AgentContext $infraAgent.AgentCtx -SsoProfile $SsoProfile -SovereigntyTier $Sovereignty.Tier -SecretsRegion $Sovereignty.SecretsRegion -AllInstanceIds $allInstanceIds
            } catch {
                Add-SetupError -Phase "AwsOrch" -Message "Orchestrator provisioning failed: $_" -Category "AWS"
                throw
            }
        } else {
            Write-SetupLog "No agents configured - skipping infrastructure operations" -Level WARN
        }
    }
}
