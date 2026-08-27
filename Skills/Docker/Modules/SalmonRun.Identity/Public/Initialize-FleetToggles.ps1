<#
.SYNOPSIS
    Resolves and sets fleet feature toggles (Tailscale, Fleet, RekognitionFallback, CODE containers, server mode).
.PARAMETER DroneMode
    If set, disables interactive prompts and uses defaults.
#>
function Initialize-FleetToggles {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch]$DroneMode
    )
    $result = @{}

    $result.InstallTailscale = Get-SilentToggle -VarName "INSTALL_TAILSCALE" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_TAILSCALE" -Value $result.InstallTailscale

    $result.InstallFleet = Get-SilentToggle -VarName "INSTALL_FLEET" -DefaultValue "true" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_FLEET" -Value $result.InstallFleet

    $result.InstallRekognitionFallback = Get-SilentToggle -VarName "INSTALL_REKOGNITION_FALLBACK" -DefaultValue "true" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_REKOGNITION_FALLBACK" -Value $result.InstallRekognitionFallback

    $result.InstallBrowserless = Get-SilentToggle -VarName "INSTALL_BROWSERLESS" -DefaultValue "false" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_BROWSERLESS" -Value $result.InstallBrowserless

    $result.InstallBookkeeping = Get-SilentToggle -VarName "INSTALL_BOOKKEEPING" -DefaultValue "false" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_BOOKKEEPING" -Value $result.InstallBookkeeping

    $result.InstallOpencode = Get-SilentToggle -VarName "INSTALL_OPENCODE" -DefaultValue "true" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_OPENCODE" -Value $result.InstallOpencode

    $result.InstallAqe = Get-SilentToggle -VarName "INSTALL_AQE" -DefaultValue "true" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_AQE" -Value $result.InstallAqe

    $result.InstallFunnel = Get-SilentToggle -VarName "INSTALL_FUNNEL" -DefaultValue "false" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_FUNNEL" -Value $result.InstallFunnel

    $result.InstallMonitoring = Get-SilentToggle -VarName "INSTALL_MONITORING" -DefaultValue "false" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_MONITORING" -Value $result.InstallMonitoring

    $result.InstallHermes = Get-SilentToggle -VarName "INSTALL_HERMES" -DefaultValue "false" -DroneMode:$DroneMode
    Set-Item -Path "Env:\INSTALL_HERMES" -Value $result.InstallHermes

    Write-SetupLog "Fleet: opencode=$($result.InstallOpencode) fleet=$($result.InstallFleet) tailscale=$($result.InstallTailscale) browserless=$($result.InstallBrowserless) Bookkeeper=$($result.InstallBookkeeping) funnel=$($result.InstallFunnel) monitoring=$($result.InstallMonitoring) hermes=$($result.InstallHermes)"
    return $result
}

