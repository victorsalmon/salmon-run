<#
.SYNOPSIS
    Verifies the hash-chain integrity of audit log entries.
.PARAMETER Domain
    Audit domain namespace. Used to resolve the log file path when ChainFile is not specified.
.PARAMETER ChainFile
    Explicit path to an audit JSONL file. If not provided, the path is resolved from Domain.
#>
function Test-AuditChainIntegrity {
    [OutputType([pscustomobject])]
    param(
        [string]$Domain,
        [string]$ChainFile
    )
    if (-not $ChainFile) {
        $logPath = Get-AuditLogPath -Domain $Domain
    } else {
        $logPath = $ChainFile
    }
    if (-not (Test-Path $logPath)) {
        return [pscustomobject]@{ Valid = $true; Entries = 0; BrokenLinks = @() }
    }
    $lines = Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) {
        return [pscustomobject]@{ Valid = $true; Entries = 0; BrokenLinks = @() }
    }
    $entries = @()
    foreach ($line in $lines) {
        try {
            $entries += $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Valid = $false; Entries = $lines.Count; BrokenLinks = @(@{Index = $entries.Count; Reason = 'ParseError' }) }
        }
    }
    $broken = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        $entryObj = $entry.PSObject.Copy()
        $entryObj.PSObject.Properties.Remove('prev')
        $entryObj.PSObject.Properties.Remove('hash')

        $sortedObj = [ordered]@{}
        $entryObj.PSObject.Properties.Name | Sort-Object | ForEach-Object { $sortedObj[$_] = $entryObj.$_ }
        $canonicalJson = $sortedObj | ConvertTo-Json -Compress -Depth 10
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalJson)
        $computedHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($hashBytes)) -replace '-', ''
        $computedHash = $computedHash.ToLower()
        if ($entry.hash -ne $computedHash) {
            $legacyJson = $entryObj | ConvertTo-Json -Compress -Depth 10
            $legacyBytes = [System.Text.Encoding]::UTF8.GetBytes($legacyJson)
            $legacyHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($legacyBytes)) -replace '-', ''
            $legacyHash = $legacyHash.ToLower()
            if ($entry.hash -ne $legacyHash) {
                $broken += @{ Index = $i; Reason = "HashMismatch: sorted=$computedHash legacy=$legacyHash, got $($entry.hash)" }
            }
            continue
        }
        if ($i -gt 0) {
            if ($entry.prev -ne $entries[$i - 1].hash) {
                $broken += @{ Index = $i; Reason = "PrevMismatch: expected $($entries[$i-1].hash), got $($entry.prev)" }
            }
        } else {
            if ($entry.prev -ne '') {
                $broken += @{ Index = 0; Reason = 'GenesisPrevNotEmpty' }
            }
        }
    }
    return [pscustomobject]@{
        Valid       = $broken.Count -eq 0
        Entries     = $entries.Count
        BrokenLinks = $broken
    }
}
