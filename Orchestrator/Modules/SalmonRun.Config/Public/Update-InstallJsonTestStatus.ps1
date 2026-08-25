<#
.SYNOPSIS
    Updates the testStatus section of install.json with container health status.
.DESCRIPTION
    Takes a hashtable mapping container/feature names to their test status (Pass/Fail/Skip)
    and writes it into the testStatus property of install.json. If install.json lacks a
    testStatus property, one is created. Writes atomically via a .tmp file to avoid corruption.
    Clears the module-level install.json cache after writing so subsequent reads get fresh data.
.PARAMETER ContainerStatus
    Hashtable where keys are container/feature names and values are status strings.
.PARAMETER Path
    Optional explicit path to install.json. Auto-detected if omitted.
.EXAMPLE
    Update-InstallJsonTestStatus -ContainerStatus @{ fleet = "Pass"; orch = "Fail" }
#>
function Update-InstallJsonTestStatus {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ContainerStatus,
        [string]$Path
    )
    if (-not $Path) {
        $Path = Find-InstallJsonPath
    }
    if (-not $Path) {
        Write-Information -MessageData "install.json not found — cannot update testStatus. Skipping." -Tags "WARN"
        return
    }

    $Json = if (Test-Path $Path) {
        Get-Content $Path -Raw | ConvertFrom-Json
    } else { $null }
    if (-not $Json) {
        $Json = [pscustomobject]@{ version = "1.0" }
    }

    if (-not $Json.testStatus) {
        $Json | Add-Member -MemberType NoteProperty -Name "testStatus" -Value ([pscustomobject]@{})
    }
    foreach ($entry in $ContainerStatus.GetEnumerator()) {
        $Json.testStatus | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value -Force
    }

    $TmpPath = "$Path.tmp"
    $Json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $TmpPath -Encoding UTF8
    Move-Item -LiteralPath $TmpPath -Destination $Path -Force

    $script:InstallJsonCache = $null
    $script:InstallJsonCacheTime = $null
}
