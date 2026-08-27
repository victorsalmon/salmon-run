<#
.SYNOPSIS
Writes an audit log entry for marketer operations.
.DESCRIPTION
Appends a single JSONL entry under a named mutex so concurrent callers cannot
lose entries. Each entry carries a SHA-256 hash and a prev link (ADR-0023)
mirroring the SalmonRun.Audit hash-chain pattern. The only read is an O(1)
tail-1 lookup of the previous hash under the mutex - never a whole-file
read-modify-write.
.PARAMETER Capability
The capability that was checked.
.PARAMETER Action
The action that was performed.
.PARAMETER Context
Additional context as a hashtable.
.PARAMETER Result
The result of the operation (allow/deny).
#>
function Write-MarketerAuditEntry {
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

    $mutexName = 'Global\InterclawMarketerAuditLog'
    $mutex = $null
    $mutexOwned = $false
    try {
        $dir = Split-Path $script:MarketerAuditLogPath -Parent
        if (-not (Test-Path $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }

        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $mutexOwned = $mutex.WaitOne(5000)
        if (-not $mutexOwned) {
            Write-Warning "Write-MarketerAuditEntry: mutex timeout for audit log '$($script:MarketerAuditLogPath)' after 5s"
            return
        }

        $prev = ''
        if (Test-Path $script:MarketerAuditLogPath) {
            $lastLine = Get-Content -LiteralPath $script:MarketerAuditLogPath -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) {
                try {
                    $lastEntry = $lastLine | ConvertFrom-Json -ErrorAction Stop
                    $prev = [string]$lastEntry.hash
                } catch {
                    $prev = ''
                }
            }
        }

        $orderedKeys = $entry.Keys | Sort-Object
        $orderedEntry = [ordered]@{}
        foreach ($key in $orderedKeys) {
            $orderedEntry[$key] = $entry[$key]
        }
        $entryJson = $orderedEntry | ConvertTo-Json -Compress -Depth 5
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($entryJson)
        $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($hashBytes)) -replace '-', ''
        $orderedEntry['prev'] = $prev
        $orderedEntry['hash'] = $hash.ToLower()

        $line = $orderedEntry | ConvertTo-Json -Compress -Depth 5
        Add-Content -LiteralPath $script:MarketerAuditLogPath -Value $line -Encoding utf8
    }
    catch {
        Write-Warning "Failed to write audit entry: $_"
    }
    finally {
        if ($mutex) {
            if ($mutexOwned) {
                try { $mutex.ReleaseMutex() } catch { Write-Debug "Write-MarketerAuditEntry: mutex release failed: $_" }
            }
            $mutex.Dispose()
        }
    }
}
