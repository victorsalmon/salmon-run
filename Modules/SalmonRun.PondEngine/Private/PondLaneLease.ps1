function ConvertTo-PondLeaseTimestamp {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime]) { return [datetimeoffset]::new([datetime]$Value) }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed }
    return $null
}
function Write-PondLaneLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LanePath,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][string]$SourcePond,
        [Parameter(Mandatory)][string]$AttemptId,
        [int]$ProcessId = 0
    )
    $path = Join-Path $LanePath '.lease.json'
    $lease = [ordered]@{
        generation = $Generation
        sourcePond = $SourcePond
        attemptId = $AttemptId
        processId = $ProcessId
        heartbeatAt = [datetimeoffset]::UtcNow.ToString('o')
        recoveryObservedGeneration = $null
        recoveryObservedAt = $null
    }
    $tmp = "$path.tmp-$PID-$([guid]::NewGuid().ToString('n'))"
    $lease | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return [pscustomobject]$lease
}

function Update-PondLaneLeaseHeartbeat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LanePath,[int]$ProcessId = 0)
    $path = Join-Path $LanePath '.lease.json'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $lease = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
    if (-not $lease -or [string]::IsNullOrWhiteSpace([string]$lease.generation)) { return $false }
    $lease.heartbeatAt = [datetimeoffset]::UtcNow.ToString('o')
    if ($ProcessId -gt 0) { $lease.processId = $ProcessId }
    $lease.recoveryObservedGeneration = $null
    $lease.recoveryObservedAt = $null
    $tmp = "$path.tmp-$PID-$([guid]::NewGuid().ToString('n'))"
    $lease | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $true
}

