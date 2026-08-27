function Get-PondFileNamespace {
    <#
    .SYNOPSIS
        Extracts a connascence/namespace from a plan filename.
    .DESCRIPTION
        Removes date prefixes, leading role/tracker tokens, trailing sequence
        numbers, and feedback suffixes so related plans group together.
    .PARAMETER FileName
        Name of the plan file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $base = $base -replace '-feedback\d*$', ''
    $base = $base -creplace '^[A-Z]+-', ''
    $base = $base -replace '^\d{4}[-.]\d{2}[-.]\d{2}-?', ''

    if ($base -match '^(.+)-(\d+)$') {
        return $matches[1]
    }

    if ($base -match '^(.+?)-\d+') {
        return $matches[1]
    }

    if ($base -match '-') {
        $base = $base -replace '\d+$', ''
        if ([string]::IsNullOrWhiteSpace($base)) { return 'ungrouped' }
        return ($base -replace '^-|-$', '')
    }

    return 'ungrouped'
}

function Get-PondNamespaceGroups {
    <#
    .SYNOPSIS
        Groups plan files in a directory by their connascence namespace.
    .PARAMETER Directory
        Path to a queue directory.
    .OUTPUTS
        PSCustomObject with Namespace and Files.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $files = Get-ChildItem "$Directory\*.md" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }
    $groups = @{}
    foreach ($f in $files) {
        $ns = Get-PondFileNamespace -FileName $f.Name
        if (-not $groups.ContainsKey($ns)) { $groups[$ns] = [System.Collections.Generic.List[string]]::new() }
        $groups[$ns].Add($f.Name)
    }
    $result = @()
    foreach ($ns in ($groups.Keys | Sort-Object)) {
        $result += [pscustomobject]@{
            Namespace = $ns
            Files     = $groups[$ns].ToArray()
        }
    }
    return $result
}
