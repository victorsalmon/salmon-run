<#
.SYNOPSIS
    Resolves the Docker Swarm stack name for the current fleet.
.DESCRIPTION
    Returns the stack name from the health state, INSTALL_PROJECT env var,
    or by querying Docker Swarm stacks. Cached in module state.
#>
function Get-StackName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:FleetHealthState -and $script:FleetHealthState['StackName'] -and $script:FleetHealthState['StackName'] -ne 'unknown') {
        return $script:FleetHealthState['StackName']
    }
    if ($env:INSTALL_PROJECT) {
        return $env:INSTALL_PROJECT
    }
    try {
        $stacks = docker stack ls --format "{{.Name}}" 2>$null
        if ($stacks) {
            $name = ($stacks -split "`n" | Select-Object -First 1).Trim()
            if ($name) { return $name }
        }
    } catch { Write-SetupLog "Get-StackName: docker stack ls failed: $($_.Exception.Message)" -Level WARN }
    return "unknown"
}
