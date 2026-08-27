function Get-SuppressedHealthServices {
    <#
    .SYNOPSIS
        Returns list of service names with active health suppression files.
    .DESCRIPTION
        Scans Tasks/Logs/.suppress-health-<service> files and returns
        the list of service names whose remediation is paused.
        Also checks Tasks/Logs/.suppress-health-all for global suppression.
    #>
    [OutputType([string[]])]
    param()
    $logDir = Join-Path $PWD "Tasks/Logs"
    if (-not (Test-Path $logDir)) { return @() }
    $suppressed = @()
    $files = Get-ChildItem -Path $logDir -Filter ".suppress-health-*" -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $serviceName = $f.Name -replace '^\.suppress-health-', ''
        $suppressed += $serviceName
    }
    return ($suppressed | Select-Object -Unique)
}

$script:FleetHealthState = @{
    Status        = "ok"
    LastUpdate    = $null
    FailCount     = 0
    UptimeSeconds = 0
    StartTime     = [DateTime]::UtcNow
    Version       = "2.0"
    Hostname      = if ($env:HOSTNAME) { $env:HOSTNAME } else { "unknown" }
    StackName     = if (Get-Command Get-StackName -ErrorAction SilentlyContinue) { Get-StackName } else { "unknown" }
}

$script:CommandPollInterval = if ($global:InterclawConstants.FleetCommandPollIntervalSec) { $global:InterclawConstants.FleetCommandPollIntervalSec } else { 30 }
$script:UpdateCycleInterval = if ($global:InterclawConstants.FleetUpdateCycleIntervalSec) { $global:InterclawConstants.FleetUpdateCycleIntervalSec } else { 86400 }

$script:StartupCheckMarker = Join-Path $PWD "Tasks/Logs/.startup-check-marker"
