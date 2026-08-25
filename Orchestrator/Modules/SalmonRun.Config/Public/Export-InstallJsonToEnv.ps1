<#
.SYNOPSIS
    Exports a curated subset of install.json values to process-level environment variables.
.DESCRIPTION
    Reads install.json (either from a provided object, a specified path, or the default location)
    and sets environment variables for the most commonly needed values (project code, agent roles,
    sovereignty, feature toggles). Intentionally exports ~8 of the ~20 available keys -- callers
    needing the full set should use Read-InstallJson directly.
.PARAMETER InstallJson
    An already-parsed install.json object. If omitted, the function reads from Path or the default location.
.PARAMETER Path
    Path to an install.json file. Ignored if InstallJson is provided.
.PARAMETER Force
    If set, uses ErrorAction Stop for environment variable writes, surfacing failures immediately.
#>
function Export-InstallJsonToEnv {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [object]$InstallJson,
        [string]$Path,
        [switch]$Force
    )

    if (-not $InstallJson -and $Path) {
        $InstallJson = Read-InstallJson -Path $Path
    }
    if (-not $InstallJson) {
        $InstallJson = Read-InstallJson
    }
    if (-not $InstallJson) { return }

    # NOTE: This function exports a deliberate subset (~8/20) of the most
    # commonly needed env vars. Callers needing the full set should read
    # install.json directly via Read-InstallJson.
    $ea = if ($Force) { 'Stop' } else { 'SilentlyContinue' }

    if ($InstallJson.project.code) {
        Set-Item -Path "Env:\INSTALL_PROJECT" -Value $InstallJson.project.code -ErrorAction $ea
        Set-Item -Path "Env:\PROJECT_CODE" -Value $InstallJson.project.code -ErrorAction $ea
    }
    if ($InstallJson.fleet -and $InstallJson.fleet.agents) {
        $agents = $InstallJson.fleet.agents
        $roleCode = ($agents.role) -join ','
        if ($roleCode) {
            Set-Item -Path "Env:\ROLE_CODE" -Value $roleCode -ErrorAction $ea
        }
        if ($agents.Count -eq 1 -and $agents[0].role) {
            Set-Item -Path "Env:\INSTALL_ROLE" -Value $agents[0].role -ErrorAction $ea
        } elseif ($roleCode) {
            Set-Item -Path "Env:\INSTALL_ROLE" -Value $roleCode -ErrorAction $ea
        }
        Set-Item -Path "Env:\AGENT_NUMBER" -Value "$($agents.Count)" -ErrorAction $ea
    }
    if ($InstallJson.fleet -and $InstallJson.fleet.sovereignty) {
        Set-Item -Path "Env:\INTERCLAW_SOVEREIGNTY" -Value $InstallJson.fleet.sovereignty -ErrorAction $ea
    }
    if ($InstallJson.project.domainSuffix) {
        Set-Item -Path "Env:\INTERCLAW_DOMAIN_SUFFIX" -Value $InstallJson.project.domainSuffix -ErrorAction $ea
    }
    if ($null -ne $InstallJson.features.fleet.install) {
        Set-Item -Path "Env:\INSTALL_FLEET" -Value $InstallJson.features.fleet.install.ToString().ToLower() -ErrorAction $ea
    }
    if ($null -ne $InstallJson.features.tailscale.install) {
        Set-Item -Path "Env:\INSTALL_TAILSCALE" -Value $InstallJson.features.tailscale.install.ToString().ToLower() -ErrorAction $ea
    }
}
