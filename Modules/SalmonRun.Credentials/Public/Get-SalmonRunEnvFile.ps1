function Get-SalmonRunEnvFile {
    <#
    .SYNOPSIS
        Reads a .env-style file into a case-insensitive ordered hashtable.
    .DESCRIPTION
        Supports # comments (both line and inline), blank lines, and KEY=VALUE.
        Does not resolve values; returns raw strings. The default path is
        $SALMON_RUN_HOME/.env, falling back to ~/.salmon/.env.
    .PARAMETER Path
        Optional path to a .env file.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path
    )

    if (-not $Path) {
        $homePath = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Join-Path $HOME '.salmon' }
        $Path = Join-Path $homePath '.env'
    }

    $values = [System.Collections.Specialized.OrderedDictionary]::new()
    if (-not (Test-Path $Path)) { return $values }

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        # strip inline comment after unquoted #
        $commentIndex = $trimmed.IndexOf(' #')
        if ($commentIndex -gt 0) { $trimmed = $trimmed.Substring(0, $commentIndex).TrimEnd() }

        $equals = $trimmed.IndexOf('=')
        if ($equals -lt 1) { continue }

        $key = $trimmed.Substring(0, $equals).Trim()
        $value = $trimmed.Substring($equals + 1).Trim()

        # remove wrapping single/double quotes if present
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$key] = $value
    }

    return $values
}
