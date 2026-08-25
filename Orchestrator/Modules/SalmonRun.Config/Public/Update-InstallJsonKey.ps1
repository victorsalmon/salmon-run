<#
.SYNOPSIS
    Updates a specific key in the install.json configuration file.
#>
function Update-InstallJsonKey {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$KeyPath,
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    if (-not $Path) {
        $Path = Find-InstallJsonPath
    }
    if (-not $Path) {
        throw "install.json not found -- cannot update key."
    }

    $Json = if (Test-Path $Path) {
        Get-Content $Path -Raw | ConvertFrom-Json
    } else {
        $null
    }

    if (-not $Json) {
        $Json = @{ version = "1.0" }
    }

    $Created = $false
    $Keys = $KeyPath.Split('.')
    $Current = $Json
    for ($i = 0; $i -lt $Keys.Count - 1; $i++) {
        $Key = $Keys[$i]
        if ($null -eq $Current.$Key) {
            $Current | Add-Member -MemberType NoteProperty -Name $Key -Value ([PSCustomObject]@{})
            $Created = $true
        }
        $Current = $Current.$Key
    }
    $LastKey = $Keys[-1]
    $Updated = ($null -ne $Current.$LastKey)
    $Current | Add-Member -MemberType NoteProperty -Name $LastKey -Value $Value -Force

    $TmpPath = "$Path.tmp"
    $Json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $TmpPath -Encoding utf8NoBOM -NoNewline
    # Ensure LF-only line endings (no CRLF) for cross-platform Docker volume mounts
    $rawContent = [System.IO.File]::ReadAllText($TmpPath) -replace "`r", ""
    [System.IO.File]::WriteAllText($Path, $rawContent, [System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $TmpPath -Force

    $script:InstallJsonCache = $null
    $script:InstallJsonCacheTime = $null

    return (-not $Created)
}
