<#
.SYNOPSIS
    Returns the list of shared agent config files for volume seeding.
.DESCRIPTION
    Returns an array of .md file names that are shared across all agent roles
    (User.md, environment.md, boundaries.md, protocols.md, projects.md).
    Used by Initialize-AgentVolumes to copy shared files into config volumes.
.OUTPUTS
    String[] of shared file names.
#>
function Get-SharedFiles {
    [OutputType([string[]])]
    param()
    return $script:SharedFiles
}
