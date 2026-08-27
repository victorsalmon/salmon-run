<#
.SYNOPSIS
    Merges a config override object into the in-memory install.json cache.
.DESCRIPTION
    Reads the base install.json, deep-merges the override using Merge-JsonDeep,
    and stores the result in the script-scoped cache for subsequent reads.
#>
function Set-InstallJsonOverride {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object]$OverrideObject,

        [string]$BasePath
    )
    if (-not $BasePath) {
        $BasePath = Find-InstallJsonPath
    }
    if (-not $BasePath -or -not (Test-Path $BasePath)) {
        Write-SetupLog "Set-InstallJsonOverride: Base install.json not found at $BasePath — using override as-is" -Level WARN
        $script:InstallJsonCache = $OverrideObject
        $script:InstallJsonCacheTime = Get-Date
        return
    }
    $base = Get-Content $BasePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $merged = Merge-JsonDeep -Base $base -Override $OverrideObject
    $script:InstallJsonCache = $merged
    $script:InstallJsonCacheTime = Get-Date
    Write-SetupLog "Set-InstallJsonOverride: merged ConfigOverride onto $BasePath" -Level INFO
}

function Merge-JsonDeep {
    param(
        [object]$Base,
        [object]$Override
    )
    if ($null -eq $Override) { return $Base }
    if ($Override -isnot [PSCustomObject] -or $Base -isnot [PSCustomObject]) {
        return $Override
    }
    $result = $Base.PSObject.Copy()
    foreach ($prop in $Override.PSObject.Properties) {
        if ($null -eq $result.$($prop.Name)) {
            $result | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
        } elseif ($prop.Value -is [PSCustomObject] -and $result.$($prop.Name) -is [PSCustomObject]) {
            $result.$($prop.Name) = Merge-JsonDeep -Base $result.$($prop.Name) -Override $prop.Value
        } else {
            $result.$($prop.Name) = $prop.Value
        }
    }
    return $result
}
