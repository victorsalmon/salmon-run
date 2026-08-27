<#
.SYNOPSIS
    Write or remove tempo dispatch override schedule files.
.DESCRIPTION
    Controls built-in code/review dispatch scheduling by writing/removing
    override files at Tasks/Schedule/code-dispatch.json and review-dispatch.json.
    When an override file exists with status "pending", the built-in cron dispatch
    is suppressed and the override takes precedence.
.PARAMETER CodeCron
    Cron expression for code dispatch (e.g. "0 */3 * * *").
.PARAMETER ReviewCron
    Cron expression for review dispatch.
.PARAMETER DisableCode
    Remove the code-dispatch.json override (falls back to built-in defaults).
.PARAMETER DisableReview
    Remove the review-dispatch.json override.
.PARAMETER Status
    Set status on existing override files without removing them ("paused").
.PARAMETER RepoDir
    Repository root directory. Defaults to current working directory.
.EXAMPLE
    .\Write-TempoDispatchConfig.ps1 -CodeCron "0 */3 * * *"
.EXAMPLE
    .\Write-TempoDispatchConfig.ps1 -DisableCode -DisableReview
.EXAMPLE
    .\Write-TempoDispatchConfig.ps1 -Status "paused"
#>
param(
    [Parameter(ParameterSetName = "SetCron")]
    [string]$CodeCron,
    [Parameter(ParameterSetName = "SetCron")]
    [string]$ReviewCron,
    [Parameter(ParameterSetName = "Disable")]
    [switch]$DisableCode,
    [Parameter(ParameterSetName = "Disable")]
    [switch]$DisableReview,
    [Parameter(ParameterSetName = "Status")]
    [string]$Status,
    [string]$RepoDir = (Get-Location).Path
)

$scheduleDir = Join-Path $RepoDir "Tasks" "Schedule"
$null = New-Item -ItemType Directory -Path $scheduleDir -Force -ErrorAction SilentlyContinue

if ($DisableCode) {
    $path = Join-Path $scheduleDir "code-dispatch.json"
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force; Write-Host "Removed $path" }
    else { Write-Host "No code-dispatch.json to remove" }
}

if ($DisableReview) {
    $path = Join-Path $scheduleDir "review-dispatch.json"
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force; Write-Host "Removed $path" }
    else { Write-Host "No review-dispatch.json to remove" }
}

if ($CodeCron) {
    $path = Join-Path $scheduleDir "code-dispatch.json"
    $content = @{
        id = "override-code-dispatch"
        agent = "coder"
        type = "builtin-dispatch"
        repeat = $CodeCron
        status = "pending"
        scheduled_at = ([DateTime]::UtcNow).ToString("o")
    } | ConvertTo-Json
    $content | Out-File $path -Encoding utf8
    Write-Host "Wrote $path with cron: $CodeCron"
}

if ($ReviewCron) {
    $path = Join-Path $scheduleDir "review-dispatch.json"
    $content = @{
        id = "override-review-dispatch"
        agent = "reviewer"
        type = "builtin-dispatch"
        repeat = $ReviewCron
        status = "pending"
        scheduled_at = ([DateTime]::UtcNow).ToString("o")
    } | ConvertTo-Json
    $content | Out-File $path -Encoding utf8
    Write-Host "Wrote $path with cron: $ReviewCron"
}

if ($Status) {
    foreach ($name in @("code-dispatch.json", "review-dispatch.json")) {
        $path = Join-Path $scheduleDir $name
        if (Test-Path $path) {
            try {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                $data.status = $Status
                $data | ConvertTo-Json | Out-File $path -Encoding utf8
                Write-Host "Set status='$Status' on $path"
            } catch { Write-Warning "Failed to update $path : $_" }
        }
    }
}