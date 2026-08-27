<#
.SYNOPSIS
    Returns the role-to-config-files mapping for agent volume seeding.
.DESCRIPTION
    Returns a hashtable mapping each agent role (ORCH, VERI, BASE, WORK) to its
    list of .md config files. Used by Initialize-AgentVolumes to determine which
    files to copy into each agent's config volume.
.OUTPUTS
    Hashtable of role -> string[] file lists.
#>
function Get-RoleFileMap {
    [OutputType([hashtable])]
    param()
    return $script:RoleFileMap
}
