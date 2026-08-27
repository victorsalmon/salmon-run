<#
.SYNOPSIS
    Verifies all required Docker Swarm secrets exist for each agent role.
#>
function Test-FleetSecretHydration {
    [OutputType([array])]
    param([array]$AgentRoles, [string]$StackName)
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[4] Secret Hydration"
    $BaseSecretSuffixes = @((Get-SecretSchema)['AwsId'].Suffix, (Get-SecretSchema)['AwsSecret'].Suffix, (Get-SecretSchema)['GatewayToken'].Suffix, (Get-SecretSchema)['OpenRouterApiKey'].Suffix)
    foreach ($Agent in $AgentRoles) {
        $SecretPrefix = Get-AgentSecretPrefix -Project $StackName -Role $Agent.Role -Index $Agent.Index
        $RoleKeys = if ($script:RoleProviderKeyMap.ContainsKey($Agent.Role)) { $script:RoleProviderKeyMap[$Agent.Role] } else { @() }
        foreach ($Suffix in ($BaseSecretSuffixes + $RoleKeys)) {
            $Found = docker secret ls --filter "name=${SecretPrefix}_${Suffix}" -q 2>$null
            if ([string]::IsNullOrWhiteSpace($Found)) {
                $r = Test-Step -Name "Secret ${SecretPrefix}_${Suffix}" -Passed:($Suffix -in @((Get-SecretSchema)['OpenRouterApiKey'].Suffix)) -Detail $(if ($Suffix -in @((Get-SecretSchema)['OpenRouterApiKey'].Suffix)) { "optional, not created" } else { "missing" }) -PassThru; if ($r) { $results.Add($r) }
            } else {
                $r = Test-Step -Name "Secret ${SecretPrefix}_${Suffix}" -Passed $true -Detail "exists" -PassThru; if ($r) { $results.Add($r) }
            }
        }
    }
    return $results.ToArray()
}
