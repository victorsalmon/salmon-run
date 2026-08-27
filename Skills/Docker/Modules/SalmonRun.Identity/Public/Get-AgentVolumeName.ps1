<#
.SYNOPSIS
    Builds a Docker volume name for an agent's config or persist volume.
.PARAMETER StackName
    Docker stack/project name.
.PARAMETER VolumeType
    Volume type (e.g. agent_config, agent_persist).
.PARAMETER Role
    Agent role (e.g. ORCH, VERI, BASE).
.PARAMETER Index
    Instance index; passed to Get-AgentServiceName.
.OUTPUTS
    String volume name (e.g. FRAD_agent_config_oc-base).
#>
function Get-AgentVolumeName {
    [OutputType([string])]
    param([string]$StackName, [string]$VolumeType, [string]$Role, [int]$Index = 0)
    $svcName = Get-AgentServiceName -Role $Role -Index $Index
    return "${StackName}_${VolumeType}_${svcName}"
}
