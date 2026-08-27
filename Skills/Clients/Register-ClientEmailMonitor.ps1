param(
    [Parameter(Mandatory)]
    [string]$ClientSlug,

    [Parameter(Mandatory)]
    [string]$Email,

    [string]$ImapHost,

    [int]$ImapPort = 993,

    [string]$ImapPassword,

    [ValidateSet("hourly", "daily", "weekly")]
    [string]$Schedule = "hourly",

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$scheduleDir = Join-Path $PSScriptRoot "..\..\Tasks\Schedule"
$registryPath = Join-Path $PSScriptRoot "..\..\Infrastructure\clients\email-monitor-registry.json"

# Resolve paths
if (-not (Test-Path $scheduleDir)) { New-Item -ItemType Directory -Path $scheduleDir -Force | Out-Null }

$cronMap = @{
    hourly = "0 * * * *"
    daily  = "0 6 * * *"
    weekly = "0 6 * * 1"
}
$cronExpression = $cronMap[$Schedule]

$scheduleFile = Join-Path $scheduleDir "client-email-$ClientSlug.json"

Write-Host "Register-ClientEmailMonitor:"
Write-Host "  Client:  $ClientSlug"
Write-Host "  Email:   $Email"
Write-Host "  Host:    $ImapHost"
Write-Host "  Port:    $ImapPort"
Write-Host "  Schedule: $Schedule ($cronExpression)"

if ($WhatIf) {
    Write-Host "[WhatIf] Would create Tempo schedule: $scheduleFile"
    Write-Host "[WhatIf]   repeat: $cronExpression"
    Write-Host "[WhatIf]   prompt: node Skills/Email/Watch-ClientMailbox.mjs --client $ClientSlug"
    Write-Host "[WhatIf] Would append to registry: $registryPath"
    return @{
        Email        = $Email
        ClientSlug   = $ClientSlug
        ScheduleFile = $scheduleFile
        RegistryFile = $registryPath
        Cron         = $cronExpression
        WhatIf       = $true
    }
}

$scheduleEntry = @{
    id      = "client-email-$ClientSlug"
    type    = "custom"
    prompt  = "node Skills/Email/Watch-ClientMailbox.mjs --client $ClientSlug"
    agent   = "tempo"
    repeat  = $cronExpression
    status  = "pending"
    created = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
}
$scheduleEntry | ConvertTo-Json | Set-Content $scheduleFile
Write-Host "  Created schedule file: $scheduleFile"

$registryEntry = @{
    email      = $Email
    client     = $ClientSlug
    added_at   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    imap_host  = $ImapHost
    imap_port  = $ImapPort
    schedule   = $Schedule
}

$registry = @()
if (Test-Path $registryPath) {
    $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
    $existing = $registry | Where-Object { $_.client -eq $ClientSlug }
    if ($existing) {
        Write-Host "  Registry entry for '$ClientSlug' already exists — updating."
        $registry = $registry | Where-Object { $_.client -ne $ClientSlug }
    }
}
$registry = @($registry) + @($registryEntry)
$registry | ConvertTo-Json -Depth 10 | Set-Content $registryPath
Write-Host "  Registry updated: $registryPath"

Write-Host "  Done. Client '$ClientSlug' registered for $Schedule email monitoring."
