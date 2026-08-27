<#
.SYNOPSIS
    Creates an AgentContext object capturing per-agent identity in a single snapshot.
.DESCRIPTION
    Reads INSTALL_PROJECT, INSTALL_ROLE, INTERCLAW_INSTANCE_ID, and
    INTERCLAW_AGENT_INDEX from environment variables and returns a
    [PSCustomObject] with all derived identity values. This object
    should be passed to provisioning functions instead of letting them
    re-read env vars, which are process-wide and unsafe in parallel
    runspaces.

    Supports override parameters for each field so callers can supply
    values directly without touching env vars.
.PARAMETER ProjectCode
    Override for INSTALL_PROJECT. If not provided, reads from env.
.PARAMETER RoleCode
    Override for INSTALL_ROLE. If not provided, reads from env.
.PARAMETER InstanceId
    Override for INTERCLAW_INSTANCE_ID. If not provided, reads from env.
.PARAMETER Index
    Override for INTERCLAW_AGENT_INDEX. If not provided, reads from env.
.OUTPUTS
    PSCustomObject with: ProjectCode, RoleCode, InstanceId, Index,
    AgentName, GatewayPort, SecretPrefix, SovereigntyTier
#>
function New-AgentContext {
    [OutputType([pscustomobject])]
    param(
        [string]$ProjectCode,
        [string]$RoleCode,
        [string]$InstanceId,
        [int]$Index = -1
    )

    if (-not $ProjectCode) {
        if ([string]::IsNullOrWhiteSpace($env:INSTALL_PROJECT)) {
            throw "New-AgentContext: INSTALL_PROJECT is not set and no -ProjectCode provided"
        }
        $ProjectCode = $env:INSTALL_PROJECT
    }

    if (-not $RoleCode) {
        if ([string]::IsNullOrWhiteSpace($env:INSTALL_ROLE)) {
            throw "New-AgentContext: INSTALL_ROLE is not set and no -RoleCode provided"
        }
        $RoleCode = $env:INSTALL_ROLE
    }

    if (-not $InstanceId) {
        $InstanceId = $env:INTERCLAW_INSTANCE_ID
        if ([string]::IsNullOrWhiteSpace($InstanceId)) { $InstanceId = "0" }
    }

    if ($Index -lt 0) {
        $rawIndex = $env:INTERCLAW_AGENT_INDEX
        $Index = if ([string]::IsNullOrWhiteSpace($rawIndex)) { 0 } else { try { [int]$rawIndex } catch { Write-Warning "New-AgentContext: Invalid INTERCLAW_AGENT_INDEX '$rawIndex' — defaulting to 0"; 0 } }
    }

    $GatewayPort = Get-AgentHostPort -Role $RoleCode -Index $Index
    $SecretPrefix = Get-AgentSecretPrefix -Project $ProjectCode -Role $RoleCode -Index $Index
    $AgentName = "Agent-${ProjectCode}-${RoleCode}-${InstanceId}"
    $SovereigntyTier = if ($env:INTERCLAW_SOVEREIGNTY) { $env:INTERCLAW_SOVEREIGNTY } else { "global" }

    return [PSCustomObject]@{
        ProjectCode     = $ProjectCode
        RoleCode        = $RoleCode
        InstanceId      = $InstanceId
        Index           = $Index
        AgentName       = $AgentName
        GatewayPort     = $GatewayPort
        SecretPrefix    = $SecretPrefix
        SovereigntyTier = $SovereigntyTier
    }
}
