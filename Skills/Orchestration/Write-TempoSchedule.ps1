<#
.SYNOPSIS
    Schedules a prompt for Tempo to dispatch to mcp_opencode.
.DESCRIPTION
    Writes a schedule JSON to Tasks/Schedule/<id>.json. Tempo's schedule poller
    picks it up at the specified time, checks mcp_opencode health, and POSTs the
    prompt directly to its session API.
.PARAMETER Due
    When to run: "ASAP" (default), "20:00", "in 2 hours", "tomorrow 6am",
    ISO datetime.
.PARAMETER Prompt
    The prompt/task to send to mcp_opencode.
.PARAMETER Repeat
    Repeat interval: "every 30 minutes for 2 hours", "every hour 3 times",
    cron expression. Default: no repeat.
.PARAMETER PassThru
    Return the schedule object and path instead of writing to host.
#>
param(
    [Parameter(Position = 0)]
    [string]$Due = "ASAP",

    [Parameter(Position = 1, Mandatory)]
    [string]$Prompt,

    [Parameter()]
    [string]$Repeat,

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "../..")
$scheduleDir = Join-Path $repoRoot "Tasks" "Schedule"
$null = New-Item -ItemType Directory -Path $scheduleDir -Force -ErrorAction SilentlyContinue

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
            $hours = [int]$matches[1]; $mins = [int]($matches[2] -replace '[^0-9]', '0'); $ampm = $matches[3]
            if ($ampm -eq "pm" -and $hours -lt 12) { $hours += 12 }
            if ($ampm -eq "am" -and $hours -eq 12) { $hours = 0 }
            return (Get-Date).Date.AddDays(1).AddHours($hours).AddMinutes($mins).ToString("o")
        }
        if ($timeStr -match '^(\d{1,2}):(\d{2})$') {
            return (Get-Date).Date.AddDays(1).AddHours([int]$matches[1]).AddMinutes([int]$matches[2]).ToString("o")
        }
    }
    try {
        return ([DateTime]::Parse($DueText)).ToString("o")
    } catch {}
    if ($lower -match '^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$') {
        $hours = [int]$matches[1]; $mins = [int]($matches[2] -replace '[^0-9]', '0'); $ampm = $matches[3]
        if ($ampm -eq "pm" -and $hours -lt 12) { $hours += 12 }
        if ($ampm -eq "am" -and $hours -eq 12) { $hours = 0 }
        $candidate = (Get-Date).Date.AddHours($hours).AddMinutes($mins)
        if ($candidate -le (Get-Date)) { $candidate = $candidate.AddDays(1) }
        return $candidate.ToString("o")
    }
    if ($lower -match '^(\d{1,2}):(\d{2})$') {
        $hours = [int]$matches[1]; $mins = [int]$matches[2]
        $candidate = (Get-Date).Date.AddHours($hours).AddMinutes($mins)
        if ($candidate -le (Get-Date)) { $candidate = $candidate.AddDays(1) }
        return $candidate.ToString("o")
    }
    return $null
}

function ConvertFrom-NaturalRepeat {
    param([string]$RepeatText)
    if ([string]::IsNullOrWhiteSpace($RepeatText)) { return $null }
    $lower = $RepeatText.ToLowerInvariant().Trim()
    if ($lower -match '^[\d*,/\-\s]+$' -and ($lower -split '\s+').Count -eq 5) {
        return $lower.Trim()
    }
    if ($lower -match '^every\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s+for\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s*$') {
        $num = [int]$matches[1]; $unit = $matches[2]
        $num2 = [int]$matches[3]; $unit2 = $matches[4]
        $intervalMinutes = switch -Regex ($unit) { '^min' { $num } '^hour|^hr' { $num * 60 } '^day' { $num * 1440 } }
        $totalMinutes = switch -Regex ($unit2) { '^min' { $num2 } '^hour|^hr' { $num2 * 60 } '^day' { $num2 * 1440 } }
        $maxAttempts = [math]::Max(1, [math]::Floor($totalMinutes / $intervalMinutes))
        return @{ interval_minutes = $intervalMinutes; max_attempts = $maxAttempts }
    }
    if ($lower -match '^every\s+(\d+)\s*(minute|minutes|min|hour|hours|hr|day|days)\s+(\d+)\s*times?\s*$') {
        $num = [int]$matches[1]; $unit = $matches[2]
        $maxAttempts = [int]$matches[3]
        $intervalMinutes = switch -Regex ($unit) { '^min' { $num } '^hour|^hr' { $num * 60 } '^day' { $num * 1440 } }
        return @{ interval_minutes = $intervalMinutes; max_attempts = $maxAttempts }
    }
    return $null
}

$today = Get-Date -Format "yyyyMMdd"
$existingFiles = @(Get-ChildItem -Path $scheduleDir -Filter "*.json" -File)
$highestSeq = 0
foreach ($f in $existingFiles) {
    if ($f.BaseName -match "^sched-$today-(\d+)$") {
        $seq = [int]$matches[1]
        if ($seq -gt $highestSeq) { $highestSeq = $seq }
    }
}
$id = "sched-$today-$($highestSeq.ToString('000'))"

$scheduledAt = ConvertFrom-NaturalDue -DueText $Due
$repeatObj = ConvertFrom-NaturalRepeat -RepeatText $Repeat

$schedule = @{
    id            = $id
    type          = "custom"
    prompt        = $Prompt
    agent         = "any"
    status        = "pending"
    created_at    = (Get-Date).ToString("o")
    scheduled_at  = $scheduledAt
    repeat        = $repeatObj
    attempt       = 1
    max_attempts  = if ($repeatObj) { $repeatObj.max_attempts } else { $null }
    handoff_path  = $null
    model         = $null
    triggered_at  = $null
    completed_at  = $null
    error         = $null
}

$outputPath = Join-Path $scheduleDir "$id.json"

if ($PassThru) {
    return [PSCustomObject]@{ Schedule = $schedule; Path = $outputPath }
}

$schedule | ConvertTo-Json -Depth 5 | Out-File $outputPath -Encoding utf8
Write-Host "Scheduled: tempo $Due $Prompt"
Write-Host "  -> $outputPath"
