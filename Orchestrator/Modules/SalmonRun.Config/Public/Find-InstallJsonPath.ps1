<#
.SYNOPSIS
    Locates the install.json file by searching common locations and environment variables.
#>
function Find-InstallJsonPath {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($env:ORCHESTRATOR_INSTALL_JSON -and (Test-Path $env:ORCHESTRATOR_INSTALL_JSON)) {
        return $env:ORCHESTRATOR_INSTALL_JSON
    }

    $RepoRoot = if (Get-Command Get-SalmonRunRepoRoot -ErrorAction SilentlyContinue) { Get-SalmonRunRepoRoot } elseif ($script:ModuleRoot) { Split-Path (Split-Path $script:ModuleRoot -Parent) -Parent } else { $null }
    if ($RepoRoot) {
        $RepoRootPath = Join-Path $RepoRoot "install.json"
        if (Test-Path $RepoRootPath) { return $RepoRootPath }
    }

    $HostPath = Join-Path (Get-HomeDir) ".ORCHESTRATOR" "install.json"
    if (Test-Path $HostPath) { return $HostPath }

    $DronePath = "/home/node/app/install.json"
    if (Test-Path $DronePath) { return $DronePath }

    $HomePath = Join-Path $HOME ".ORCHESTRATOR" "install.json"
    if (Test-Path $HomePath) { return $HomePath }

    # Fallback: walk up from CWD looking for install.json (repo root)
    $cwd = Get-Location
    $walk = $cwd.Path
    while ($walk) {
        $candidate = Join-Path $walk "install.json"
        if (Test-Path $candidate) { return $candidate }
        $parent = Split-Path $walk -Parent
        if ($parent -eq $walk) { break }
        $walk = $parent
    }

    return $null
}
