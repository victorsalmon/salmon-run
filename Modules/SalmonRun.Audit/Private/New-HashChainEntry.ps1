function New-HashChainEntry {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [hashtable]$Entry,
        [string]$ChainFile
    )
    $prev = ''
    $mutexName = "Global\AuditChain_$([System.IO.Path]::GetFileName($ChainFile).Replace('\', '_').Replace('/', '_'))"
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        if (-not $mutex.WaitOne(5000)) {
            Write-Warning "New-HashChainEntry: mutex timeout for chain file '$ChainFile' after 5s"
            return [ordered]@{ prev = ''; hash = '' }
        }

        if (Test-Path $ChainFile) {
            $lastLine = Get-Content -LiteralPath $ChainFile -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) {
                try {
                    $lastEntry = $lastLine | ConvertFrom-Json -ErrorAction Stop
                    $prev = $lastEntry.hash
                } catch {
                    $prev = ''
                }
            }
        }

        $orderedKeys = $Entry.Keys | Sort-Object
        $orderedEntry = [ordered]@{}
        foreach ($key in $orderedKeys) {
            $value = $Entry[$key]
            if ($key -eq 'ts') { $value = Get-CanonicalTimestamp $value }
            $orderedEntry[$key] = $value
        }
        $entryJson = $orderedEntry | ConvertTo-Json -Compress -Depth 10
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($entryJson)
        $hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($hashBytes)) -replace '-', ''
        return [ordered]@{
            prev = $prev
            hash = $hash.ToLower()
        }
    } catch {
        Write-Warning "New-HashChainEntry failed: $_"
        return [ordered]@{ prev = ''; hash = '' }
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { Write-Debug "New-HashChainEntry: mutex release failed: $_" }
            $mutex.Dispose()
        }
    }
}
