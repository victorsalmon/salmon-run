<#
.SYNOPSIS
    Runs credential isolation tests for all provisioned agents.
.DESCRIPTION
    Iterates agent configurations and invokes per-agent credential isolation
    verification against AWS IAM boundaries.
#>
function Invoke-DeployPhaseCredentialIsolation {
    param(
        [string]$InstallAws,
        [hashtable[]]$AgentConfigs,
        [string]$SsoProfile
    )
    if ($InstallAws -eq "true") {
        foreach ($agent in $AgentConfigs) {
            Write-Information -MessageData "`n--- CREDENTIAL ISOLATION TEST ($($agent.AgentName)) ---" -Tags "INFO"
            try {
                Invoke-AgentCredentialTests -AgentContext $agent.AgentCtx -SsoProfile $SsoProfile
            } catch {
                Add-SetupError -Phase "AwsTest" -Message "Credential isolation test failed for $($agent.AgentName): $_" -Category "AWS"
                throw
            }
        }
    }
}
