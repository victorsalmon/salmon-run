<#
.SYNOPSIS
    Reads a Docker Swarm secret bundle, trying multiple strategies.
.DESCRIPTION
    Docker 29.x+ no longer returns .Spec.Data in docker secret inspect.
    This function tries (1) Docker inspect, (2) docker exec into a running
    container, (3) connecting via the Docker API directly. Returns the
    bundle as a PSCustomObject or $null if all strategies fail.
.PARAMETER BundleName
    Docker Swarm secret name (e.g. FRAD_ORCH_secrets_bundle).
.PARAMETER ServiceName
    Docker Swarm service name for exec fallback (e.g. FRAD_oc-base).
.PARAMETER ContainerSecretPath
    Path inside the container (default /run/secrets/secrets_bundle).
#>
function Read-ContainerSecretBundle {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundleName,
        [string]$ServiceName,
        [string]$ContainerSecretPath = '/run/secrets/secrets_bundle'
    )

    # Strategy 1: docker secret inspect (works on some Docker versions)
    $InspectResult = try {
        docker secret inspect $BundleName --format '{{json .Spec.Data}}' 2>$null
    } catch { Write-Verbose "Read-ContainerSecretBundle strategy 1 (docker inspect) failed: $_"; $null }
    if ($InspectResult -and $InspectResult -ne 'null' -and $InspectResult -ne '<nil>') {
        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($InspectResult.Trim('"'))
            ) | ConvertFrom-Json
            if ($decoded) { return $decoded }
        } catch {
            Write-Verbose "Docker inspect strategy failed for ${BundleName}: $_"
        }
    }

    # Strategy 2: docker exec into a running container
    if ($ServiceName) {
        $ContainerLines = try {
            docker service ps $ServiceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null
        } catch { Write-Verbose "Read-ContainerSecretBundle strategy 2 (task list) failed: $_"; $null }
        $ContainerName = $ContainerLines | Select-Object -First 1
        if ($ContainerName) {
            $ExecResult = try {
                $prevEncoding = [Console]::OutputEncoding
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
                docker exec $ContainerName cat $ContainerSecretPath 2>$null
            } catch { Write-Verbose "Read-ContainerSecretBundle strategy 2 (docker exec) failed: $_"; $null }
            finally { [Console]::OutputEncoding = $prevEncoding }
            if ($ExecResult) {
                try {
                    return $ExecResult | ConvertFrom-Json
                } catch {
                    Write-Verbose "Docker exec JSON parse failed for ${ServiceName}: $_"
                }
            }
        } else {
            Write-Verbose "No running tasks found for service $ServiceName"
        }
    }

    return $null
}
