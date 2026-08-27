<#
.SYNOPSIS
    Validates and writes the fleet compose definition to disk.
.DESCRIPTION
    Checks that all services have images, validates deploy key structure,
    serializes to YAML, and writes the output file atomically.
#>
function Compile-FleetComposeOutput {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Compose,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Agents,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    foreach ($svcName in $Compose.services.Keys) {
        $svc = $Compose.services[$svcName]
        if ([string]::IsNullOrWhiteSpace($svc.image)) {
            throw "Compile-FleetComposeOutput: Service '$svcName' has no image reference - every service must specify an image"
        }
    }

    $forbiddenDeployKeys = @('healthcheck')
    foreach ($svcName in $Compose.services.Keys) {
        $svc = $Compose.services[$svcName]
        if ($svc.deploy -is [hashtable] -or $svc.deploy -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($forbidden in $forbiddenDeployKeys) {
                if ($svc.deploy.Contains($forbidden)) {
                    throw "Compile-FleetComposeOutput: Service '$svcName' has '$forbidden' nested under 'deploy' - this is not valid in Docker Compose v3. Move it to the service level"
                }
            }
        }
    }

    $Yaml = ConvertTo-ComposeYaml -InputObject $Compose
    Write-AtomicFile -Path $OutputPath -Value $Yaml -Encoding UTF8
    Write-SetupLog "Generated fleet compose at: $OutputPath ($($Agents.Count) agents)"
    return $OutputPath
}
