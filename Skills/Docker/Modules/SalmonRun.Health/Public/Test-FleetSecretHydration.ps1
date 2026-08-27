<#
.SYNOPSIS
    Verifies all required Docker Swarm secrets exist for each agent role.
.DESCRIPTION
    Tests that every Docker Swarm secret expected for each agent role has been
    created and is available. Uses the bundle manifest schema from Get-SecretSchema
    to determine which suffixes exist. The -OptionalSuffixes parameter controls
    which suffixes are treated as optional (missing is not a failure).
    
    Secret suffix scheme: Each agent role has a set of secret suffixes (e.g. AwsId,
    AwsSecret, GatewayToken, OpenRouterApiKey). The full secret name is
    <StackName>_<Role>_<Index>_<Suffix>. Optional suffixes allow the fleet to
    operate without certain keys (e.g. OpenRouterApiKey for agents that don't
    need code execution).
.PARAMETER AgentRoles
    Array of agent role configuration objects with .Role and .Index properties.
.PARAMETER StackName
    The Docker Swarm stack/project name used as the secret prefix.
.PARAMETER OptionalSuffixes
    Array of secret suffixes that are considered optional (missing is not a failure).
    Defaults to empty array (all secrets required).
#>
function Test-FleetSecretHydration {
    [OutputType([array])]
    param(
        [array]$AgentRoles,
        [string]$StackName,
        [string[]]$OptionalSuffixes = @()
    )
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Verbose "`n[4] Secret Hydration"

    # Load secret schema once — defines all known suffixes for the bundle manifest
    $schema = Get-SecretSchema

    # Base suffixes every agent role needs: AWS credentials, gateway token, API key
    $BaseSecretSuffixes = @(
        $schema['AwsId'].Suffix,
        $schema['AwsSecret'].Suffix,
        $schema['GatewayToken'].Suffix,
        $schema['OpenRouterApiKey'].Suffix
    )

    foreach ($Agent in $AgentRoles) {
        $SecretPrefix = Get-AgentSecretPrefix -Project $StackName -Role $Agent.Role -Index $Agent.Index

        $RoleKeys = if ($script:RoleProviderKeyMap.ContainsKey($Agent.Role)) {
            $script:RoleProviderKeyMap[$Agent.Role]
        } else {
            @()
        }

        foreach ($Suffix in ($BaseSecretSuffixes + $RoleKeys)) {
            $Found = docker secret ls --filter "name=${SecretPrefix}_${Suffix}" -q 2>$null
            $isMissing = [string]::IsNullOrWhiteSpace($Found)
            $isOptional = $Suffix -in $OptionalSuffixes

            if ($isMissing) {
                $detail = if ($isOptional) { "optional, not created" } else { "missing" }
                $r = Test-Step -Name "Secret ${SecretPrefix}_${Suffix}" `
                    -Passed:$isOptional `
                    -Detail $detail `
                    -PassThru
                if ($r) { $results.Add($r) }
            } else {
                $r = Test-Step -Name "Secret ${SecretPrefix}_${Suffix}" `
                    -Passed $true `
                    -Detail "exists" `
                    -PassThru
                if ($r) { $results.Add($r) }
            }
        }
    }

    return $results.ToArray()
}
