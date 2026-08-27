<#
.SYNOPSIS
Writes an audit log entry for Bookkeeper operations.
.PARAMETER Capability
The capability that was checked.
.PARAMETER Action
The action that was performed.
.PARAMETER Context
Additional context as a hashtable.
.PARAMETER Result
The result of the operation (allow/deny).
#>
function Write-BookkeepingAuditEntry {
    [CmdletBinding()]
    param(
        [string]$Capability,
        [string]$Action,
        [hashtable]$Context = @{},
        [string]$Result = 'allow'
    )

    $entry = [ordered]@{
        ts     = [datetime]::UtcNow.ToString('o')
        cap    = $Capability
        act    = $Action
        caller = if ($MyInvocation.Line) { $MyInvocation.Line.Substring(0, [math]::Min(200, $MyInvocation.Line.Length)) } else { 'unknown' }
        result = $Result
        ctx    = $Context
    }

    try {
        $dir = Split-Path $script:BookkeepingAuditLogPath -Parent
        if (-not (Test-Path $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        if (Test-Path $dir) {
            ($entry | ConvertTo-Json -Compress -Depth 5) | Out-File -FilePath $script:BookkeepingAuditLogPath -Encoding UTF8 -Append
        }
    }
    catch {
        # Silently swallow — warnings on the failure path pollute the parent's
        # JSON output stream. The audit log is best-effort; caller already has
        # the operation result in its hands.
    }
}
