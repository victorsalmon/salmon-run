<#
.SYNOPSIS
    Checks all CODE containers are running, healthy, and reports their identity metadata.
.DESCRIPTION
    Inspects both compose-defined (code-*) and fleet-spawned CODE containers.
    Reports run-id, creation timestamp, role, and crash history for each container.
    Enables tracing a failing container back to the setup run that created it.
#>
function Test-FleetCodeHealth {
    [OutputType([array])]
    param([array]$StackServices)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[CODE Containers] Health & Identity"

    $AllSvcNames = if ($StackServices) {
        $StackServices | ForEach-Object { ($_ -split "`t")[0] }
    } else {
        $stack = Get-StackName
        if ($stack) { docker stack services $stack --format "{{.Name}}" 2>$null } else { @() }
    }

    $CodeSvcs = $AllSvcNames | Where-Object { $_ -match '^code-' }
    if (-not $CodeSvcs) {
        $r = Test-Step -Name "CODE containers present" -Passed $false -Detail "No CODE services found in stack" -PassThru; if ($r) { $results.Add($r) }
        return $results.ToArray()
    }

    foreach ($SvcName in $CodeSvcs) {
        $Labels = docker service inspect $SvcName --format '{{json .Spec.Labels}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

        $RunId = if ($Labels) { $Labels.'interclaw.run-id' } else { $null }
        $CreatedAt = if ($Labels) { $Labels.'interclaw.created-at' } else { $null }
        $MaxLifetime = if ($Labels) { $Labels.'interclaw.max-lifetime' } else { $null }
        $PlatformManaged = if ($Labels -and $Labels.'interclaw.managed' -eq 'true') { $true } else { $false }

        $ContainerLine = docker ps --filter "name=$SvcName" --format "{{.ID}}|{{.Names}}|{{.Status}}" 2>$null | Where-Object { $_ -match "$SvcName\." } | Select-Object -First 1
        if (-not $ContainerLine) {
            $ContainerLine = docker ps --all --filter "name=$SvcName" --format "{{.ID}}|{{.Names}}|{{.Status}}" 2>$null | Where-Object { $_ -match "$SvcName\." } | Select-Object -First 1
        }

        $IdentityDetail = if ($RunId) { "run=$RunId" } else { "no-run-id" }
        if ($CreatedAt) { $IdentityDetail += " created=$CreatedAt" }
        if ($PlatformManaged -and $MaxLifetime) { $IdentityDetail += " ttl=${MaxLifetime}s" }

        if (-not $ContainerLine) {
            $r = Test-Step -Name "CODE $SvcName" -Passed $false -Detail "No container found [$IdentityDetail]" -Remediation "Check docker service ps $SvcName for scheduling errors" -PassThru; if ($r) { $results.Add($r) }
            continue
        }

        $Parts = $ContainerLine -split "\|"
        $ContainerId = $Parts[0]
        $Status = if ($Parts.Count -gt 2) { $Parts[2] } else { "unknown" }

        $IsHealthy = $Status -match "Up|healthy"
        $r = Test-Step -Name "CODE $SvcName" -Passed $IsHealthy -Detail "${Status} [$IdentityDetail]" -Remediation $(if (-not $IsHealthy) { "Check logs: docker service logs $SvcName ; trace run=$RunId in setup-*.log" }) -PassThru; if ($r) { $results.Add($r) }

        $ExitCount = @(docker ps --all --filter "name=$SvcName" --format "{{.Names}}|{{.Status}}" 2>$null | Where-Object { $_ -match "$SvcName\." -and $_ -match "Exited" }).Count
        if ($ExitCount -gt 0) {
            $r = Test-Step -Name "CODE $SvcName crash history" -Passed $false -Detail "$ExitCount previous exit(s) [$IdentityDetail]" -PassThru; if ($r) { $results.Add($r) }
        }
    }
    return $results.ToArray()
}
