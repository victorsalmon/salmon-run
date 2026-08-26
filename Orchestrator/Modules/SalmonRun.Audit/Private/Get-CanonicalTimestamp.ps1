<#
.SYNOPSIS
    Normalizes a timestamp value to an ISO 8601 round-trip string.
.DESCRIPTION
    Audit hashes are computed over a canonical JSON representation. ConvertTo-Json
    on a DateTime trims trailing fractional zeros, so this helper always returns
    the full round-trip form (seven fractional digits, including a trailing 'Z'
    or a local offset). Any value that cannot be parsed as a DateTime is returned
    unchanged.
#>
function Get-CanonicalTimestamp {
    [OutputType([object])]
    param([object]$Value)

    if ($Value -is [datetime]) {
        return $Value.ToString('o')
    }

    if ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) {
        try {
            $parsed = [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            return $parsed.ToString('o')
        } catch {
            return $Value
        }
    }

    return $Value
}
