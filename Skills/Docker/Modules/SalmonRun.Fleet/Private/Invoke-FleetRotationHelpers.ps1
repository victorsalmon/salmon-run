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
        return $Raw | ConvertFrom-Json
    } catch { return $null }
    finally { if ($Reader) { $Reader.Close() } }
}

function Deny-Method {
    param([string]$Expected)
    $Buffer = Get-BodyBuffer @{ error = "method not allowed - use $Expected" }
    return @{ StatusCode = 405; Buffer = $Buffer }
}

function Write-RotationLog {
    param([string]$Message, [string]$Level = "INFO")
    $logDir = "/workspace/logs"; $logFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd').log"
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] [RotationEndpoint] $Message"
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    Add-Content -Path $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-RunningTaskContainer {
    param([string]$ServiceName)
    $tasks = docker service ps $ServiceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tasks) { return $null }
    return ($tasks -split "`n" | Select-Object -First 1).Trim()
}

function Get-CurrentBundle {
    param([string]$ContainerName)
    $bundleJson = Invoke-FleetDockerExec -ContainerName $ContainerName -Command "cat /run/secrets/secrets_bundle"
    if ($LASTEXITCODE -ne 0 -or -not $bundleJson) { return $null }
    return $bundleJson | ConvertFrom-Json -AsHashtable
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

function Invoke-SecretRotationFallback {
    param([string]$ServiceName, [hashtable]$BundleData, [string]$OldSecretName, [string]$NewSecretName, [string]$MountTarget)
    $tempName = "${NewSecretName}_rotating"
    $newJson = $BundleData | ConvertTo-Json -Compress
    try {
        $prevOE = $OutputEncoding; $prevCOE = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $null = $newJson | docker secret create "$tempName" - 2>$null
        [Console]::OutputEncoding = $prevCOE; $OutputEncoding = $prevOE
        if ($LASTEXITCODE -ne 0) { throw "Failed to create temp secret $tempName" }
        $null = docker service update --detach=true --secret-rm="$OldSecretName" --secret-add="source=$tempName,target=$MountTarget" $ServiceName 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Failed to update $ServiceName with temp secret" }
        $null = docker secret rm $OldSecretName 2>$null
        $prevOE = $OutputEncoding; $prevCOE = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $null = $newJson | docker secret create "$NewSecretName" - 2>$null
        [Console]::OutputEncoding = $prevCOE; $OutputEncoding = $prevOE
        if ($LASTEXITCODE -ne 0) { throw "Failed to re-create secret $NewSecretName" }
        $null = docker service update --detach=true --secret-rm="$tempName" --secret-add="source=$NewSecretName,target=$MountTarget" $ServiceName 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Failed to update $ServiceName with final secret" }
        $null = docker secret rm $tempName -ErrorAction SilentlyContinue 2>$null
        return $true
    } catch {
        $null = docker secret rm $tempName -ErrorAction SilentlyContinue 2>$null
        throw
    }
}

function Invoke-RotationRouteDispatch {
    param($Path, $Method, $Request, $Response, $rotationApiToken, $rotationMonitorToken, $AllowedContainers, $stackName, $__rotationModuleLoaded)
    $Result = switch ($Path) {
        "/secret/update" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyResult = try { Read-JsonBody $Request } catch { $null }
                if (-not $bodyResult) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "invalid JSON body" } } }
                else {
                    $container = $bodyResult.container; $key = $bodyResult.key; $value = $bodyResult.value
                    if (-not $container -or -not $key -or -not $value) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required fields: container, key, value" } } }
                    elseif ($container -notin $AllowedContainers) { @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "container not allowed for rotation" } } }
                    else {
                        $serviceName = "${stackName}_${container}"; $secretName = "${stackName}_secrets_bundle"
                        $taskContainer = Get-RunningTaskContainer -ServiceName $serviceName
                        if (-not $taskContainer) { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "no running task found for service $serviceName" } } }
                        else {
                            $currentBundle = Get-CurrentBundle -ContainerName $taskContainer
                            if (-not $currentBundle) { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "could not read secrets_bundle from $taskContainer" } } }
                            elseif (-not $currentBundle.ContainsKey($key)) { @{ StatusCode = 403; Buffer = Get-BodyBuffer @{ error = "key '$key' not found in Orchestrator-scoped bundle" } } }
                            else {
                                $currentValue = $currentBundle[$key]
                                if ($value.Length -ne $currentValue.Length) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "length mismatch: new value length ($($value.Length)) must match current ($($currentValue.Length))" } } }
                                else {
                                    $updatedBundle = @{}; foreach ($k in $currentBundle.Keys) { if ($k -eq $key) { $updatedBundle[$k] = $value } else { $updatedBundle[$k] = $currentBundle[$k] } }
                                    try {
                                        if ($__rotationModuleLoaded) { Invoke-SecretRotation -ServiceName $serviceName -BundleData $updatedBundle -OldSecretName $secretName -NewSecretName $secretName -MountTarget secrets_bundle }
                                        else { Invoke-SecretRotationFallback -ServiceName $serviceName -BundleData $updatedBundle -OldSecretName $secretName -NewSecretName $secretName -MountTarget secrets_bundle }
                                        Write-RotationLog "SECRET_ROTATED container=$container key=$key service=$serviceName"
                                        @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "rotated"; container = $container; key = $key } }
                                    } catch { Write-RotationLog "SECRET_ROTATION_FAILED container=$container key=$key error=$($_.Exception.Message)" -Level "ERROR"; @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "rotation failed: $($_.Exception.Message)" } } }
                                }
                            }
                        }
                    }
                }
            }
        }
        "/rotate" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyResult = try { Read-JsonBody $Request } catch { $null }
                if (-not $bodyResult) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "invalid JSON body" } } }
                elseif (-not $bodyResult.proxy_aws_id -or -not $bodyResult.proxy_aws_secret) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required fields: proxy_aws_id, proxy_aws_secret" } } }
                elseif ($bodyResult.proxy_aws_id.Length -lt 12 -or $bodyResult.proxy_aws_secret.Length -lt 12) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "rotation rejected: values must be at least 12 characters" } } }
                else {
                    $existingId = docker secret inspect "proxy_aws_id" 2>$null; $existingSecret = docker secret inspect "proxy_aws_secret" 2>$null
                    if ($existingId -or $existingSecret) { @{ StatusCode = 409; Buffer = Get-BodyBuffer @{ error = "rotation rejected: one or more target secrets already exist" } } }
                    else {
                        try {
                            $prevOutputEncoding = $OutputEncoding; $prevEncoding = [Console]::OutputEncoding
                            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                            $bodyResult.proxy_aws_id | docker secret create "proxy_aws_id" - 2>&1 | Out-Null
                            [Console]::OutputEncoding = $prevEncoding; $OutputEncoding = $prevOutputEncoding
                            if ($LASTEXITCODE -ne 0) { throw "Failed to create proxy_aws_id secret" }
                            $prevOutputEncoding = $OutputEncoding; $prevEncoding = [Console]::OutputEncoding
                            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                            $bodyResult.proxy_aws_secret | docker secret create "proxy_aws_secret" - 2>&1 | Out-Null
                            [Console]::OutputEncoding = $prevEncoding; $OutputEncoding = $prevOutputEncoding
                            if ($LASTEXITCODE -ne 0) { throw "Failed to create proxy_aws_secret secret" }
                            Write-RotationLog "PROXY_AWS_KEYS_ROTATED" -Level "INFO"
                            @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "rotated"; message = "proxy_aws_id/proxy_aws_secret rotated" } }
                        } catch { Write-RotationLog "PROXY_AWS_ROTATION_FAILED error=$($_.Exception.Message)" -Level "ERROR"; @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "rotation failed: $($_.Exception.Message)" } } }
                    }
                }
            }
        }
        default { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "not found" } } }
    }
    return $Result
}

