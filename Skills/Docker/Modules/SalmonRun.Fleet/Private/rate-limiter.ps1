function New-RateLimiter {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [int]$Limit = 100,
        [int]$WindowSec = 60,
        [int]$CooldownSec = 30
    )

    $rl = [PSCustomObject]@{
        Limit       = $Limit
        WindowSec   = $WindowSec
        CooldownSec = $CooldownSec
        Trackers    = @{}
        Lock        = [System.Threading.Mutex]::new()
    }

    $rl | Add-Member -MemberType ScriptMethod -Name 'IsAllowed' -Force -Value {
        param($ClientKey)

        $this.Lock.WaitOne() | Out-Null
        try {
            $now = [DateTime]::UtcNow
            if (-not $this.Trackers.ContainsKey($ClientKey)) {
                $this.Trackers[$ClientKey] = @{
                    Timestamps    = [System.Collections.ArrayList]::new()
                    ErrorCount    = 0
                    InCooldown    = $false
                    CooldownUntil = $null
                }
                return $true
            }
            $t = $this.Trackers[$ClientKey]
            if ($t.InCooldown -and $t.CooldownUntil -and $now -lt $t.CooldownUntil) { return $false }
            if ($t.InCooldown) { $t.InCooldown = $false; $t.CooldownUntil = $null }

            $cutoff = $now.AddSeconds(-$this.WindowSec)
            $valid = [System.Collections.ArrayList]::new()
            foreach ($ts in $t.Timestamps) { if ($ts -ge $cutoff) { $valid.Add($ts) | Out-Null } }
            $t.Timestamps = $valid
            if ($t.Timestamps.Count -ge $this.Limit) { return $false }

            $t.Timestamps.Add($now) | Out-Null
            return $true
        }
        finally { $this.Lock.ReleaseMutex() }
    }

    $rl | Add-Member -MemberType ScriptMethod -Name 'RecordError' -Force -Value {
        param($ClientKey)

        $this.Lock.WaitOne() | Out-Null
        try {
            if (-not $this.Trackers.ContainsKey($ClientKey)) { return }
            $t = $this.Trackers[$ClientKey]
            $t.ErrorCount++
            $total = $t.Timestamps.Count
            if ($total -gt 0 -and ($t.ErrorCount / $total) -gt 0.5) {
                $t.InCooldown = $true
                $t.CooldownUntil = [DateTime]::UtcNow.AddSeconds($this.CooldownSec)
            }
        }
        finally { $this.Lock.ReleaseMutex() }
    }

    return $rl
}
