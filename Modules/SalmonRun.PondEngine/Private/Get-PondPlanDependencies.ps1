function ConvertTo-PondDependencyId {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Dependency)

    $value = if ($null -eq $Dependency) { '' } else { $Dependency.Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }

    $code = [regex]::Match($value, '`(?<id>[^`]+)`')
    if ($code.Success) {
        $value = $code.Groups['id'].Value
    } else {
        $link = [regex]::Match($value, '^\[(?<id>[^\]]+)\]\([^\)]+\)')
        if ($link.Success) { $value = $link.Groups['id'].Value }
        $value = $value -replace '[ \t]+\([^\r\n]*\)[ \t]*$', ''
        $value = $value.Trim()
        $value = $value.Trim('`')
    }

    return [IO.Path]::GetFileNameWithoutExtension($value.Trim())
}

function Get-PondPlanDependencies {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrEmpty($Content)) { return @() }
    $matches = [regex]::Matches($Content, '(?im)^\*\*DependsOn\*\*:[ \t]*(?<value>[^\r\n]*)')
    $dependencies = [System.Collections.Generic.List[string]]::new()
    foreach ($match in $matches) {
        foreach ($raw in ($match.Groups['value'].Value -split ',[ \t]*')) {
            $id = ConvertTo-PondDependencyId -Dependency $raw
            if (-not [string]::IsNullOrWhiteSpace($id) -and -not $dependencies.Contains($id)) {
                $dependencies.Add($id)
            }
        }
    }
    return $dependencies.ToArray()
}
