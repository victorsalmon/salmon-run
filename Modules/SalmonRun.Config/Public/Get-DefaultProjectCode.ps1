<#
.SYNOPSIS
    Returns the default project code from install.json, env var, or fallback.
.DESCRIPTION
    Checks INSTALL_PROJECT env var first, then reads from install.json,
    then falls back to "FRAD".
.OUTPUTS
    System.String
#>
function Get-DefaultProjectCode {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:INSTALL_PROJECT)) { return $env:INSTALL_PROJECT }
    try {
        $Json = Read-InstallJson
        if ($Json -and $Json.project.code) { return $Json.project.code }
    } catch {
        Write-Verbose "Get-DefaultProjectCode: Failed to read install.json: $_"
    }
    return "FRAD"
}
