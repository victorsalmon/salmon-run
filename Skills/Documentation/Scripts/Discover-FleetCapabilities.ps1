<#
.SYNOPSIS
    Discover all fleet container capabilities by querying each service's /tools/list endpoint.
.DESCRIPTION
    Polls every known fleet container on service_net for its tools list.
    Generates a Mermaid table, JSON output, and Mermaid flowchart of capabilities.
    Writes results to an ephemeral timestamped file.
.PARAMETER OutputDir
    Directory to write output files (default: Tasks/Logs/)
.PARAMETER AsJson
    Output only the JSON representation (for programmatic consumption).
.PARAMETER AsMermaid
    Output only the Mermaid diagram.
.PARAMETER TimeoutSec
    Per-service HTTP timeout in seconds (default: 5).
.EXAMPLE
    ./Discover-FleetCapabilities.ps1
.EXAMPLE
    ./Discover-FleetCapabilities.ps1 -AsJson | ConvertFrom-Json
.EXAMPLE
    ./Discover-FleetCapabilities.ps1 -OutputDir /workspace/Fleet\ Tasks/Logs/
#>

param(
    [string]$OutputDir = "Tasks/Logs",
    [switch]$AsJson,
    [switch]$AsMermaid,
    [int]$TimeoutSec = 5
)

$discoveredAt = (Get-Date).ToUniversalTime().ToString("o")
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")

$services = @(
    # mcp_web retired 2026-08-22 — web research via the cross-harness /web-research skill
    @{ Name = "mcp_aqe";          Host = "mcp_aqe";          Port = 21004; Type = "sse";       Path = "" },
    @{ Name = "is-bookkeeping";    Host = "is-bookkeeping";    Port = 21008; Type = "rest";      Path = "/tools/list" },
    @{ Name = "is-api";           Host = "is-api";           Port = 21003; Type = "rest";      Path = "/tools/list" },
    @{ Name = "is-fleet";        Host = "is-fleet";        Port = 21002; Type = "rest";      Path = "/tools/list" },
    @{ Name = "mcp_browserless";  Host = "is-api";           Port = 21003; Type = "rest-proxy"; Path = "/tools/list/browserless" },
    @{ Name = "mcp_opencode";     Host = "mcp_opencode";     Port = 21000; Type = "rest";      Path = "/tools/list" }
)

$results = @()

foreach ($svc in $services) {
    $uri = "http://$($svc.Host):$($svc.Port)$($svc.Path)"
    $entry = @{
        name      = $svc.Name
        reachable = $false
        tools     = @()
        error     = $null
        type      = $svc.Type
    }

    try {
        if ($svc.Type -eq "internal") {
            # mcp_opencode is the local opencode server — skip unauthenticated queries
            $entry.reachable = $true
            $entry.tools = @(@{ name = "opencode-session"; description = "opencode serve MCP session manager" })
        } elseif ($svc.Type -eq "rest" -or $svc.Type -eq "rest-proxy") {
            $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
            if ($response.tools) {
                $entry.tools = $response.tools
            } elseif ($response -is [array]) {
                $entry.tools = $response
            }
            $entry.reachable = $true
        } else {
            # SSE types — attempt REST /tools/list as fallback, else mark as SSE-only
            try {
                $response = Invoke-RestMethod -Uri "http://$($svc.Host):$($svc.Port)/tools/list" -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
                if ($response.tools) {
                    $entry.tools = $response.tools
                }
                $entry.reachable = $true
            } catch {
                $entry.reachable = $true
                $entry.tools = @(@{ name = "sse-mcp-server"; description = "MCP SSE server — tools available via SSE transport" })
            }
        }
    } catch {
        $entry.reachable = $false
        $entry.error = $_.Exception.Message
    }

    $results += [PSCustomObject]$entry
}

$reachableCount = ($results | Where-Object { $_.reachable }).Count
$totalCount = $results.Count

# ---- Build JSON output ----
$jsonOutput = @{
    discovered_at = $discoveredAt
    summary = @{ reachable = $reachableCount; total = $totalCount }
    services = $results | ForEach-Object {
        @{
            name      = $_.name
            reachable = $_.reachable
            type      = $_.type
            error     = $_.error
            tools     = $_.tools | ForEach-Object {
                if ($_ -is [string]) {
                    @{ name = $_; description = "" }
                } else {
                    @{ name = $_.name; description = $_.description }
                }
            }
        }
    }
} | ConvertTo-Json -Depth 5

# ---- Build Mermaid flowchart ----
$flowchartLines = @()
$flowchartLines += "graph LR"
$flowchartLines += "    subgraph Fleet[Fleet Capability Map]"
foreach ($svc in $results) {
    $statusEmoji = if ($svc.reachable) { "" } else { " ❌" }
    $toolNames = ($svc.tools | ForEach-Object {
        if ($_ -is [hashtable] -or $_ -is [PSCustomObject]) { $_.name } else { $_ }
    }) -join ", "
    $label = "$($svc.name)$statusEmoji<br/>$toolNames"
    $nodeId = $svc.name -replace "-", "_"
    $flowchartLines += "        $nodeId[""$label""]"
}
$flowchartLines += "    end"
$mermaidFlowchart = $flowchartLines -join "`n"

# ---- Build Mermaid table ----
$header = "| Service | Type | Reachable | Tools |"
$separator = "|---------|------|-----------|-------|"
$tableLines = @($header, $separator)
foreach ($svc in $results) {
    $toolNames = ($svc.tools | ForEach-Object {
        if ($_ -is [hashtable] -or $_ -is [PSCustomObject]) { $_.name } else { $_ }
    }) -join ", "
    $reachableStr = if ($svc.reachable) { "✅" } else { "❌" }
    $tableLines += "| $($svc.name) | $($svc.type) | $reachableStr | $toolNames |"
}
$mermaidTable = $tableLines -join "`n"

# ---- Conditional output ----
if ($AsJson) {
    $jsonOutput
    return
}

if ($AsMermaid) {
    $mermaidFlowchart
    return
}

# ---- Full report ----
$reportLines = @()
$reportLines += "# Fleet Capability Map"
$reportLines += ""
$reportLines += "**Discovered**: $discoveredAt"
$reportLines += "**Reachable**: $reachableCount / $totalCount services"
$reportLines += ""
$reportLines += "## Mermaid Flowchart"
$reportLines += ""
$reportLines += '```mermaid'
$reportLines += $mermaidFlowchart
$reportLines += '```'
$reportLines += ""
$reportLines += "## Service Table"
$reportLines += ""
$reportLines += $mermaidTable
$reportLines += ""
$reportLines += "## JSON"
$reportLines += ""
$reportLines += '```json'
$reportLines += $jsonOutput
$reportLines += '```'

$reportContent = $reportLines -join "`n"

$outputPath = Join-Path -Path $OutputDir -ChildPath "fleet-capabilities-$timestamp.md"
$null = New-Item -ItemType Directory -Path $OutputDir -Force
$reportContent | Out-File -FilePath $outputPath -Encoding utf8

Write-Output "Fleet capability map written to: $outputPath"
Write-Output "Reachable $reachableCount/$totalCount services"
