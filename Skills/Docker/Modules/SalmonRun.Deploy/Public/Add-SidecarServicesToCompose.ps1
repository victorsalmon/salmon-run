<#
.SYNOPSIS
    Adds sidecar service definitions (API proxy, opencode, Browserless,
    AQE, Bookkeeper, Monitoring) to compose.
#>
function Add-SidecarServicesToCompose {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Compose,
        [Parameter(Mandatory = $true)]
        [string]$ProjectCode,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstallWorkspaceRepos,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBundleName,
        [Parameter(Mandatory = $true)]
        [string]$CodingReadBundleName,
        [Parameter(Mandatory = $true)]
        [string]$CodingWriteBundleName,
        [Parameter(Mandatory = $true)]
        [string]$BookkeepingBundleName,
        [Parameter(Mandatory = $true)]
        [string]$BookkeepingBundleSuffix,
        [Parameter(Mandatory = $true)]
        [string]$InstallTailscale,
        [Parameter(Mandatory = $true)]
        [string]$InstallBrowserless,
        [Parameter(Mandatory = $true)]
        [string]$InstallBookkeeping,
        [Parameter(Mandatory = $true)]
        [string]$InstallAqe,
        [Parameter(Mandatory = $true)]
        [string]$InstallFunnel,
        [Parameter(Mandatory = $true)]
        [string]$InstallMarketer,
        [Parameter(Mandatory = $true)]
        [string]$InstallHermes,
        [Parameter(Mandatory = $true)]
        [bool]$MonitoringEnabled
    )
Set-StrictMode -Off

    # Monitoring
    if ($MonitoringEnabled) {
        $MonitoringInternalPort = Get-ServicePort -Service "is-monitoring" -Type "internal"
        $Compose.configs["prometheus_config"] = [ordered]@{
            file = (Join-Path (Get-InterclawRepoRoot) "Infrastructure/monitoring/prometheus.yml")
        }
        $Compose.configs["grafana_datasource"] = [ordered]@{
            file = (Join-Path (Get-InterclawRepoRoot) "Infrastructure/monitoring/grafana-datasource.yml")
        }
        $Compose.configs["grafana_dashboard_provider"] = [ordered]@{
            file = (Join-Path (Get-InterclawRepoRoot) "Infrastructure/monitoring/grafana-dashboard-provider.yml")
        }
        $Compose.configs["grafana_dashboard"] = [ordered]@{
            file = (Join-Path (Get-InterclawRepoRoot) "Infrastructure/monitoring/grafana-dashboard.json")
        }
        $Compose.services["is-monitoring"] = [ordered]@{
            image       = "`${ORCHESTRATOR_MONITORING_IMAGE:-monitoring:local}"
            networks    = @((Get-NetworkNames).ServiceNet)
            ports       = @("127.0.0.1:${MonitoringInternalPort}:${MonitoringInternalPort}")
            healthcheck = [ordered]@{
                test         = @("CMD-SHELL", "curl -sf http://127.0.0.1:${MonitoringInternalPort}/api/health || exit 1")
                interval     = "30s"
                timeout      = "5s"
                retries      = 3
                start_period = "15s"
            }
            deploy      = [ordered]@{
                resources = [ordered]@{
                    reservations = [ordered]@{ memory = "64M" }
                    limits       = [ordered]@{ memory = "128M" }
                }
                restart_policy = [ordered]@{
                    condition = "any"
                    delay     = "5s"
                }
            }
            volumes     = @("interclaw_workspace:/workspace:ro")
            configs     = @()
            secrets     = @(
                [ordered]@{ source = "FLEET_API_TOKEN_MONITOR"; target = "fleet_monitor_token" }
            )
            cap_drop    = @("ALL")
            cap_add     = @("CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "NET_BIND_SERVICE")
            security_opt = @("no-new-privileges:true")
            read_only   = $true
            tmpfs       = @("/tmp")
        }
        $Compose.services["prometheus"] = [ordered] @{
            image       = "prom/prometheus:v3"
            networks    = @((Get-NetworkNames).ServiceNet)
            ports       = @("9090")
            deploy      = [ordered]@{
                resources = [ordered]@{
                    reservations = [ordered]@{ memory = "256M" }
                    limits       = [ordered]@{ memory = "512M" }
                }
                restart_policy = [ordered]@{
                    condition = "any"
                    delay     = "5s"
                }
            }
            configs     = @(
                [ordered]@{
                    source = "prometheus_config"
                    target = "/etc/prometheus/prometheus.yml"
                }
            )
            volumes     = @("prometheus_data:/prometheus")
            command     = @("--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus", "--web.console.libraries=/usr/share/prometheus/console_libraries", "--web.console.templates=/usr/share/prometheus/consoles")
            cap_drop    = @("ALL")
            cap_add     = @("NET_BIND_SERVICE")
            security_opt = @("no-new-privileges:true")
            read_only   = $true
            tmpfs       = @("/tmp")
        }
        $Compose.volumes["prometheus_data"] = $null
        $GrafanaHostPort = 30000
        $Compose.services["grafana"] = [ordered]@{
            image       = "grafana/grafana:11"
            networks    = @((Get-NetworkNames).ServiceNet)
            ports       = @("127.0.0.1:${GrafanaHostPort}:3000")
            deploy      = [ordered]@{
                resources = [ordered]@{
                    reservations = [ordered]@{ memory = "128M" }
                    limits       = [ordered]@{ memory = "256M" }
                }
                restart_policy = [ordered]@{
                    condition = "any"
                    delay     = "5s"
                }
            }
            environment = [ordered]@{
                GF_AUTH_ANONYMOUS_ENABLED   = "false"
                GF_SECURITY_ADMIN_PASSWORD  = '${GF_SECURITY_ADMIN_PASSWORD:?GF_SECURITY_ADMIN_PASSWORD is required}'
            }
            configs     = @(
                [ordered]@{
                    source = "grafana_datasource"
                    target = "/etc/grafana/provisioning/datasources/prometheus.yml"
                }
                [ordered]@{
                    source = "grafana_dashboard_provider"
                    target = "/etc/grafana/provisioning/dashboards/provider.yml"
                }
                [ordered]@{
                    source = "grafana_dashboard"
                    target = "/etc/grafana/provisioning/dashboards/fleet-dashboard.json"
                }
            )
            volumes     = @("grafana_data:/var/lib/grafana")
            cap_drop    = @("ALL")
            cap_add     = @("NET_BIND_SERVICE")
            security_opt = @("no-new-privileges:true")
            read_only   = $true
            tmpfs       = @("/tmp")
        }
        $Compose.volumes["grafana_data"] = $null
    }

    return $Compose
}
