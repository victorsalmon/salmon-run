<#
.SYNOPSIS
    Creates a schedule entry in Tasks/Schedule/<id>.json for the sentry poller.
.DESCRIPTION
    User-facing CLI that writes a schedule JSON to Tasks/Schedule/<id>.json.
    Supports natural-language due dates and repeat intervals.
.PARAMETER Prompt
    The prompt/instruction for the scheduled agent. Positional, mandatory.
.PARAMETER Due
    Natural language due time: "ASAP", "in 2 hours", "tomorrow 3pm",
    "2026-06-20T15:00:00", "30 minutes". Default: ASAP.
.PARAMETER Repeat
    Natural language repeat: "every 30 minutes for 2 hours",
    "every hour 3 times", "once". Default: no repeat.
.PARAMETER Agent
    Target agent: "coder", "reviewer", "auditor", "any". Default: "any".
.PARAMETER HandoffPath
    Path to a handoff file in Tasks/Handoff/ to include in the plan.
.PARAMETER Type
    Schedule type: "custom" (default) or "alignment-audit".
.PARAMETER Model
    Optional model constraint: "provider/model-id" or null for agent's default.
.PARAMETER RequestedBy
    Who requested this schedule (for alignment-audit type). Defaults to $env:USERNAME.
.PARAMETER WhatIf
    Dry-run: show what would be written without writing.
.EXAMPLE
    .\Schedule-Prompt.ps1 "Run diagnostics" -Due "in 30 minutes"
.EXAMPLE
    .\Schedule-Prompt.ps1 -Prompt "Audit config" -Agent "auditor" -Repeat "every hour 3 times"
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Prompt,

    [Parameter()]
    [string]$Due = "ASAP",

    [Parameter()]
    [string]$Repeat,

    [Parameter()]
    [ValidateSet("coder", "reviewer", "auditor", "any")]
    [string]$Agent = "any",

    [Parameter()]
    [string]$HandoffPath,

    [Parameter()]
    [ValidateSet("custom", "alignment-audit")]
    [string]$Type = "custom",

    [Parameter()]
    [string]$Model,

    [Parameter()]
    [string]$RequestedBy,

    [Parameter()]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function ConvertFrom-NaturalDue {
    param([string]$DueText)
    if ([string]::IsNullOrWhiteSpace($DueText) -or $DueText -eq "ASAP") { return $null }
    $lower = $DueText.ToLowerInvariant().Trim()
    if ($lower -match '^in\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s*$') {
        $num = [int]$matches[1]
        $unit = $matches[2]
        $span = switch -Regex ($unit) {
            '^min' { [TimeSpan]::FromMinutes($num) }
            '^hour|^hr' { [TimeSpan]::FromHours($num) }
            '^day' { [TimeSpan]::FromDays($num) }
        }
        return (Get-Date).Add($span).ToString("o")
    }
    if ($lower -match '^tomorrow\s+(.+)$') {
        $timeStr = $matches[1].Trim()
        if ($timeStr -match '^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$') {
            $hours = [int]$matches[1]; $mins = [int]$matches[2]; $ampm = $matches[3]
            if ($ampm -eq "pm" -and $hours -lt 12) { $hours += 12 }
            if ($ampm -eq "am" -and $hours -eq 12) { $hours = 0 }
            $tomorrow = (Get-Date).Date.AddDays(1)
            return $tomorrow.AddHours($hours).AddMinutes($mins).ToString("o")
        }
        if ($timeStr -match '^(\d{1,2}):(\d{2})$') {
            $tomorrow = (Get-Date).Date.AddDays(1)
            return $tomorrow.AddHours([int]$matches[1]).AddMinutes([int]$matches[2]).ToString("o")
        }
    }
    try {
        $parsed = [DateTime]::Parse($DueText)
        return $parsed.ToString("o")
    } catch {}
    if ($lower -match '^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$' -or $lower -match '^(\d{1,2}):(\d{2})$') {
        if ($lower -match '^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$') {
            $hours = [int]$matches[1]; $mins = [int]($matches[2] -replace '[^0-9]', '0'); $ampm = $matches[3]
            if ($ampm -eq "pm" -and $hours -lt 12) { $hours += 12 }
            if ($ampm -eq "am" -and $hours -eq 12) { $hours = 0 }
        } else {
            $hours = [int]$matches[1]; $mins = [int]$matches[2]
        }
        $today = (Get-Date).Date
        $candidate = $today.AddHours($hours).AddMinutes($mins)
        if ($candidate -le (Get-Date)) { $candidate = $candidate.AddDays(1) }
        return $candidate.ToString("o")
    }
    return $null
}