function Invoke-RotationListenerLoop {
    param([string]$Prefix, [string[]]$AllowedContainers)
    $__rotationModuleLoaded = $false
    try { Import-Module SalmonRun.Secrets -Force -ErrorAction Stop | Out-Null; $__rotationModuleLoaded = $null -ne (Get-Command Invoke-SecretRotation -ErrorAction SilentlyContinue) }
    catch { Write-RotationLog "Could not load SalmonRun.Secrets module — will use inline rotation" -Level "WARN" }
    $stackName = $env:INSTALL_PROJECT
    if (-not $stackName) { $stacks = docker stack ls --format "{{.Name}}" 2>$null; if ($stacks) { $stackName = ($stacks -split "`n")[0].Trim() } }
    $rotationApiToken = Get-Content "/run/secrets/fleet_api_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $rotationMonitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $Listener = [System.Net.HttpListener]::new()
    $Listener.Prefixes.Add($Prefix)
    try { $Listener.Start() } catch { Write-RotationLog "Failed to start rotation endpoint listener: $($_.Exception.Message)" -Level "ERROR"; return }
    try {
        while ($Listener.IsListening) {
            $Context = $Listener.GetContext()
            $Request = $Context.Request; $Response = $Context.Response
            $Path = $Request.Url.PathAndQuery; $Method = $Request.HttpMethod
            if (-not $rotationApiToken -and -not $rotationMonitorToken) {
                $Response.StatusCode = 401; $buffer = Get-BodyBuffer @{ error = "forbidden — no token configured" }; $Response.ContentLength64 = $buffer.Length; $Response.OutputStream.Write($buffer, 0, $buffer.Length); $Response.Close(); continue
            }
            $authHeader = $Request.Headers['Authorization']; $valid = $false; $isMonitor = $false
            if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') {
                $token = $Matches[1]
                if (Test-TokenConstantTime -Provided $token -Expected $rotationApiToken) { $valid = $true }
                elseif (Test-TokenConstantTime -Provided $token -Expected $rotationMonitorToken) { $valid = $true; $isMonitor = $true }
            }
            if (-not $valid) { $Response.StatusCode = 403; $buffer = Get-BodyBuffer @{ error = "forbidden — valid fleet token required" }; $Response.ContentLength64 = $buffer.Length; $Response.OutputStream.Write($buffer, 0, $buffer.Length); $Response.Close(); continue }
            if ($isMonitor -and $Path -notin @('/api/health', '/api/ready')) {
                Write-RotationLog "Monitor token rejected on secret rotation path: $Path" -Level "WARN"
                $Response.StatusCode = 403; $buffer = Get-BodyBuffer @{ error = "forbidden — monitor token cannot rotate secrets" }; $Response.ContentLength64 = $buffer.Length; $Response.OutputStream.Write($buffer, 0, $buffer.Length); $Response.Close(); continue
            }
            $Result = Invoke-RotationRouteDispatch -Path $Path -Method $Method -Request $Request -Response $Response -rotationApiToken $rotationApiToken -rotationMonitorToken $rotationMonitorToken -AllowedContainers $AllowedContainers -stackName $stackName -__rotationModuleLoaded $__rotationModuleLoaded
            $Buffer = if ($Result.Buffer) { $Result.Buffer } else { [System.Text.Encoding]::UTF8.GetBytes('{}') }
            $Response.StatusCode = if ($Result.StatusCode) { $Result.StatusCode } else { 200 }
            if ($Result.ContentType) { $Response.ContentType = $Result.ContentType } else { $Response.ContentType = "application/json" }
            $Response.ContentLength64 = $Buffer.Length; $Response.OutputStream.Write($Buffer, 0, $Buffer.Length); $Response.Close()
        }
    } finally {
        try { $Listener.Stop() } catch { Write-Debug "SecretRotationEndpoint: Listener.Stop() failed: $_" }
        $Listener.Close()
    }
}
