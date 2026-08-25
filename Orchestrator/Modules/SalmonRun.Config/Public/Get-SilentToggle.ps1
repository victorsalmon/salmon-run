<#
.SYNOPSIS
    Resolves a feature toggle value from environment, install.json, or prompt.
.DESCRIPTION
    Checks process environment first, then install.json for an explicit declaration.
    In DroneMode returns the default without prompting. Falls back to interactive prompt
    only when not in DroneMode and no value is declared.
.PARAMETER VarName
    The environment variable name to resolve (e.g. INSTALL_TAILSCALE).
.PARAMETER DefaultValue
    Default value returned when nothing is declared. Defaults to "false".
.PARAMETER DroneMode
    Suppress interactive prompts; return the default if not declared.
.OUTPUTS
    String value of the toggle ("true" or "false").
.EXAMPLE
    PS> Get-SilentToggle -VarName "INSTALL_TAILSCALE" -DroneMode
    Returns the declared value or "false".
#>
function Get-SilentToggle {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VarName,

        [string]$DefaultValue = "false",
        [switch]$DroneMode
    )

    # Check process environment first
    $Existing = Get-Item -Path "Env:\$VarName" -ErrorAction SilentlyContinue
    if ($null -ne $Existing -and -not [string]::IsNullOrWhiteSpace($Existing.Value)) {
        return $Existing.Value
    }

    # Check install.json -- look for explicit declaration
    $InstallJson = Read-InstallJson
    $FoundInJson = $false
    $JsonValue = $null
    if ($InstallJson) {
        $KeyMap = Get-InstallJsonKeyMap
        $JsonPath = $KeyMap[$VarName]
        if ($JsonPath) {
            $JsonValue = Get-JsonValueByPath -JsonObj $InstallJson -KeyPath $JsonPath
            $FoundInJson = ($null -ne $JsonValue)
        }
    }
    if ($FoundInJson) {
        $StrValue = "$JsonValue"
        if ([string]::IsNullOrWhiteSpace($StrValue)) { return "false" }
        return $StrValue
    }

    # Not declared anywhere -- in DroneMode use default without prompting
    if ($DroneMode) {
        if (Get-Command Write-SetupLog -ErrorAction SilentlyContinue) {
            Write-SetupLog "DroneMode: using default $DefaultValue for $VarName (not declared in install.json)"
        }
        return $DefaultValue
    }

    # Not declared anywhere -- prompt user (value is NOT persisted)
    $PromptText = switch ($VarName) {
        "INSTALL_TAILSCALE"         { "Deploy Tailscale subnet router" }
        "INSTALL_CODE_CONTAINERS"   { "CODE workers for two-agent pattern (0=off, recommended: 1)" }
        "INSTALL_CODE_SERVER_MODE"  { "Run CODE container as server (multi-session via API)" }
        "INSTALL_BOOKKEEPING"        { "Deploy Bookkeeping service (Plaid sync + reconciliation)" }
        default                     { "Enable $VarName" }
    }
    if ($VarName -eq "INSTALL_CODE_CONTAINERS") {
        $InputVal = Read-Host "$PromptText (Default: $DefaultValue)"
    } else {
        $InputVal = Read-Host "$PromptText [$VarName] [true/false] (Default: $DefaultValue)"
    }
    $FinalVal = if ([string]::IsNullOrWhiteSpace($InputVal)) { $DefaultValue } else { $InputVal }
    return $FinalVal
}

