<#
.SYNOPSIS
    Verifies Docker volumes exist per agent and cleans double-prefixed volumes.
#>
function Test-FleetVolumeIntegrity {
    [OutputType([array])]
    param([string]$StackName, [array]$AgentRoles, [array]$AllVolumes)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[3] Volume Integrity"
    foreach ($Agent in $AgentRoles) {
        $ConfigVol = Get-AgentVolumeName -StackName $StackName -VolumeType "agent_config" -Role $Agent.Role -Index $Agent.Index
        $PersistVol = Get-AgentVolumeName -StackName $StackName -VolumeType "agent_persist" -Role $Agent.Role -Index $Agent.Index
        $r = Test-Step -Name "Volume $ConfigVol" -Passed:($AllVolumes -contains $ConfigVol) -PassThru; if ($r) { $results.Add($r) }
        $r = Test-Step -Name "Volume $PersistVol" -Passed:($AllVolumes -contains $PersistVol) -PassThru; if ($r) { $results.Add($r) }
    }
    $DoublePrefixedVolumes = $AllVolumes | Where-Object { $_ -match "^${StackName}_${StackName}_" }
    if ($DoublePrefixedVolumes.Count -gt 0) {
        $CleanedCount = 0
        foreach ($VolName in $DoublePrefixedVolumes) { $capturedV = $VolName; $null = Invoke-DockerWithLogging -Command { docker volume rm $capturedV 2>&1 } -OperationLabel "Cleanup double-prefixed volume $VolName"; if ($LASTEXITCODE -eq 0) { $CleanedCount++ } }
        $r = Test-Step -Name "Double-prefixed volumes cleanup" -Passed $true -Detail "$CleanedCount of $($DoublePrefixedVolumes.Count) cleaned up" -PassThru; if ($r) { $results.Add($r) }
    } else {
        $r = Test-Step -Name "Double-prefixed volumes cleanup" -Passed $true -Detail "none found" -PassThru; if ($r) { $results.Add($r) }
    }
    return $results.ToArray()
}
