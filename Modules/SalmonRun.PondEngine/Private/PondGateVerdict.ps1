function Get-LatestPondHeaderMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string[]]$Headers
    )

    $names = @($Headers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
    if ($names.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Content)) { return $null }
    $pattern = "(?im)^\*\*(?<header>$($names -join '|'))\*\*:\s*(?<value>[^\r\n]+)"
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -eq 0) { return $null }
    return $matches[$matches.Count - 1]
}

function Get-PondGateVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [string]$DecisionHeader,
        [Parameter(Mandatory)][string]$EvidenceHeader
    )

    $match = Get-LatestPondHeaderMatch -Content $Content -Headers @($DecisionHeader, $EvidenceHeader)
    if (-not $match) {
        return [pscustomobject]@{ Found=$false; Passed=$false; Failed=$false; Header=''; Value=''; Index=-1 }
    }
    $header = $match.Groups['header'].Value
    $value = $match.Groups['value'].Value.Trim()
    $passPattern = if ($header -eq $DecisionHeader) { '^pass(?:ed)?\b' } else { '^(passed|completed)\b' }
    $failPattern = '^(rework|fail(?:ed)?|reject(?:ed)?|blocked)\b'
    return [pscustomobject]@{
        Found  = $true
        Passed = $value -match $passPattern
        Failed = $value -match $failPattern
        Header = $header
        Value  = $value
        Index  = $match.Index
    }
}