<#
.SYNOPSIS
    Gets the hash of the last audit entry in the chain for a domain.
.PARAMETER Domain
    Audit domain namespace. Used to resolve the log file path.
#>
function Get-LastHash {
    [OutputType([string])]
    param([string]$Domain)
    $logPath = Get-AuditLogPath -Domain $Domain
    if (-not (Test-Path $logPath)) { return '' }
    $lastLine = Get-Content -LiteralPath $logPath -Tail 1 -ErrorAction SilentlyContinue
    if (-not $lastLine) { return '' }
    try {
        $entry = $lastLine | ConvertFrom-Json -ErrorAction Stop
        return $entry.hash
    } catch {
        return ''
    }
}
