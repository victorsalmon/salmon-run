<#
.SYNOPSIS
    Hydrates Docker Swarm secrets from AWS Secrets Manager.
.DESCRIPTION
    Reads Interclaw/FRAD/Orchestrator and Interclaw/FRAD/Provisioning
    secrets from AWS SM to hydrate local env vars and Docker Swarm secrets.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Invoke-SecretHydration {
    [OutputType([void])]
    param(
        [PSCustomObject]$AgentContext
    )

    Write-SetupLog "1Secrets started"

    $SsoProfile = $env:AWS_SSO_PROFILE

    Write-SetupLog "Phase 1: Verifying orchestrator identity"

    $Project = if ($AgentContext) { $AgentContext.ProjectCode } else { $env:INSTALL_PROJECT }
    $Role = if ($AgentContext) { $AgentContext.RoleCode } else { $env:INSTALL_ROLE }
    $InstanceID = if ($AgentContext) { $AgentContext.InstanceId } else { $env:INTERCLAW_INSTANCE_ID }

    if ([string]::IsNullOrWhiteSpace($Project)) {
        Write-SetupLog "FAIL: INSTALL_PROJECT not set" -Level ERROR
        Write-Warning "  [CRITICAL ERROR] INSTALL_PROJECT is not set. This should be set by 0setup.ps1."
        throw "INSTALL_PROJECT is not set. This should be set by 0setup.ps1."
    }
    if ([string]::IsNullOrWhiteSpace($Role)) {
        Write-SetupLog "FAIL: INSTALL_ROLE not set" -Level ERROR
        Write-Warning "  [CRITICAL ERROR] INSTALL_ROLE is not set. This should be set by 0setup.ps1."
        throw "INSTALL_ROLE is not set. This should be set by 0setup.ps1."
    }

    Write-SetupLog "Phase 1 complete: identity verified"
    Write-SetupLog "Phase 2: Hydrating identity secrets from AWS"
    Write-Verbose "`n[SECRETS] Pulling identity secrets on demand..."

    # Hydrate the baseline keys this script owns
    Import-SecretsFromAws -Keys (Get-SecretsOwnedKeys -List Secrets) -SsoProfile $SsoProfile -SourceLabel "Identity"
    Write-SetupLog "Phase 2 complete: identity secrets hydrated"

    # Individual Docker secret creation is removed '" secrets are now bundled
    # per container type in New-AgentIamUser (agent bundles), New-FleetIamUser
    # (fleet bundle), Publish-CodingKeySecrets (coding bundle), and
    # Publish-FleetStack (proxy bundle). This reduces ~42 Docker CLI calls
    # to ~5 per deploy.
    #
    # Values are hydrated into env vars by Import-SecretsFromAws above and
    # are available to the subsequent bundle-creation phases.

    Write-Verbose "  [SECRETS] Phase complete."
    Write-SetupLog "1Secrets complete"
}
