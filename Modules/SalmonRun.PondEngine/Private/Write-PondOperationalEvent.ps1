function Write-PondOperationalEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][object]$Entry
    )

    $fullPlan = [IO.Path]::GetFullPath($PlanPath)
    $cursor = Split-Path $fullPlan -Parent
    $taskHome = $null
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if ((Split-Path $cursor -Leaf) -eq 'Tasks') {
            $taskHome = Split-Path $cursor -Parent
            break
        }
        $parent = Split-Path $cursor -Parent
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if (-not $taskHome) { $taskHome = if ($env:SALMON_RUN_HOME) { $env:SALMON_RUN_HOME } else { Split-Path (Split-Path $fullPlan -Parent) -Parent } }

    $logDir = Join-Path $taskHome 'Logs'
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $journal = Join-Path $logDir 'workflow-events.jsonl'
    $payload = [ordered]@{ ts = [datetimeoffset]::UtcNow.ToString('o'); plan = [IO.Path]::GetFileName($PlanPath) }
    foreach ($property in ([pscustomobject]$Entry).PSObject.Properties) { $payload[$property.Name] = $property.Value }
    if (-not $payload.Contains('ts') -or [string]::IsNullOrWhiteSpace([string]$payload.ts)) { $payload.ts = [datetimeoffset]::UtcNow.ToString('o') }

    $mutex = [Threading.Mutex]::new($false, 'Global\SalmonRun-WorkflowEventJournal')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([timespan]::FromSeconds(15)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'workflow event journal lock timeout' }
        if ((Test-Path $journal) -and (Get-Item $journal).Length -gt 10MB) {
            $archive = Join-Path $logDir 'workflow-events.previous.jsonl'
            Move-Item $journal $archive -Force
        }
        Add-Content -LiteralPath $journal -Value (($payload | ConvertTo-Json -Compress -Depth 5)) -Encoding utf8
    } finally {
        if ($acquired) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return [pscustomobject]$payload
}