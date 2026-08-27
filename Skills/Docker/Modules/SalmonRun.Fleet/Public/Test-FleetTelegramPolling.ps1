<#
.SYNOPSIS
    Checks ORCH containers for Telegram polling stalls in recent logs.
#>
function Test-FleetTelegramPolling {
    [OutputType([array])]
    param([string]$StackName)
    Write-Verbose "`n[10] Telegram Polling Health"
    $results = [System.Collections.Generic.List[object]]::new()
    $OrchContainers = docker ps --filter "name=oc-base" --format "{{.Names}}" 2>$null
    foreach ($ContainerName in $OrchContainers) {
        $StallCount = @([regex]::Matches((docker logs $ContainerName --since 20m 2>&1 | Out-String), "Polling stall detected")).Count
        $results.Add((Test-Step -Name "Telegram polling: $ContainerName" -Passed:($StallCount -lt 2) -Detail "$StallCount stalls in last 20m" -Remediation $(if ($StallCount -ge 2) { "Force restart: docker service update --force ${StackName}_oc-orch" } else { "" }) -PassThru))
    }
    return $results.ToArray()
}
