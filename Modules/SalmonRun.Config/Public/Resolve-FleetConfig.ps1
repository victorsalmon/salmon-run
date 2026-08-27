<#
.SYNOPSIS
    Resolves the full fleet configuration from install.json, env vars, and defaults.
.DESCRIPTION
    Merges values from the provided InstallEnv object (usually from Read-InstallJson),
    environment variables, and hard-coded defaults into a unified fleet config hashtable.
.PARAMETER InstallEnv
    An install.json config object (from Read-InstallJson). Defaults to current install.json.
.PARAMETER ProjectOverride
    Optional override for the project code.
.OUTPUTS
    Hashtable of resolved fleet configuration values.
#>
function Resolve-FleetConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object]$InstallEnv = (Read-InstallJson),
        [string]$ProjectOverride
    )

    $Project = if (-not [string]::IsNullOrWhiteSpace($ProjectOverride)) { $ProjectOverride }
               elseif (-not [string]::IsNullOrWhiteSpace($env:INSTALL_PROJECT)) { $env:INSTALL_PROJECT }
               elseif ($InstallEnv -and $InstallEnv.project.code) { $InstallEnv.project.code }
    if (-not $Project) {
        throw "INSTALL_PROJECT not found in environment or install.json"
    }

    $StackName = $Project

    $InstallJson = $InstallEnv

    $Sovereignty = $env:INTERCLAW_SOVEREIGNTY
    if (-not $Sovereignty -and $InstallJson -and $InstallJson.fleet) { $Sovereignty = $InstallJson.fleet.sovereignty }
    if (-not $Sovereignty) { $Sovereignty = "global" }

    $DefaultDomainSuffix = $env:INTERCLAW_DOMAIN_SUFFIX
    if (-not $DefaultDomainSuffix -and $InstallJson -and $InstallJson.project.domainSuffix) { $DefaultDomainSuffix = $InstallJson.project.domainSuffix }
    if (-not $DefaultDomainSuffix) { $DefaultDomainSuffix = (Get-DefaultDomainSuffix) }

    $PublicDomain = $env:PUBLIC_DOMAIN
    if (-not $PublicDomain -and $InstallJson -and $InstallJson.project.publicDomain) { $PublicDomain = $InstallJson.project.publicDomain }
    if (-not $PublicDomain) { $PublicDomain = "$($Project.ToLower())$DefaultDomainSuffix" }

    # Derive RoleCode, AgentNumber, AgentRoles from fleet.agents array
    $AgentRoles = @()
    $RoleCode = $env:ROLE_CODE
    $AgentNumber = $env:AGENT_NUMBER
    if ($InstallJson -and $InstallJson.fleet -and $InstallJson.fleet.agents) {
        $agents = $InstallJson.fleet.agents
        if (-not $RoleCode) {
            $RoleCode = ($agents.role) -join ','
        }
        if (-not $AgentNumber) {
            $AgentNumber = "$($agents.Count)"
        }
        # Build AgentRoles from the array regardless of env overrides
        $counts = @{}
        foreach ($a in $agents) {
            $r = $a.role
            $idx = ($counts[$r] = ($counts[$r] + 1))
            $AgentRoles += @{ Role = $r; Index = ($idx - 1) }
        }
    }
    if (-not $RoleCode) { $RoleCode = "" }
    if (-not $AgentNumber) { $AgentNumber = "1" }
    $AgentNumber = [int]$AgentNumber

    $InstallFleet = $env:INSTALL_FLEET
    if (-not $InstallFleet -and $InstallJson -and $null -ne $InstallJson.features.fleet.install) { $InstallFleet = $InstallJson.features.fleet.install.ToString().ToLower() }
    if (-not $InstallFleet) { $InstallFleet = "true" }

    $InstallTailscale = $env:INSTALL_TAILSCALE
    if (-not $InstallTailscale -and $InstallJson -and $null -ne $InstallJson.features.tailscale.install) { $InstallTailscale = $InstallJson.features.tailscale.install.ToString().ToLower() }
    if (-not $InstallTailscale) { $InstallTailscale = "false" }

    $InstallOpencode = $env:INSTALL_OPENCODE
    if (-not $InstallOpencode -and $InstallJson -and $null -ne $InstallJson.features.opencode.install) { $InstallOpencode = $InstallJson.features.opencode.install.ToString().ToLower() }
    if (-not $InstallOpencode) { $InstallOpencode = "true" }

    return @{
        Project                      = $Project
        StackName                    = $StackName
        SovereigntyTier              = $Sovereignty
        PublicDomain                 = $PublicDomain
        WebhookUrl                   = "https://$PublicDomain/"
        SecretBasePath               = "salmon-run/FRAD"
        RoleCode                     = $RoleCode
        AgentNumber                  = $AgentNumber
        AgentRoles                   = $AgentRoles
        InstallFleet                = $InstallFleet
        InstallTailscale             = $InstallTailscale
        InstallOpencode              = $InstallOpencode
    }
}
