<#
.SYNOPSIS
    Returns the canonical key mapping for install.json. Used by Read-InstallJson and Update-InstallJsonKey.
#>
$script:InstallJsonKeyMap = @{
    'INSTALL_PROJECT'         = 'project.code'
    'PROJECT_CODE'            = 'project.code'
    'INTERCLAW_DOMAIN_SUFFIX'  = 'project.domainSuffix'
    'PUBLIC_DOMAIN'           = 'project.publicDomain'
    # AGENT_NUMBER, ROLE_CODE, AGENT_NAMES are computed from fleet.agents array
    'INTERCLAW_SOVEREIGNTY'    = 'fleet.sovereignty'
    'INSTALL_FLEET'          = 'features.fleet.install'
    'INSTALL_SENTRY'         = 'features.sentry.install'
    'INSTALL_TAILSCALE'       = 'features.tailscale.install'
    'INSTALL_DOCUSIGN'        = 'features.docusign.install'
    'INSTALL_BROWSERLESS'     = 'features.browserless.install'
    'INSTALL_OPENCODE'        = 'features.opencode.install'
    'INSTALL_BOOKKEEPING'      = 'features.Bookkeeper.install'
    'INSTALL_WEB_MCP'         = 'features.web-mcp.install'
    'INSTALL_AQE'             = 'features.mcp-aqe.install'
    'INSTALL_FUNNEL'          = 'features.funnel.install'

    'INSTALL_REKOGNITION_FALLBACK' = 'features.rekognition-fallback.install'
    'INSTALL_HERMES'          = 'features.hermes.install'
    'INSTALL_WORKSPACE_REPOS' = 'workspace.repos'
    'INTERCLAW_RUN_ID'         = 'runtime.runId'
    'REBUILD_INTERCLAW'        = 'runtime.rebuildInterclaw'
}

function Get-InstallJsonKeyMap {
    [CmdletBinding()]
    param()

    return $script:InstallJsonKeyMap
}

function Get-JsonValueByPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$JsonObj,
        [Parameter(Mandatory)]
        [string]$KeyPath
    )

    $Keys = $KeyPath.Split('.')
    $Current = $JsonObj
    foreach ($Key in $Keys) {
        if ($null -eq $Current) { return $null }
        $Current = $Current.$Key
    }
    return $Current
}

