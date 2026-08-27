<#
.SYNOPSIS
    Resolves a configuration value through a multi-source precedence chain.
.DESCRIPTION
    Checks: (1) process env, (2) aliased env vars, (3) install.json file,
    (4) interactive prompt (unless NonInteractive). Sets the resolved value
    back into the process environment.
.PARAMETER VarName
    Primary environment variable name to resolve.
.PARAMETER PromptMessage
    Message displayed to the user during interactive prompt.
.PARAMETER DefaultValue
    Default value used when no source provides a value.
.PARAMETER Aliases
    Alternative env var names checked after the primary name.
.PARAMETER NonInteractive
    Skip interactive prompt; throw if no value is found and no default provided.
.OUTPUTS
    String of the resolved configuration value.
.EXAMPLE
    PS> Get-ConfigValue -VarName "INSTALL_PROJECT" -PromptMessage "Project code" -DefaultValue "FRAD"
    Resolves from env, file, or prompts the user.
#>
function Get-ConfigValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$VarName,

        [string]$PromptMessage,
        [string]$DefaultValue,
        [string[]]$Aliases,
        [switch]$NonInteractive
    )

    # 1. Check process environment first
    $Existing = Get-Item -Path "Env:\$VarName" -ErrorAction SilentlyContinue
    if ($null -ne $Existing -and -not [string]::IsNullOrWhiteSpace($Existing.Value)) {
        return $Existing.Value
    }

    # 2. Check aliases in environment
    if ($Aliases) {
        foreach ($Alias in $Aliases) {
            $AliasExisting = Get-Item -Path "Env:\$Alias" -ErrorAction SilentlyContinue
            if ($null -ne $AliasExisting -and -not [string]::IsNullOrWhiteSpace($AliasExisting.Value)) {
                Set-Item -Path "Env:\$VarName" -Value $AliasExisting.Value
                return $AliasExisting.Value
            }
        }
    }

    # 3. Check install.json (cached -- refresh every 10s)
    $InstallJson = Read-InstallJson
    if ($InstallJson) {
        $KeyMap = Get-InstallJsonKeyMap
        $JsonPath = $KeyMap[$VarName]
        if ($JsonPath) {
            $JsonValue = Get-JsonValueByPath -JsonObj $InstallJson -KeyPath $JsonPath
            if ($null -ne $JsonValue -and -not [string]::IsNullOrWhiteSpace("$JsonValue")) {
                $StrValue = "$JsonValue"
                Set-Item -Path "Env:\$VarName" -Value $StrValue
                return $StrValue
            }
        }
        if ($Aliases) {
            foreach ($Alias in $Aliases) {
                $AliasJsonPath = $KeyMap[$Alias]
                if ($AliasJsonPath) {
                    $AliasJsonValue = Get-JsonValueByPath -JsonObj $InstallJson -KeyPath $AliasJsonPath
                    if ($null -ne $AliasJsonValue -and -not [string]::IsNullOrWhiteSpace("$AliasJsonValue")) {
                        $StrValue = "$AliasJsonValue"
                        Set-Item -Path "Env:\$VarName" -Value $StrValue
                        return $StrValue
                    }
                }
            }
        }

        # Computed values from fleet.agents array
        if ($InstallJson.fleet -and $InstallJson.fleet.agents) {
            $agents = $InstallJson.fleet.agents
            switch ($VarName) {
                'AGENT_NUMBER' {
                    $StrValue = "$($agents.Count)"
                    Set-Item -Path "Env:\$VarName" -Value $StrValue
                    return $StrValue
                }
                'ROLE_CODE' {
                    $StrValue = ($agents.role) -join ','
                    Set-Item -Path "Env:\$VarName" -Value $StrValue
                    return $StrValue
                }
                'AGENT_NAMES' {
                    $StrValue = ($agents.name) -join ','
                    Set-Item -Path "Env:\$VarName" -Value $StrValue
                    return $StrValue
                }
            }
        }
    }

    # 4. Prompt user if no value found anywhere
    if ($NonInteractive) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            Set-Item -Path "Env:\$VarName" -Value $DefaultValue
            return $DefaultValue
        }
        throw "Config value '$VarName' not found and no default provided in NonInteractive mode."
    }

    $InputVal = Read-Host "$PromptMessage (Default: $DefaultValue)"
    $FinalVal = if ([string]::IsNullOrWhiteSpace($InputVal)) { $DefaultValue } else { $InputVal }
    Set-Item -Path "Env:\$VarName" -Value $FinalVal
    return $FinalVal
}
