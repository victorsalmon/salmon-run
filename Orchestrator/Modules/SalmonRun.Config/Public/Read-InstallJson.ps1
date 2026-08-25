<#
.SYNOPSIS
    Reads and parses the install.json configuration file with optional key filtering.
#>
function Read-InstallJson {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Path
    )

    if (-not $Path) {
        $Path = Find-InstallJsonPath
    }

    if (-not $Path -or -not (Test-Path $Path)) {
        return $null
    }

    $FileStamp = (Get-Item $Path).LastWriteTime
    if ($script:InstallJsonCache -and $script:InstallJsonCacheTime -and $FileStamp -le $script:InstallJsonCacheTime) {
        return $script:InstallJsonCache
    }

    try {
        $Raw = Get-Content $Path -Raw -ErrorAction Stop
        $Raw = $Raw -replace "`r", ""
        $Parsed = $Raw | ConvertFrom-Json -ErrorAction Stop
        $script:InstallJsonCache = $Parsed
        $script:InstallJsonCacheTime = $FileStamp
        return $Parsed
    }
    catch {
        Write-SetupLog "Could not read install.json: $Path — $($_.Exception.Message)" -Level WARN
        return $null
    }
}
