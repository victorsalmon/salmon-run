<#
.SYNOPSIS
    Replaces {placeholders} in a string with values from a map.
.PARAMETER Text
    String containing {PlaceholderName} tokens.
.PARAMETER PlaceholderMap
    Hashtable mapping placeholder names to replacement values.
.OUTPUTS
    String with all placeholders resolved.
#>
function Resolve-StringPlaceholders {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Text,
        [hashtable]$PlaceholderMap
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if (-not $PlaceholderMap -or $PlaceholderMap.Count -eq 0) {
        $PlaceholderMap = Get-OwnerPlaceholders -ErrorAction SilentlyContinue
    }
    if (-not $PlaceholderMap -or $PlaceholderMap.Count -eq 0) { return $Text }
    $result = $Text
    foreach ($kv in $PlaceholderMap.GetEnumerator()) {
        $result = $result -replace [regex]::Escape("{$($kv.Name)}"), $kv.Value
    }
    return $result
}
