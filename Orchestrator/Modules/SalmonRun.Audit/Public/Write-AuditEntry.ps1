<#
.SYNOPSIS
    Writes a signed hash-chain entry to the audit log for a domain.
.PARAMETER Entry
    Hashtable of the audit event data. Must include at minimum 'ts' (ISO 8601 timestamp)
    and 'agent' fields; these are auto-populated if missing.
.PARAMETER Domain
    Audit domain namespace (e.g. 'Bookkeeper', 'marketer', 'web', 'deploy', 'adhoc').
    Determines the JSONL log file path.
#>
function Write-AuditEntry {
    [OutputType([void])]
    param(
        [hashtable]$Entry,
        [string]$Domain
    )
    if (-not $Entry.ContainsKey('ts')) {
        $Entry.ts = (Get-Date -Format o)
    }
    if (-not $Entry.ContainsKey('agent')) {
        $Entry.agent = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { 'unknown' }
    }

    $logPath = Get-AuditLogPath -Domain $Domain
    $mutexName = "Global\AuditLog_$($Domain.Replace('\', '_').Replace('/', '_'))"

    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        if (-not $mutex.WaitOne(5000)) {
            Write-Warning "Write-AuditEntry: mutex timeout for domain '$Domain' after 5s"
            return
        }

        Invoke-AuditLogRotation -LogPath $logPath

        $chain = New-HashChainEntry -Entry $Entry -ChainFile $logPath
        $Entry.prev = $chain.prev
        $Entry.hash = $chain.hash
        $entryJson = $Entry | ConvertTo-Json -Compress -Depth 10
        Add-Content -LiteralPath $logPath -Value $entryJson -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Warning "Write-AuditEntry failed for domain '$Domain': $_"
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { Write-Warning "Write-AuditEntry: mutex release failed for domain '$Domain': $_" }
            $mutex.Dispose()
        }
    }
}
