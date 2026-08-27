function Invoke-LocalCommand {
    param([scriptblock]$Cmd)
    $Output = & $Cmd
    $ExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ Output = $Output; ExitCode = $ExitCode; Success = ($ExitCode -eq 0) }
}

function Get-BodyBuffer {
    param($Body)
    $Json = $Body | ConvertTo-Json -Compress
    return [System.Text.Encoding]::UTF8.GetBytes($Json)
}

function Resolve-GitRepoPath {
    param([string]$RepoName)
    $mappingJson = [Environment]::GetEnvironmentVariable('GIT_REPO_MAPPING')
    if ($mappingJson) {
        try { $mapping = $mappingJson | ConvertFrom-Json; if ($mapping.$RepoName) { return $mapping.$RepoName } } catch { Write-Warning "Failed to parse GIT_REPO_MAPPING: $_" }
    }
    $defaults = @{ 'intersite-docs' = '/home/node/app/repo' }
    if ($defaults.ContainsKey($RepoName)) { return $defaults[$RepoName] }
    throw "Unknown git repo: $RepoName"
}

function Invoke-GitStatus {
    param([string]$RepoPath)
    return (git -C "$RepoPath" status --porcelain 2>&1) | Out-String
}

function Invoke-GitPull {
    param([string]$RepoPath)
    $fetchOutput = git -C "$RepoPath" fetch origin 2>&1 | Out-String
    $pullOutput = git -C "$RepoPath" pull --rebase 2>&1 | Out-String
    return "${fetchOutput}${pullOutput}"
}

function Invoke-GitCommitPush {
    param([string]$RepoPath, [string]$CommitMessage, [string]$AuthorName = 'Orchestrator Bot', [string]$AuthorEmail = 'orchestrator@clocklobster.com', [string[]]$Files)
    $porcelain = git -C "$RepoPath" status --porcelain 2>&1
    if ([string]::IsNullOrWhiteSpace($porcelain)) { return @{ status = 'clean' } }
    git -C "$RepoPath" config user.name $AuthorName
    git -C "$RepoPath" config user.email $AuthorEmail
    if ($Files -and $Files.Count -gt 0) { foreach ($f in $Files) { git -C "$RepoPath" add $f } } else { git -C "$RepoPath" add -A }
    git -C "$RepoPath" commit -m $CommitMessage 2>&1 | Out-Null
    git -C "$RepoPath" fetch origin 2>&1 | Out-Null
    git -C "$RepoPath" pull --rebase 2>&1 | Out-Null
    git -C "$RepoPath" push 2>&1 | Out-Null
    $shortHash = (git -C "$RepoPath" rev-parse --short HEAD).Trim()
    return @{ status = 'committed'; commit = $shortHash; repo = $RepoPath }
}

function Read-JsonBody {
    param($Request)
    $Reader = $null
    try {
        $Reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
        $Raw = $Reader.ReadToEnd()
        return $Raw | ConvertFrom-Json
    } catch { return $null }
    finally { if ($Reader) { $Reader.Close() } }
}

function Deny-External {
    $Buffer = Get-BodyBuffer @{ error = "forbidden - external requests not allowed" }
    return @{ StatusCode = 403; Buffer = $Buffer }
}

function Deny-Method {
    param([string]$Expected)
    $Buffer = Get-BodyBuffer @{ error = "method not allowed - use $Expected" }
    return @{ StatusCode = 405; Buffer = $Buffer }
}

function Add-CorsHeaders {
    param($Response)
    $Response.Headers.Add('Access-Control-Allow-Origin', '*')
    $Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
    $Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
}

function Invoke-ReadBody {
    param($Request)
    try { $Payload = Read-JsonBody $Request; return @{ Success = $true; Payload = $Payload } }
    catch { $Buffer = Get-BodyBuffer @{ error = "invalid JSON: $($_.Exception.Message)" }; return @{ Success = $false; StatusCode = 400; Buffer = $Buffer } }
}

function New-InlineRateLimiter {
    param($Limit = 100, $WindowSec = 60, $CooldownSec = 30)
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
            if (-not $this.Trackers.ContainsKey($ClientKey)) { $this.Trackers[$ClientKey] = @{ Timestamps = [System.Collections.ArrayList]::new(); ErrorCount = 0; InCooldown = $false; CooldownUntil = $null }; return $true }
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
        } finally { $this.Lock.ReleaseMutex() }
    }
    $rl | Add-Member -MemberType ScriptMethod -Name 'RecordError' -Force -Value {
        param($ClientKey)
        $this.Lock.WaitOne() | Out-Null
        try {
            if (-not $this.Trackers.ContainsKey($ClientKey)) { return }
            $t = $this.Trackers[$ClientKey]
            $t.ErrorCount++
            $total = $t.Timestamps.Count
            if ($total -gt 0 -and ($t.ErrorCount / $total) -gt 0.5) { $t.InCooldown = $true; $t.CooldownUntil = [DateTime]::UtcNow.AddSeconds($this.CooldownSec) }
        } finally { $this.Lock.ReleaseMutex() }
    }
    return $rl
}