function ConvertFrom-NaturalRepeat {
    param([string]$RepeatText)
    if ([string]::IsNullOrWhiteSpace($RepeatText)) { return $null }
    $lower = $RepeatText.ToLowerInvariant().Trim()
    if ($lower -eq "once" -or $lower -eq "no repeat") { return $null }

    # Cron expression (5 space-separated fields) — pass through as-is
    if ($lower -match '^[\d*,/\-\s]+$' -and ($lower -split '\s+').Count -eq 5) {
        return $lower.Trim()
    }

    if ($lower -match '^every\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s+for\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s*$') {
        $num = [int]$matches[1]; $unit = $matches[2]
        $num2 = [int]$matches[3]; $unit2 = $matches[4]
        $intervalMinutes = switch -Regex ($unit) {
            '^min' { $num }
            '^hour|^hr' { $num * 60 }
            '^day' { $num * 1440 }
        }
        $totalMinutes = switch -Regex ($unit2) {
            '^min' { $num2 }
            '^hour|^hr' { $num2 * 60 }
            '^day' { $num2 * 1440 }
        }
        $maxAttempts = [math]::Max(1, [math]::Floor($totalMinutes / $intervalMinutes))
        return @{ interval_minutes = $intervalMinutes; max_attempts = $maxAttempts }
    }
    if ($lower -match '^every\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s+(\d+)\s*times?\s*$') {
        $num = [int]$matches[1]; $unit = $matches[2]
        $maxAttempts = [int]$matches[3]
        $intervalMinutes = switch -Regex ($unit) {
            '^min' { $num }
            '^hour|^hr' { $num * 60 }
            '^day' { $num * 1440 }
        }
        return @{ interval_minutes = $intervalMinutes; max_attempts = $maxAttempts }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Error "Prompt cannot be empty."
    exit 1
}

# Resolve repo root: this script lives at Skills/Workflows/Scheduler/ (3 levels
# under the repo root), so three ".." segments reach salmon-orchestrator.
# (A previous version used four ".." and overshot one level above the repo
# root, writing schedule files outside the repo where the poller never read
# them — see ADR 0045, now Superseded, for the abandoned bare-path design.)
$scheduleDir = Join-Path (Resolve-Path "$PSScriptRoot/../../..") "Tasks" "Schedule"
$null = New-Item -ItemType Directory -Path $scheduleDir -Force -ErrorAction SilentlyContinue

$existingFiles = @(Get-ChildItem -Path $scheduleDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
if ($existingFiles.Count -gt 20) {
    Write-Warning "Tasks/Schedule/ has $($existingFiles.Count) files — consider reviewing and cleaning up stale entries."
}

$today = Get-Date -Format "yyyyMMdd"
$highestSeq = 0
foreach ($f in $existingFiles) {
    if ($f.BaseName -match "^sched-$today-(\d+)$") {
        $seq = [int]$matches[1]
        if ($seq -gt $highestSeq) { $highestSeq = $seq }
    }
}
$nextSeq = $highestSeq + 1
$id = "sched-$today-$($nextSeq.ToString('000'))"

$scheduledAt = ConvertFrom-NaturalDue -DueText $Due
$repeatObj = ConvertFrom-NaturalRepeat -RepeatText $Repeat

if ($Type -eq "alignment-audit") {
    $auditFiles = @(Get-ChildItem -Path $scheduleDir -Filter "audit-cyc-*.json" -File -ErrorAction SilentlyContinue)
    $cycSeq = 0
    foreach ($af in $auditFiles) {
        if ($af.BaseName -match "^audit-cyc-$today-(\d+)$") {
            $seq = [int]$matches[1]
            if ($seq -gt $cycSeq) { $cycSeq = $seq }
        }
    }
    $cycleId = "cyc-$today-$($cycSeq.ToString('000'))"
    $requestedBy = if ($RequestedBy) { $RequestedBy } else { $env:USERNAME }

    $schedule = @{
        id            = $id
        type          = "alignment-audit"
        cycle_id      = $cycleId
        requested_by  = $requestedBy
        status        = "pending"
        created_at    = (Get-Date).ToString("o")
        scheduled_at  = $scheduledAt
        triggered_at  = $null
        completed_at  = $null
        error         = $null
    }
} else {
    $schedule = @{
        id            = $id
        type          = "custom"
        prompt        = $Prompt
        agent         = $Agent
        status        = "pending"
        created_at    = (Get-Date).ToString("o")
        scheduled_at  = $scheduledAt
        repeat        = $repeatObj
        attempt       = 1
        max_attempts  = if ($repeatObj) { $repeatObj.max_attempts } else { $null }
        handoff_path  = if ($HandoffPath) { $HandoffPath } else { $null }
        model         = if ($Model) { $Model } else { $null }
        triggered_at  = $null
        completed_at  = $null
        error         = $null
    }
}

if ($WhatIf) {
    Write-Host "=== WhatIf: Would write schedule ==="
    $schedule | ConvertTo-Json -Depth 5
    Write-Host "Target: $(Join-Path $scheduleDir "$id.json")"
    exit 0
}

$outputPath = Join-Path $scheduleDir "$id.json"
$schedule | ConvertTo-Json -Depth 5 | Out-File $outputPath -Encoding utf8
Write-Host "Written: $id -> $outputPath"
