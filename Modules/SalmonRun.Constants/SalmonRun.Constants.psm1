#Requires -Version 7.0

Set-StrictMode -Off

$script:InterclawConstants = @{
    GatewayPortBase              = 20100
    GatewayPortMultiplier        = 100
    AwsKeyPropagationDelaySec    = 5
    AwsKeyPropagationRetries     = 10
    AwsKeyInitialPropagationWaitSec = 5
    HealthCheckMaxRetries        = 30
    HealthCheckRetryIntervalSec  = 10
    StackCleanupTimeoutSec       = 60
    StackCleanupRetryIntervalSec = 2
    PostCleanupWaitSec           = 3
    FleetCommandPollIntervalSec  = 30
    FleetUpdateCycleIntervalSec  = 86400
    FleetRemediationCooldownSec  = 15
    FleetMainLoopIntervalSec     = 300
    DockerDesktopStartupWaitSec  = 40
    VolumeSeedRetryMs            = 500
    LogTailLines                 = 100
    ComposeHealthCheckIntervalSec    = 180
    ComposeHealthCheckTimeoutSec     = 15
    ComposeHealthCheckRetries        = 3
    ComposeHealthCheckStartPeriodSec = 120
    ComposeNetworkWatchdogIntervalSec = 300
    ComposeNetworkWatchdogFailThreshold = 3
    MaxAgents                    = 9
    FleetApiPort                 = $(try { Get-ServicePort -Service is-fleet } catch { 29999 })
    CodeContainerPort            = $(try { Get-ServicePort -Service mcp_opencode_health } catch { 20101 })
    CodeServerPort               = $(try { Get-ServicePort -Service mcp_opencode_server } catch { 20102 })
    ProxyPort                    = $(try { Get-ServicePort -Service is-api } catch { 21010 })
    MarketerPort                 = $(try { Get-ServicePort -Service is-marketer } catch { 21011 })
    InterclawImage                = "openclaw:local"
    OpenCodeImage                = "opencode:local"
    FleetImage                   = "fleet:local"
    SentryImage                  = "is-sentry:local"
    ProxyImage                   = "is-api:local"
    McpBrowserlessImage          = "mcp_browserless:local"

    FleetHealthIntervalSec    = 1800
    FleetVersionCheckIntervalSec   = 21600
    FleetNightlyIntervalSec        = 86400
    FleetFirstUpdateDelaySec       = 120
    FleetRotationPort              = 29998

    SentryCommandPollIntervalSec   = 30
    SentryUpdateCycleIntervalSec   = 86400
    SentryRemediationCooldownSec   = 15
    SentryMainLoopIntervalSec      = 300

    AgentHeartbeatStaleThresholdSeconds = 120
    AgentHungThresholdMultiplier        = 2
    NamespaceReclaimThresholdSeconds    = 300
}

<#
.SYNOPSIS
    Returns the hashtable of all SalmonRun constants (ports, images, timeouts).
.OUTPUTS
    System.Collections.Hashtable
#>
function Get-SalmonRunConstants { if ($null -ne $script:InterclawConstants) { $script:InterclawConstants } else { @{} } }

<#
.SYNOPSIS
    Returns the ordered hashtable of Docker network names.
.OUTPUTS
    System.Collections.Specialized.OrderedDictionary
#>
function Get-NetworkNames { $script:NetworkNames }

$global:InterclawConstants = $script:InterclawConstants
$script:NetworkNames = [ordered]@{
    ServiceNet       = "service_net"
    OrchestrationNet = "orchestration_net"
    ManagementNet    = "management_net"
    FunnelNet        = "funnel_net"
}

<#
.SYNOPSIS
    Returns the canonical salmon-run pond/queue folder configuration.
.OUTPUTS
    PSCustomObject
#>
function Get-TaskQueueConfig {
    return [PSCustomObject]@{
        Primary = @('Code', 'Review', 'Working', 'Complete', 'Failed')
        Secondary = @('Manual', 'Handoffs', 'Project', 'ProjectReview', 'Schedules', 'Temp', 'ToDo', 'Paused', 'AQE')
        Ponds = [ordered]@{
            Intake  = @{ Role = 'planner';  Description = 'Interactive intake and feature discovery' }
            Code    = @{ Role = 'coder';    Description = 'Ready for coder implementation' }
            Review  = @{ Role = 'reviewer'; Description = 'Ready for reviewer verification' }
            QA      = @{ Role = 'qa';       Description = 'Property and mutation test maturation' }
            Audit   = @{ Role = 'auditor';  Description = 'Best-practice, safety, and code-smell audit' }
            Working = @{ Role = 'working';  Description = 'In-progress plans and lock files' }
            Failed  = @{ Role = 'failed';   Description = 'Failed or blocked plans' }
            Complete = @{ Role = 'complete'; Description = 'Completed plans awaiting archival' }
            Archive = @{ Role = 'archive';  Description = 'Archived plans' }
        }
    }
}

<#
.SYNOPSIS
    Returns the default AWS region for a given region type (secrets or compute).
.PARAMETER RegionType
    AWS_SECRETS_REGION or AWS_REGION.
.OUTPUTS
    System.String
#>
function Get-DefaultRegion {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AWS_SECRETS_REGION", "AWS_REGION")]
        [string]$RegionType
    )
    if (-not [string]::IsNullOrWhiteSpace((Get-Item "Env:\$RegionType" -ErrorAction SilentlyContinue).Value)) {
        return (Get-Item "Env:\$RegionType").Value
    }
    try {
        $Json = Read-InstallJson
        if ($Json) {
            if ($RegionType -eq "AWS_SECRETS_REGION" -and $Json.runtime.awsSecretsRegion) { return $Json.runtime.awsSecretsRegion }
            if ($RegionType -eq "AWS_REGION" -and $Json.runtime.awsRegion) { return $Json.runtime.awsRegion }
        }
    } catch {
        Write-SetupLog "Get-DefaultRegion: install.json read failed (using fallback) -- $_" -Level DEBUG -Agent core -Phase init
    }
    switch ($RegionType) {
        "AWS_SECRETS_REGION" { return "ca-central-1" }
        "AWS_REGION"         { return "us-east-1" }
    }
}

<#
.SYNOPSIS
    Returns the ordered list of coding key env-var names, by priority.
.OUTPUTS
    System.String[]
#>
function Get-CodingKeyPriority {
    return @("OPENCODE_GO1_KEY", "OPENCODE_GO5_KEY")
}

<#
.SYNOPSIS
    Resolves the project code from INSTALL_PROJECT environment variable.
    Fails fast with a clear error if INSTALL_PROJECT is empty.
.OUTPUTS
    System.String
#>
function Get-ProjectCode {
    $project = [System.Environment]::GetEnvironmentVariable('INSTALL_PROJECT')
    if ([string]::IsNullOrWhiteSpace($project)) {
        throw "INSTALL_PROJECT environment variable is not set or empty. Cannot resolve AWS SM path."
    }
    return $project
}

Export-ModuleMember -Function @(
    'Get-CodingKeyPriority',
    'Get-DefaultRegion',
    'Get-NetworkNames',
    'Get-SalmonRunConstants',
    'Get-ProjectCode',
    'Get-TaskQueueConfig'
)

# Backward-compatibility alias for the previous Interclaw-prefixed constants accessor
Set-Alias -Name 'Get-InterclawConstants' -Value 'Get-SalmonRunConstants'
Export-ModuleMember -Alias 'Get-InterclawConstants'
