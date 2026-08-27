function Get-BodyBuffer {
    param($Body)
    $Json = $Body | ConvertTo-Json -Compress
    return [System.Text.Encoding]::UTF8.GetBytes($Json)
}

function Read-JsonBody {
    param($Request)
    $Reader = $null
    try {
        $Reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
        $Raw = $Reader.ReadToEnd()
        return @{ Success = $true; Payload = $Raw | ConvertFrom-Json }
    } catch { return @{ Success = $false; Error = $_.Exception.Message } }
    finally { if ($Reader) { $Reader.Close() } }
}

function Test-TokenConstantTime {
    param([string]$Provided, [string]$Expected)
    if ([string]::IsNullOrEmpty($Provided) -or [string]::IsNullOrEmpty($Expected)) { return $false }
    try {
        $providedBytes = [System.Text.Encoding]::UTF8.GetBytes($Provided)
        $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($Expected)
        return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($providedBytes, $expectedBytes)
    } catch { return $false }
}

function Test-Auth {
    param($Request, $ExpectedToken)
    $authHeader = $Request.Headers['Authorization']
    if (-not $authHeader) { return $false }
    if ($authHeader -notmatch '^Bearer\s+(.+)$') { return $false }
    return Test-TokenConstantTime -Provided $Matches[1] -Expected $ExpectedToken
}

function Get-AuditState {
    param($StateFilePath)
    if (-not $StateFilePath -or -not (Test-Path $StateFilePath)) { return @{ current_state = "IDLE"; cycle_id = "none" } }
    try { $data = Get-Content $StateFilePath -Raw | ConvertFrom-Json; return $data } catch { return @{ current_state = "IDLE"; cycle_id = "none" } }
}

function Get-DeployStatus {
    param($StateFilePath)
    $stateData = Get-AuditState -StateFilePath $StateFilePath
    if ($stateData.current_state -ne "IDLE") { return @{ current_state = $stateData.current_state; deploy_dry_run_log = $stateData.deploy_dry_run_log; deploy_execute_run_id = $stateData.deploy_execute_run_id; deploy_status = $stateData.deploy_status } }
    return @{ current_state = "IDLE"; deploy_status = $null }
}

function Invoke-DockerServiceUpdate {
    param([string]$StackName)
    $svcName = "${StackName}_is-fleet"
    $result = Invoke-NativeCommand -FilePath "docker" -ArgumentList @("service", "update", "--force", $svcName)
    $output = if ($result.StdOut) { $result.StdOut.Trim() } else { "" }
    $exitCode = if ($null -ne $result.ExitCode) { $result.ExitCode } else { 0 }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Invoke-DockerStackPs {
    param([string]$StackName)
    $result = Invoke-NativeCommand -FilePath "docker" -ArgumentList @("stack", "ps", $StackName, "--format", "{{.Name}} {{.CurrentState}}")
    $output = if ($result.StdOut) { $result.StdOut.Trim() } else { "" }
    return $output
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

function Invoke-OperationalRouteDispatch {
    param($Path, $Request, $authOk, $stackName, $fleetApiToken, $stateFilePath)
    if ($Path -eq '/api/health') {
        $Body = @{ status = "ok"; service = "is-fleet-operational"; timestamp = ([DateTime]::UtcNow.ToString('o')) }
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer $Body; ContentType = "application/json" }
    }
    if ($Path -eq '/api/audit/state') {
        if (-not $authOk) { return @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "forbidden" } } }
        $stateData = Get-AuditState -StateFilePath $stateFilePath
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer $stateData; ContentType = "application/json" }
    }
    if ($Path -eq '/api/deploy/status') {
        if (-not $authOk) { return @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "forbidden" } } }
        $deployStatus = Get-DeployStatus -StateFilePath $stateFilePath
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer $deployStatus; ContentType = "application/json" }
    }
    if ($Path -eq '/api/deploy/fleet-update') {
        if (-not $authOk) { return @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "forbidden" } } }
        $null = Read-JsonBody $Request
        try {
            $updateResult = Invoke-DockerServiceUpdate -StackName $stackName
            if ($updateResult.ExitCode -eq 0) { return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "triggered"; message = "Fleet service update initiated"; output = $updateResult.Output }; ContentType = "application/json" } }
            return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "DOCKER_ERROR"; message = "docker exit code $($updateResult.ExitCode)"; output = $updateResult.Output }; ContentType = "application/json" }
        } catch { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "INTERNAL_ERROR"; message = $_.Exception.Message }; ContentType = "application/json" } }
    }
    if ($Path -eq '/api/fleet/services') {
        if (-not $authOk) { return @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "forbidden" } } }
        try {
            $serviceOutput = Invoke-DockerStackPs -StackName $stackName
            $lines = @($serviceOutput -split "`n" | Where-Object { $_ -match '\S' }); $services = @{}
            foreach ($line in $lines) { $parts = $line -split '\s+', 2; if ($parts.Count -ge 2) { $services[$parts[0]] = $parts[1] } }
            return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ services = $services; stack = $stackName }; ContentType = "application/json" }
        } catch { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "INTERNAL_ERROR"; message = $_.Exception.Message }; ContentType = "application/json" } }
    }
    if ($Path -eq '/api/routes') {
        if (-not $authOk) { return @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "forbidden" } } }
        $routes = @( @{ method = "GET"; path = "/api/health"; description = "Liveness check" }; @{ method = "GET"; path = "/api/audit/state"; description = "Current audit cycle state" }; @{ method = "GET"; path = "/api/deploy/status"; description = "Deploy status" }; @{ method = "POST"; path = "/api/deploy/fleet-update"; description = "Trigger fleet self-update" }; @{ method = "GET"; path = "/api/fleet/services"; description = "Fleet service status" }; @{ method = "GET"; path = "/api/routes"; description = "Route discovery" } )
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ routes = $routes }; ContentType = "application/json" }
    }
    return @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "NOT_FOUND"; message = "path not found" } }
}

