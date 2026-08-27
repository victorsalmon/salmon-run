function Invoke-HtmlReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('guide', 'estimate', 'status')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        $Data,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $templateDir = Join-Path $PSScriptRoot 'templates'
    $templatePath = Join-Path $templateDir "$Type.html.tmpl"

    if (-not (Test-Path $templatePath)) {
        throw "Template not found: $templatePath"
    }

    $template = Get-Content -Path $templatePath -Raw

    $resolved = @{}
    if ($Data -is [hashtable]) {
        $resolved = $Data
    } elseif ($Data -is [string] -and (Test-Path $Data)) {
        $resolved = Get-Content -Path $Data -Raw | ConvertFrom-Json -AsHashtable
    } elseif ($Data -is [PSCustomObject]) {
        $resolved = $Data | ConvertTo-Hashtable
    } else {
        throw "Data must be a hashtable, JSON file path, or PSCustomObject"
    }

    $html = $template

    $html = [regex]::Replace($html, '\{\{#if (\w+)\}\}(.*?)\{\{\/if\}\}', {
        param($match)
        $condKey = $match.Groups[1].Value
        $body = $match.Groups[2].Value
        $val = $resolved[$condKey]
        $present = $resolved.ContainsKey($condKey) -and $null -ne $val
        if ($present -and $val -is [string]) {
            $present = -not [string]::IsNullOrWhiteSpace($val)
        } elseif ($present -and $val -is [System.Collections.IList]) {
            $present = $val.Count -gt 0
        }
        if ($present) { return $body }
        return ''
    }, 'Singleline')

    foreach ($key in $resolved.Keys) {
        $value = $resolved[$key]
        if ($value -is [array] -or $value -is [System.Collections.IList]) {
            $rendered = ($value | ForEach-Object {
                if ($_ -is [hashtable] -or $_ -is [PSCustomObject]) {
                    $row = $_
                    $cells = ($row.Keys | ForEach-Object {
                        "<td>$($row[$_])</td>"
                    }) -join ''
                    "<tr>$cells</tr>"
                } else {
                    "<tr><td>$_</td></tr>"
                }
            }) -join "`n"
            $html = $html -replace "\{\{$key\}\}", $rendered
        } elseif ($value -is [hashtable] -or $value -is [PSCustomObject]) {
            $rendered = ($value.Keys | ForEach-Object {
                "<dt>$_</dt><dd>$($value[$_])</dd>"
            }) -join "`n"
            $rendered = "<dl>$rendered</dl>"
            $html = $html -replace "\{\{$key\}\}", $rendered
        } else {
            $html = $html -replace "\{\{$key\}\}", "$value"
        }
    }

    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }

    Set-Content -Path $OutputPath -Value $html -Encoding utf8
    Write-Verbose "HTML report written to $OutputPath"
    return (Resolve-Path $OutputPath).Path
}
