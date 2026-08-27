<#
.SYNOPSIS
    Updates the script-scope Fleet health state with provided properties.
#>
function Update-FleetHealthState {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(ParameterSetName = 'KeyValue')]
        [string]$Key,

        [Parameter(ParameterSetName = 'KeyValue')]
        [object]$Value,

        [Parameter(ParameterSetName = 'Hashtable')]
        [hashtable]$Properties
    )

    if ($PSCmdlet.ParameterSetName -eq 'Hashtable' -and $Properties) {
        foreach ($k in $Properties.Keys) {
            $script:FleetHealthState[$k] = $Properties[$k]
        }
    } elseif ($PSCmdlet.ParameterSetName -eq 'KeyValue' -and $Key) {
        $script:FleetHealthState[$Key] = $Value
    }
}
