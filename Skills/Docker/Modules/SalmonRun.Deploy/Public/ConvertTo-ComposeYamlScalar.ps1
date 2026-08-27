<#
.SYNOPSIS
    Converts a PowerShell value to a YAML scalar string for compose file generation.
.DESCRIPTION
    Handles null, bool, numeric, and string types. Escapes and quotes strings
    containing special YAML characters (:, #, {}, [], etc.) or leading/trailing whitespace.
.PARAMETER Value
    The value to convert. Can be null, bool, numeric, or string.
.OUTPUTS
    String suitable for YAML serialization.
#>
function ConvertTo-ComposeYamlScalar {
    [OutputType([string])]
    param([object]$Value)

    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }

    $Str = $Value.ToString()

    if ($Str -eq "") { return '""' }

    $NeedsQuote = $false

    if ($Str -match '^\s' -or $Str -match '\s$') { $NeedsQuote = $true }
    $SpecialChars = @(':', '#', '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', "'", '"', '%', '@', '`')
    foreach ($c in $SpecialChars) {
        if ($Str.Contains($c)) { $NeedsQuote = $true; break }
    }
    if ($Str -match '^(true|false|null|yes|no|on|off|~|\d+(\.\d+)?)$') { $NeedsQuote = $true }
    if ($Str -match "`n") { $NeedsQuote = $true }

    if ($NeedsQuote) {
        $Escaped = $Str -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n'
        return "`"$Escaped`""
    }

    return $Str
}
