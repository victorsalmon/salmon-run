<#
.SYNOPSIS
    Retrieves audit trail entries from the JSONL log file for a given domain.
.PARAMETER Domain
    Audit domain namespace. Used to resolve the log file path.
.PARAMETER Since
    Optional datetime filter — only entries with ts >= Since are returned.
.PARAMETER Endpoint
    Optional endpoint filter — only entries whose action or URI match this string are returned.
.PARAMETER IncludeErrors
    If set, includes entries that contain error details. By default, error entries are excluded.
.PARAMETER Last
    Maximum number of entries to return (most recent). Defaults to 50.
.PARAMETER Verify
    If set, runs Test-AuditChainIntegrity on the domain before returning entries and warns on failure.
#>
function Get-AuditTrail {
    [OutputType([pscustomobject[]])]
    param(
        [string]$Domain,
        [datetime]$Since,
        [string]$Endpoint,
        [switch]$IncludeErrors,
        [int]$Last = 50,
        [switch]$Verify
    )
    $logPath = Get-AuditLogPath -Domain $Domain
    if (-not (Test-Path $logPath)) { return @() }
    $lines = Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) { return @() }
    $entries = foreach ($line in $lines) {
        try {
            $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Get-AuditTrail: failed to parse audit entry: $_"
        }
    }
    if (-not $entries) { return @() }
    if ($Since) {
        $sinceUtc = $Since.ToUniversalTime()
        $entries = $entries | Where-Object { try { ([datetime]::Parse($_.ts).ToUniversalTime()) -ge $sinceUtc } catch { $true } }
    }
    if ($Endpoint) {
        $entries = $entries | Where-Object { $_.action -like "*$Endpoint*" -or $_.req.uri -like "*$Endpoint*" }
    }
    if (-not $IncludeErrors) {
        $entries = $entries | Where-Object { -not $_.error }
    }
    if ($entries.Count -gt $Last) {
        $entries = $entries[-$Last..-1]
    }
    if ($Verify) {
        $chainValid = Test-AuditChainIntegrity -Domain $Domain
        if (-not $chainValid.Valid) {
            Write-Warning "Audit chain integrity check failed for domain '$Domain'"
        }
    }
    return [pscustomobject[]]@($entries)
}