function Invoke-OperationalListenerLoop {
    param([int]$Port)
    $fleetApiTokenRaw = Get-Content "/run/secrets/fleet_api_token" -Raw -ErrorAction SilentlyContinue
    $fleetApiToken = if ($fleetApiTokenRaw) { $fleetApiTokenRaw.Trim() } else { $null }
    $script:RateLimiter = New-InlineRateLimiter -Limit 100 -WindowSec 60
    $Listener = [System.Net.HttpListener]::new()
    $Listener.Prefixes.Add("http://+:$Port/")
    try { $Listener.Start() } catch { return @{ Error = $_.Exception.Message } }
    $reportsDir = if ($env:ORCHESTRATOR_AUDIT_CYCLE_DIR) { $env:ORCHESTRATOR_AUDIT_CYCLE_DIR } else { Join-Path $HOME ".ORCHESTRATOR" "workspace" "reports" }
    $stateFilePath = Join-Path $reportsDir "audit-cycle-state.json"
    Write-Verbose (ConvertTo-Json @{ event = "operational_listener_started"; port = $Port } -Compress)
    try {
        while ($Listener.IsListening) {
            $Context = $Listener.GetContext()
            $Request = $Context.Request
            $Response = $Context.Response
            $Path = $Request.Url.AbsolutePath
            $Method = $Request.HttpMethod
            $Response.Headers.Add('Access-Control-Allow-Origin', '*')
            $Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
            if ($Method -eq 'OPTIONS') { $Response.StatusCode = 204; $Response.Close(); continue }
            $clientKey = $Request.Headers['Authorization']
            if (-not $clientKey) { $clientKey = $Request.RemoteEndPoint.Address.ToString() }
            if (-not $script:RateLimiter.IsAllowed($clientKey)) {
                $retryAfter = $script:RateLimiter.CooldownSec
                $Buffer = Get-BodyBuffer @{ error = "rate_limit_exceeded"; retry_after = $retryAfter }
                $Response.StatusCode = 429; $Response.Headers.Add('Retry-After', "$retryAfter"); $Response.ContentType = 'application/json'; $Response.ContentLength64 = $Buffer.Length; $Response.OutputStream.Write($Buffer, 0, $Buffer.Length); $Response.Close(); continue
            }
            $authOk = Test-Auth -Request $Request -ExpectedToken $fleetApiToken
            $stackName = if (Get-Command Get-StackName -ErrorAction SilentlyContinue) { Get-StackName } else { $env:INSTALL_PROJECT }
            $Result = Invoke-OperationalRouteDispatch -Path $Path -Request $Request -authOk $authOk -stackName $stackName -fleetApiToken $fleetApiToken -stateFilePath $stateFilePath
            $Buffer = if ($Result.Buffer) { $Result.Buffer } else { [System.Text.Encoding]::UTF8.GetBytes('{}') }
            $Response.StatusCode = if ($Result.StatusCode) { $Result.StatusCode } else { 200 }
            if ($Result.ContentType) { $Response.ContentType = $Result.ContentType }
            $Response.ContentLength64 = $Buffer.Length; $Response.OutputStream.Write($Buffer, 0, $Buffer.Length); $Response.Close()
            if ($Response.StatusCode -ge 500) { $script:RateLimiter.RecordError($clientKey) }
        }
    } finally {
        try { $Listener.Stop() } catch { Write-Debug "Start-FleetOperationalListener: Listener.Stop() failed: $($_.Exception.Message)" }
        $Listener.Close()
    }
}
