<#
.SYNOPSIS
    Force-redeploys one or more fleet container services via docker service update.
.DESCRIPTION
    Accepts a list of container names (short names like "mcp_opencode")
    or the flag -All to redeploy all allowed fleet services. Validates each
    name against the allowed service list before triggering the update.
.PARAMETER Containers
    Array of container service names to redeploy (short names, no stack prefix).
.PARAMETER All
    Switch to redeploy all allowed fleet services.
.PARAMETER StackName
    Docker stack name. Auto-resolves if not provided.
.OUTPUTS
    Hashtable array with container, exitCode, output per service.
#>
function Invoke-FleetContainerRedeploy {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([array])]
    param(
        [Parameter(ParameterSetName = 'List', Mandatory)]
        [string[]]$Containers,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [string]$StackName
    )

    if (-not $StackName) {
        $StackName = Resolve-StackName
    }

    $allowed = Get-AllowedFleetServices

    $serviceList = @()
    if ($All) {
        $result = Invoke-LocalCommand { docker service ls --filter "label=com.docker.stack.namespace=${StackName}" --format "{{.Name}}" 2>&1 }
        $serviceList = @($result.Output) | Where-Object {
            $short = $_ -replace "^${StackName}_", ""
            $short -in $allowed
        }
    } else {
        $serviceList = $Containers | ForEach-Object {
            if ($_ -match "^${StackName}_") { $_ } else { "${StackName}_$_" }
        }
        $serviceList = $serviceList | Where-Object {
            $short = $_ -replace "^${StackName}_", ""
            $short -in $allowed
        }
    }

    if ($serviceList.Count -eq 0) {
        Write-Warning "No allowed services to redeploy."
        return @()
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($svc in $serviceList) {
        $svcName = $svc -replace "^${StackName}_", ""
        try {
            $r = Invoke-LocalCommand { docker service update --force "$svc" 2>&1 }
            $results.Add(@{ container = $svcName; exitCode = $r.ExitCode; output = "$($r.Output)" })
            if ($r.Success) {
                Write-FleetLog "Redeployed $svcName successfully" -Level INFO
            } else {
                Write-FleetLog "Redeploy $svcName failed with exit code $($r.ExitCode)" -Level WARN
            }
        } catch {
            $results.Add(@{ container = $svcName; exitCode = 1; output = "$($_.Exception.Message)" })
            Write-FleetLog "Redeploy $svcName threw exception: $_" -Level ERROR
        }
    }
    return $results.ToArray()
}
