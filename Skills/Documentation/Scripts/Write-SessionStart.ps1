param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$LogsDir,

    [Parameter()]
    [string]$SessionId,

    [Parameter()]
    [switch]$SkipCompress
)

# Lane/agent-scoped session-start file so concurrent stream coders do not
# clobber each other's start timestamp (see orchestrator-tooling-1). Falls
# back to the process ID so every session has a unique file.
if (-not $SessionId) {
    $SessionId = $env:OC_STREAM_ID ?? $env:OC_RESERVATION_AGENT_ID ?? $PID
}

$timestamp = (Get-Date).ToString('o')
$sessionFile = Join-Path $LogsDir "session-start-$SessionId.log"
$timestamp | Out-File -FilePath $sessionFile -Encoding utf8 -Force
Write-Output "SESSION_START $timestamp (scope=$SessionId)"

# Compress logs older than 48h (runs once per session start)
if (-not $SkipCompress) {
    $compressScript = Join-Path $PSScriptRoot "Compress-OldLogs.ps1"
    if (Test-Path $compressScript) {
        & $compressScript -LogsDir $LogsDir
    }
}
