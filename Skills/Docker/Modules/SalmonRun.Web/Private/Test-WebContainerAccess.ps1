<#
.SYNOPSIS
Verifies that the current container is allowed to access web MCP services.
.PARAMETER AllowedContainers
List of container name patterns that are permitted access.
#>
function Test-WebContainerAccess {
    [CmdletBinding()]
    param(
        [string[]]$AllowedContainers = @('opencode', 'ORCHESTRATOR')
    )

    $containerName = $env:CONTAINER_NAME
    if (-not $containerName) {
        throw [System.UnauthorizedAccessException]::new("Container access denied: CONTAINER_NAME environment variable is not set")
    }

    $matched = $false
    foreach ($allowed in $AllowedContainers) {
        if ($containerName -like $allowed) {
            $matched = $true
            break
        }
    }

    if (-not $matched) {
        throw [System.UnauthorizedAccessException]::new("Container access denied: '$containerName' is not in the allowed list: $($AllowedContainers -join ', ')")
    }

    return $true
}
