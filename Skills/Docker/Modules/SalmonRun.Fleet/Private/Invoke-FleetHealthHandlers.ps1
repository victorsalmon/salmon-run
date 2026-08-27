function Resolve-StackName {
    if ($CurrentState.StackName) { return $CurrentState.StackName }
    if ($env:INSTALL_PROJECT) { return $env:INSTALL_PROJECT }
    return ""
}

function Test-ContainerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '^[a-zA-Z0-9_-]+$'
}

function Test-ServiceRestartAllowed {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq "is-fleet") { return $false }
    return $restartAllowedServices -contains $Name
}

function Protect-Secrets {
    param([string]$Text)
    $patterns = @('-----BEGIN', 'PRIVATE KEY', 'password', 'secret', 'token')
    foreach ($p in $patterns) { $Text = $Text -replace $p, '***REDACTED***' }
    return $Text
}

function Invoke-Health {
    param($Request, $Response)
    $Now = [DateTime]::UtcNow
    $Uptime = if ($CurrentState.StartTime) { [math]::Floor(($Now - $CurrentState.StartTime).TotalSeconds) } else { 0 }
    $Body = @{ status = $CurrentState.Status; service = 'is-fleet'; version = if ($CurrentState.Version) { $CurrentState.Version } else { '1.0.0' }; uptime = $Uptime; lastUpdate = $CurrentState.LastUpdate; failCount = $CurrentState.FailCount; hostname = $CurrentState.Hostname; stackName = $CurrentState.StackName; timestamp = $Now.ToString('o') }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer $Body; ContentType = "application/json" }
}

function Invoke-Ready {
    param($Request, $Response)
    $IsReady = ($CurrentState.Status -eq "ok") -and ($CurrentState.LastUpdate) -and (([DateTime]::UtcNow - [DateTime]::Parse($CurrentState.LastUpdate)).TotalMinutes -lt 5)
    $Body = @{ ready = $IsReady; status = $CurrentState.Status; lastUpdate = $CurrentState.LastUpdate }
    return @{ StatusCode = if ($IsReady) { 200 } else { 503 }; Buffer = Get-BodyBuffer $Body; ContentType = "application/json" }
}

function Invoke-UpdateState {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    if ($Payload.Status) { $CurrentState.Status = $Payload.Status }
    if ($Payload.FailCount -is [int]) { $CurrentState.FailCount = $Payload.FailCount }
    if ($Payload.LastUpdate) { $CurrentState.LastUpdate = $Payload.LastUpdate }
    if ($Payload.Version) { $CurrentState.Version = $Payload.Version }
    if ($Payload.Hostname) { $CurrentState.Hostname = $Payload.Hostname }
    if ($Payload.StackName) { $CurrentState.StackName = $Payload.StackName }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "updated" }; ContentType = "application/json" }
}

function Invoke-Log {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $LogLevel = if ($Payload.level) { $Payload.level } else { "INFO" }
    $LogSource = if ($Payload.source) { $Payload.source } else { "unknown" }
    $LogMessage = if ($Payload.message) { $Payload.message } else { "" }
    $LogDir = "/workspace/logs"
    $LogFile = Join-Path $LogDir "$(Get-Date -Format 'yyyy-MM-dd').log"
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    # Safe swallow: log writes are best-effort; a log failure must not fail the health request.
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$LogLevel] [$LogSource] $LogMessage" -Encoding utf8 -ErrorAction SilentlyContinue
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "logged" }; ContentType = "application/json" }
}

function Invoke-SecretRefreshSelf {
    param($Request, $Response)
    try {
        $stackName = Resolve-StackName
        $fleetServiceName = "${stackName}_is-fleet"
        $bundlePath = "/run/secrets/secrets_bundle"
        $secretName = "fleet_secrets_bundle"
        $tempName = "fleet_secrets_bundle_rotating"
        if (-not (Test-Path $bundlePath)) { return @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "current secrets bundle not found at ${bundlePath}" }; ContentType = "application/json" } }
        $currentJson = Get-Content $bundlePath -Raw -Encoding UTF8
        $currentBundle = $currentJson | ConvertFrom-Json -AsHashtable
        $fleetAwsId = $currentBundle["fleet_aws_id"]
        $fleetAwsSecret = $currentBundle["fleet_aws_secret"]
        if ([string]::IsNullOrWhiteSpace($fleetAwsId) -or [string]::IsNullOrWhiteSpace($fleetAwsSecret)) { return @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "fleet_aws_id or fleet_aws_secret not found in current bundle" }; ContentType = "application/json" } }
        $env:AWS_ACCESS_KEY_ID = $fleetAwsId; $env:AWS_SECRET_ACCESS_KEY = $fleetAwsSecret; $env:AWS_DEFAULT_REGION = "ca-central-1"
        $awsErr = $null
        $awsOutput = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $awsErr += "$_`n"; $null } else { $_ }
        }
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($awsOutput)) {
            if ($awsErr) { Write-Warning "Invoke-SecretRefreshSelf: AWS SM read failed: $($awsErr.Trim())" }
            return @{ StatusCode = 502; Buffer = Get-BodyBuffer @{ error = "failed to read Interclaw/FRAD/Provisioning from AWS SM" }; ContentType = "application/json" }
        }
        $provisioning = $awsOutput | ConvertFrom-Json
        $freshToken = $provisioning.FLEET_GITHUB_TOKEN_READALL
        $newBundle = @{}
        foreach ($key in $currentBundle.Keys) { $newBundle[$key] = $currentBundle[$key] }
        if (-not [string]::IsNullOrWhiteSpace($freshToken)) { $newBundle["FLEET_GITHUB_TOKEN_READALL"] = $freshToken }
        $newJson = $newBundle | ConvertTo-Json -Compress
        docker secret rm "${tempName}" 2>$null | Out-Null
        $newJson | docker secret create "$tempName" - | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to create temp secret ${tempName}" }; ContentType = "application/json" } }
        docker service update --detach=true --secret-rm="${secretName}" --secret-add="source=${tempName},target=secrets_bundle" $fleetServiceName
        if ($LASTEXITCODE -ne 0) { docker secret rm "$tempName" | Out-Null; return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to swap fleet service to temp secret" }; ContentType = "application/json" } }
        docker secret rm "${secretName}" | Out-Null
        $newJson | docker secret create "${secretName}" - | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to re-create ${secretName}" }; ContentType = "application/json" } }
        docker service update --detach=true --secret-rm="${tempName}" --secret-add="source=${secretName},target=secrets_bundle" $fleetServiceName
        if ($LASTEXITCODE -ne 0) { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to swap fleet service back to final secret" }; ContentType = "application/json" } }
        docker secret rm "${tempName}" | Out-Null
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "refreshed"; service = "is-fleet"; secret = $secretName; keys = $newBundle.Count; github_token_refreshed = (-not [string]::IsNullOrWhiteSpace($freshToken)) }; ContentType = "application/json" }
    } catch { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "refresh failed: $($_.Exception.Message)" }; ContentType = "application/json" } }
}

function Invoke-SecretCheckFreshness {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $containers = @($Payload.containers)
    if ($containers.Count -eq 0) { return @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required field: containers" }; ContentType = "application/json" } }
    $stackName = Resolve-StackName
    $results = @()
    foreach ($container in $containers) {
        if (-not (Test-ContainerName -Name $container)) { Write-Warning "Invoke-SecretCheckFreshness: invalid container name rejected: '$container'"; $results += @{ container = $container; status = "invalid_name" }; continue }
        $resultObj = @{ container = $container }
        try {
            $serviceName = "${stackName}_${container}"
# Safe probe: docker service ps returns empty (exit 0) when no running task exists; absence is handled by the caller as a valid state.
            $taskContainer = docker service ps $serviceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null | Select-Object -First 1
            if (-not $taskContainer) { $resultObj.status = "no_running_task"; $results += $resultObj; continue }
            $bundleJson = Invoke-FleetDockerExec -ContainerName $($taskContainer.Trim()) -Command "cat /run/secrets/secrets_bundle"
            if ($LASTEXITCODE -ne 0 -or -not $bundleJson) { $resultObj.status = "bundle_not_found"; $results += $resultObj; continue }
            $currentBundle = $bundleJson | ConvertFrom-Json -AsHashtable
            $resultObj.bundle_name = "secrets_bundle"; $resultObj.bundle_key_count = ($currentBundle.Keys | Measure-Object).Count
            $fleetAwsId = $currentBundle["fleet_aws_id"]; $fleetAwsSecret = $currentBundle["fleet_aws_secret"]
            if ([string]::IsNullOrWhiteSpace($fleetAwsId) -or [string]::IsNullOrWhiteSpace($fleetAwsSecret)) { $resultObj.status = "no_aws_creds_in_bundle"; $resultObj.aws_key_count = 0; $resultObj.matching_keys = 0; $resultObj.differing_keys = 0; $resultObj.keys_match = $false; $resultObj.values_match = $false; $results += $resultObj; continue }
            $env:AWS_ACCESS_KEY_ID = $fleetAwsId; $env:AWS_SECRET_ACCESS_KEY = $fleetAwsSecret; $env:AWS_DEFAULT_REGION = "ca-central-1"
            $awsErr = $null
            $awsOutput = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $awsErr += "$_`n"; $null } else { $_ }
            }
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($awsOutput)) { $resultObj.status = "aws_unreachable"; if ($awsErr) { $resultObj.error = $awsErr.Trim() }; $resultObj.aws_key_count = 0; $resultObj.matching_keys = 0; $resultObj.differing_keys = 0; $resultObj.keys_match = $false; $resultObj.values_match = $false; $results += $resultObj; continue }
            $provisioning = $awsOutput | ConvertFrom-Json
            $resultObj.aws_key_count = ($provisioning.PSObject.Properties.Name | Measure-Object).Count
            $matching = 0; $differing = 0
            foreach ($k in $currentBundle.Keys) { $awsVal = $provisioning.$k; if ($null -ne $awsVal) { if ("$($currentBundle[$k])" -eq "$awsVal") { $matching++ } else { $differing++ } } }
            $resultObj.matching_keys = $matching; $resultObj.differing_keys = $differing; $resultObj.keys_match = ($differing -eq 0); $resultObj.values_match = ($differing -eq 0); $resultObj.status = "compared"
        } catch { $resultObj.status = "error"; $resultObj.error = $_.Exception.Message }
        $results += $resultObj
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Invoke-RefreshContainers {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $containers = @($Payload.containers)
    if ($containers.Count -eq 0) { return @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required field: containers" }; ContentType = "application/json" } }
    $stackName = Resolve-StackName
    $results = @()
    $fleetAwsId = $null; $fleetAwsSecret = $null
    foreach ($container in $containers) {
        if (-not (Test-ContainerName -Name $container)) { Write-Warning "Invoke-RefreshContainers: invalid container name rejected: '$container'"; $results += @{ container = $container; status = "invalid_name" }; continue }
        $resultObj = @{ container = $container }
        try {
            $serviceName = "${stackName}_${container}"
# Safe probe: docker service ps returns empty (exit 0) when no running task exists; absence is handled by the caller as a valid state.
            $taskContainer = docker service ps $serviceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null | Select-Object -First 1
            if (-not $taskContainer) { $resultObj.status = "no_running_task"; $results += $resultObj; continue }
            $bundleJson = Invoke-FleetDockerExec -ContainerName $($taskContainer.Trim()) -Command "cat /run/secrets/secrets_bundle"
            if ($LASTEXITCODE -ne 0 -or -not $bundleJson) { $resultObj.status = "bundle_not_found"; $results += $resultObj; continue }
            $currentBundle = $bundleJson | ConvertFrom-Json -AsHashtable
            if (-not $fleetAwsId) { $fleetAwsId = $currentBundle["fleet_aws_id"] }
            if (-not $fleetAwsSecret) { $fleetAwsSecret = $currentBundle["fleet_aws_secret"] }
            if ([string]::IsNullOrWhiteSpace($fleetAwsId) -or [string]::IsNullOrWhiteSpace($fleetAwsSecret)) { $resultObj.status = "no_aws_creds"; $resultObj.error = "fleet_aws_id or fleet_aws_secret not found"; $results += $resultObj; continue }
            $env:AWS_ACCESS_KEY_ID = $fleetAwsId; $env:AWS_SECRET_ACCESS_KEY = $fleetAwsSecret; $env:AWS_DEFAULT_REGION = "ca-central-1"
            $awsOutput = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($awsOutput)) { $resultObj.status = "aws_unreachable"; $results += $resultObj; continue }
            $provisioning = $awsOutput | ConvertFrom-Json
            $newBundle = @{}
            foreach ($key in $currentBundle.Keys) { $newBundle[$key] = $currentBundle[$key] }
            foreach ($key in $provisioning.PSObject.Properties.Name) { $val = $provisioning.$key; if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace("$val")) { $newBundle[$key] = "$val" } }
            $newJson = $newBundle | ConvertTo-Json -Compress
            $secretName = "${stackName}_secrets_bundle"; $tempName = "${stackName}_secrets_bundle_rotating"
            # Safe discard: removing a possibly-absent temp secret is best-effort cleanup; failure is benign here.
            docker secret rm "$tempName" 2>$null | Out-Null
            $newJson | docker secret create "$tempName" - | Out-Null
            if ($LASTEXITCODE -ne 0) { $resultObj.status = "failed"; $resultObj.error = "could not create temp secret"; $results += $resultObj; continue }
            docker service update --detach=true --secret-rm="${secretName}" --secret-add="source=${tempName},target=secrets_bundle" $serviceName 2>$null
            if ($LASTEXITCODE -ne 0) { $resultObj.status = "failed"; $resultObj.error = "could not swap service to temp secret"; $results += $resultObj; continue }
            # Safe discard: removing the previous bundle secret is best-effort; the re-create below is the gate.
            docker secret rm "${secretName}" 2>$null | Out-Null
            $newJson | docker secret create "${secretName}" - | Out-Null
            if ($LASTEXITCODE -ne 0) { $resultObj.status = "failed"; $resultObj.error = "could not re-create bundle secret"; $results += $resultObj; continue }
            docker service update --detach=true --secret-rm="${tempName}" --secret-add="source=${secretName},target=secrets_bundle" $serviceName 2>$null
            if ($LASTEXITCODE -ne 0) { $resultObj.status = "failed"; $resultObj.error = "could not swap service back to bundle secret"; $results += $resultObj; continue }
            # Safe discard: removing the temp secret after successful rotation is best-effort cleanup.
            docker secret rm "$tempName" 2>$null | Out-Null
            $resultObj.status = "refreshed"; $resultObj.bundle_name = "secrets_bundle"; $resultObj.key_count = ($newBundle.Keys | Measure-Object).Count
        } catch { $resultObj.status = "failed"; $resultObj.error = $_.Exception.Message }
        $results += $resultObj
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Invoke-CheckStaleness {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $stackName = Resolve-StackName
    $serviceList = @()
    if ($Payload.all -eq $true) { $result = Invoke-LocalCommand { docker service ls --filter "label=com.docker.stack.namespace=${stackName}" --format "{{.Name}}" 2>&1 }; $serviceList = @($result.Output) }
    elseif ($Payload.containers -is [array]) { $serviceList = $Payload.containers | ForEach-Object { if ($_ -match "^${stackName}_") { $_ } else { "${stackName}_$_" } } }
    $expectedHashes = if ($Payload.expected_hashes) { $Payload.expected_hashes } else { @{} }
    $deployCommit = $Payload.deploy_git_commit
    $results = @()
    foreach ($fullName in $serviceList) {
        $container = $fullName -replace "^${stackName}_", ""
        if (-not (Test-ContainerName -Name $container)) { Write-Warning "Invoke-CheckStaleness: invalid container name rejected: '$container'"; $results += @{ container = $container; status = "invalid_name" }; continue }
        $resultObj = @{ container = $container }
        try {
            $inspectResult = Invoke-LocalCommand { docker service inspect $fullName --format '{{index .Spec.TaskTemplate.ContainerSpec.Labels "org.interclaw.is-fleet.source-hash"}}' 2>&1 }
            $currentHash = if ($inspectResult.Success -and $inspectResult.Output) { "$($inspectResult.Output)".Trim() } else { $null }
            if (-not $currentHash) {
                foreach ($altLabel in @("org.interclaw.${container}.source-hash")) {
                    $altResult = Invoke-LocalCommand { docker service inspect $fullName --format "{{index .Spec.TaskTemplate.ContainerSpec.Labels \"$altLabel\"}}" 2>&1 }
                    if ($altResult.Success -and $altResult.Output) { $currentHash = "$($altResult.Output)".Trim(); break }
                }
            }
            $resultObj.current_source_hash = $currentHash
            $resultObj.code_stale = if ($currentHash -and ($expectedHashes.$container)) { $currentHash -ne "$($expectedHashes.$container)" } elseif ($currentHash) { $false } else { $true }
            $secretsStale = $true; $secretsDetail = @{}
            try {
# Safe probe: docker service ps returns empty (exit 0) when no running task exists; absence is handled by the caller as a valid state.
                $taskContainer = docker service ps $fullName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null | Select-Object -First 1
                if ($taskContainer) {
                    $bundleJson = Invoke-FleetDockerExec -ContainerName $($taskContainer.Trim()) -Command "cat /run/secrets/secrets_bundle"
                    if ($LASTEXITCODE -eq 0 -and $bundleJson) {
                        $currentBundle = $bundleJson | ConvertFrom-Json -AsHashtable
                        $secretsDetail.bundle_key_count = ($currentBundle.Keys | Measure-Object).Count
                        $fleetAwsId = $currentBundle["fleet_aws_id"]; $fleetAwsSecret = $currentBundle["fleet_aws_secret"]
                        if (-not [string]::IsNullOrWhiteSpace($fleetAwsId) -and -not [string]::IsNullOrWhiteSpace($fleetAwsSecret)) {
                            $env:AWS_ACCESS_KEY_ID = $fleetAwsId; $env:AWS_SECRET_ACCESS_KEY = $fleetAwsSecret; $env:AWS_DEFAULT_REGION = "ca-central-1"
                            $awsErr = $null
                            $awsOutput = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text 2>&1 | ForEach-Object {
                                if ($_ -is [System.Management.Automation.ErrorRecord]) { $awsErr += "$_`n"; $null } else { $_ }
                            }
                            if ($LASTEXITCODE -eq 0 -and $awsOutput) {
                                $provisioning = $awsOutput | ConvertFrom-Json
                                $secretsDetail.aws_key_count = ($provisioning.PSObject.Properties.Name | Measure-Object).Count
                                $matching = 0; $differing = 0
                                foreach ($k in $currentBundle.Keys) { $awsVal = $provisioning.$k; if ($null -ne $awsVal) { if ("$($currentBundle[$k])" -eq "$awsVal") { $matching++ } else { $differing++ } } }
                                $secretsDetail.matching_keys = $matching; $secretsDetail.differing_keys = $differing; $secretsDetail.keys_match = ($differing -eq 0); $secretsDetail.values_match = ($differing -eq 0); $secretsStale = ($differing -gt 0); $secretsDetail.status = "compared"
                            } else { $secretsDetail.status = "aws_unreachable"; if ($awsErr) { $secretsDetail.error = $awsErr.Trim() } }
                        } else { $secretsDetail.status = "no_aws_creds_in_bundle" }
                    } else { $secretsDetail.status = "bundle_not_found" }
                } else { $secretsDetail.status = "no_running_task" }
            } catch { $secretsDetail.status = "error"; $secretsDetail.error = $_.Exception.Message }
            $resultObj.secrets_stale = $secretsStale; $resultObj.secrets_detail = $secretsDetail
            if ($deployCommit) {
                $bundleManifestPath = "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1"
                $deployContent = Invoke-LocalCommand { git show "${deployCommit}:$bundleManifestPath" 2>&1 }
                $repoDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { '/workspace/repo' }
                $headContent = if (Test-Path "$repoDir/$bundleManifestPath") { Get-Content "$repoDir/$bundleManifestPath" -Raw } else { $null }
                if ($deployContent.Success -and $deployContent.Output -and $headContent) {
                    $deployBundles = @{}; $headBundles = @{}
                    $bundlePattern = '(?s)(\w+)\s*=\s*@\{[^}]*SourceKeys\s*=\s*@\(([^)]*)\)'
                    foreach ($m in [regex]::Matches("$($deployContent.Output)", $bundlePattern)) { $deployBundles[$m.Groups[1].Value] = $m.Groups[2].Value }
                    foreach ($m in [regex]::Matches("$headContent", $bundlePattern)) { $headBundles[$m.Groups[1].Value] = $m.Groups[2].Value }
                    $patternChanged = $false; $patternDetail = @{}
                    foreach ($bn in @($deployBundles.Keys) + @($headBundles.Keys) | Select-Object -Unique) {
                        $oldKeys = if ($deployBundles[$bn]) { @([regex]::Matches($deployBundles[$bn], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
                        $newKeys = if ($headBundles[$bn]) { @([regex]::Matches($headBundles[$bn], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
                        $added = @($newKeys | Where-Object { $_ -notin $oldKeys }); $removed = @($oldKeys | Where-Object { $_ -notin $newKeys })
                        if ($added.Count -gt 0 -or $removed.Count -gt 0) { $patternChanged = $true }
                        $patternDetail[$bn] = @{ added = @($added); removed = @($removed); unchanged = @($oldKeys | Where-Object { $_ -in $newKeys }).Count }
                    }
                    $resultObj.pattern_changed = $patternChanged; $resultObj.pattern_detail = $patternDetail
                } else { $resultObj.pattern_changed = $null; $resultObj.pattern_detail = @{ status = "could_not_compare" } }
            } else { $resultObj.pattern_changed = $null; $resultObj.pattern_detail = @{ status = "no_deploy_commit_provided" } }
        } catch { $resultObj.code_stale = $true; $resultObj.secrets_stale = $true; $resultObj.pattern_changed = $null; $resultObj.error = $_.Exception.Message }
        $results += $resultObj
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Get-ToolSpecs {
    return @(
        @{ name = "health"; description = "Liveness check"; method = "GET"; path = "/health"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "ready"; description = "Readiness probe"; method = "GET"; path = "/ready"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "log"; description = "Log ingestion"; method = "POST"; path = "/log"; inputSchema = @{ type = "object"; properties = @{ level = @{ type = "string" }; source = @{ type = "string" }; message = @{ type = "string" } }; required = @("message") } }
        @{ name = "fleet_deploy"; description = "Run fleet deploy"; method = "POST"; path = "/api/deploy/execute"; inputSchema = @{ type = "object"; properties = @{ whatIf = @{ type = "boolean" } }; required = @() } }
        @{ name = "audit_state"; description = "Current audit cycle state"; method = "GET"; path = "/api/audit/state"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "fleet_services"; description = "Fleet service status"; method = "GET"; path = "/api/fleet/services"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "fleet_service_update"; description = "Force restart specific services"; method = "POST"; path = "/api/deploy/service-update"; inputSchema = @{ type = "object"; properties = @{ services = @{ type = "array"; items = @{ type = "string" }; description = "Service names without stack prefix" }; all = @{ type = "boolean"; description = "Update all services" } }; required = @() } }
        @{ name = "fleet_service_redeploy"; description = "Redeploy service with new image"; method = "POST"; path = "/api/deploy/service-redeploy"; inputSchema = @{ type = "object"; properties = @{ services = @{ type = "array"; items = @{ type = "object"; properties = @{ name = @{ type = "string" }; image = @{ type = "string" } }; required = @("name") } } }; required = @("services") } }
        @{ name = "fleet_service_scale"; description = "Scale services up or down"; method = "POST"; path = "/api/deploy/scale"; inputSchema = @{ type = "object"; properties = @{ services = @{ type = "array"; items = @{ type = "object"; properties = @{ name = @{ type = "string" }; replicas = @{ type = "integer" } }; required = @("name", "replicas") } } }; required = @("services") } }
        @{ name = "fleet_service_logs"; description = "Fetch service logs"; method = "GET"; path = "/api/fleet/logs"; inputSchema = @{ type = "object"; properties = @{ service = @{ type = "string" }; tail = @{ type = "integer" }; follow = @{ type = "boolean" } }; required = @("service") } }
        @{ name = "fleet_service_status"; description = "Detailed service info"; method = "GET"; path = "/api/fleet/service-status"; inputSchema = @{ type = "object"; properties = @{ service = @{ type = "string" } }; required = @("service") } }
        @{ name = "fleet_redeploy_containers"; description = "Redeploy a set of containers by name"; method = "POST"; path = "/api/deploy/redeploy-containers"; inputSchema = @{ type = "object"; properties = @{ containers = @{ type = "array"; items = @{ type = "string" }; description = "Service names to redeploy (without stack prefix)" }; all = @{ type = "boolean"; description = "Redeploy all services" } }; required = @() } }
        @{ name = "secret_rotate"; description = "Rotate a single secret key in a target container's bundle"; method = "POST"; path = "/api/secret/rotate"; inputSchema = @{ type = "object"; properties = @{ container = @{ type = "string" }; key = @{ type = "string" }; value = @{ type = "string" } }; required = @("container", "key", "value") } }
        @{ name = "secret_rotate_containers"; description = "Rotate the same secret key across multiple containers"; method = "POST"; path = "/api/secret/rotate-containers"; inputSchema = @{ type = "object"; properties = @{ containers = @{ type = "array"; items = @{ type = "string" }; description = "Service names to rotate" }; key = @{ type = "string" }; value = @{ type = "string" } }; required = @("containers", "key", "value") } }
        @{ name = "secret_refresh_self"; description = "Refresh the fleet's own secrets bundle from AWS SM"; method = "POST"; path = "/api/secret/refresh-self"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "secret_check_freshness"; description = "Check secret bundle freshness against AWS SM for specified containers"; method = "POST"; path = "/api/secret/check-freshness"; inputSchema = @{ type = "object"; properties = @{ containers = @{ type = "array"; items = @{ type = "string" }; description = "Service names to check" } }; required = @("containers") } }
        @{ name = "secret_refresh_containers"; description = "Refresh secret bundle for specified containers from AWS SM"; method = "POST"; path = "/api/secret/refresh-containers"; inputSchema = @{ type = "object"; properties = @{ containers = @{ type = "array"; items = @{ type = "string" }; description = "Service names to refresh" } }; required = @("containers") } }
        @{ name = "fleet_check_staleness"; description = "Check code, secret, and pattern staleness for specified containers"; method = "POST"; path = "/api/deploy/check-staleness"; inputSchema = @{ type = "object"; properties = @{ containers = @{ type = "array"; items = @{ type = "string" }; description = "Service names to check" }; all = @{ type = "boolean" }; expected_hashes = @{ type = "object" }; deploy_git_commit = @{ type = "string" } }; required = @() } }
        @{ name = "fleet_self_update"; description = "Trigger fleet container self-restart via docker service update --force"; method = "POST"; path = "/api/deploy/fleet-self-update"; inputSchema = @{ type = "object"; properties = @{}; required = @() } }
        @{ name = "git_exec"; description = "Execute git commands on managed repos (status/pull/commit-push)"; method = "POST"; path = "/api/git/exec"; inputSchema = @{ type = "object"; properties = @{ repo = @{ type = "string"; description = "Repo name (e.g. intersite-docs)" }; command = @{ type = "string"; description = "Command: status, pull, or commit-push" }; commit_message = @{ type = "string" }; author_name = @{ type = "string" }; author_email = @{ type = "string" }; files = @{ type = "array"; items = @{ type = "string" } } }; required = @("repo", "command") } }
    )
}

function Invoke-FleetSelfUpdate {
    param($Request, $Response)
    try {
        $stackName = Resolve-StackName
        if (-not $stackName) { $stackName = $env:INSTALL_PROJECT }
        $fleetServiceName = "${stackName}_is-fleet"
        $result = Invoke-LocalCommand { docker service inspect $fleetServiceName --format "{{.Spec.Name}}" 2>&1 }
        if (-not $result.Success) { return @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "fleet service not found: ${fleetServiceName}" }; ContentType = "application/json" } }
        Invoke-LocalCommand { docker service update --force $fleetServiceName 2>&1 }
        return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "restart_initiated"; service = $fleetServiceName }; ContentType = "application/json" }
    } catch { return @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "self-update failed: $($_.Exception.Message)" }; ContentType = "application/json" } }
}

function Invoke-ServiceUpdate {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $stackName = Resolve-StackName
    $serviceList = @()
    if ($Payload.all -eq $true) { $result = Invoke-LocalCommand { docker service ls --filter "label=com.docker.stack.namespace=${stackName}" --format "{{.Name}}" 2>&1 }; if ($result.Success) { $allServices = @($result.Output); $serviceList = $allServices | Where-Object { $_ -ne "${stackName}_is-fleet" -and $restartAllowedServices -contains ($_ -replace "^${stackName}_", "") } } }
    elseif ($Payload.services -is [array]) { $serviceList = $Payload.services | ForEach-Object { if ($_ -match "^${stackName}_") { $_ } else { "${stackName}_$_" } } }
    $results = @()
    foreach ($svc in $serviceList) {
        $svcName = $svc -replace "^${stackName}_", ""
        if (-not (Test-ContainerName -Name $svcName)) { Write-Warning "Invoke-ServiceUpdate: invalid container name rejected: '$svcName'"; $results += @{ service = $svcName; status = "invalid_name" }; continue }
        if (-not (Test-ServiceRestartAllowed -Name $svcName)) { Write-Warning "Invoke-ServiceUpdate: service '$svcName' is not in the restart whitelist"; $results += @{ service = $svcName; status = "not_allowed" }; continue }
        $r = Invoke-LocalCommand { docker service update --force "$svc" 2>&1 }
        $results += @{ service = $svcName; exitCode = $r.ExitCode; output = "$($r.Output)" }
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Invoke-ServiceRedeploy {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $stackName = Resolve-StackName
    $results = @()
    foreach ($entry in $Payload.services) {
        $svcName = $entry.name
        if (-not (Test-ContainerName -Name $svcName)) { Write-Warning "Invoke-ServiceRedeploy: invalid container name rejected: '$svcName'"; $results += @{ service = $svcName; status = "invalid_name" }; continue }
        if (-not (Test-ServiceRestartAllowed -Name $svcName)) { Write-Warning "Invoke-ServiceRedeploy: service '$svcName' is not in the restart whitelist"; $results += @{ service = $svcName; status = "not_allowed" }; continue }
        $fullName = if ($svcName -match "^${stackName}_") { $svcName } else { "${stackName}_${svcName}" }
        $img = $entry.image
        $r = if ($img) { Invoke-LocalCommand { docker service update --image "$img" --force "$fullName" 2>&1 } } else { Invoke-LocalCommand { docker service update --force "$fullName" 2>&1 } }
        $results += @{ service = $svcName; exitCode = $r.ExitCode; image = $img; output = "$($r.Output)" }
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Invoke-ServiceScale {
    param($Request, $Response)
    $bodyResult = Invoke-ReadBody $Request
    if (-not $bodyResult.Success) { return $bodyResult }
    $Payload = $bodyResult.Payload
    $stackName = Resolve-StackName
    $results = @()
    foreach ($entry in $Payload.services) {
        $svcName = $entry.name
        if (-not (Test-ContainerName -Name $svcName)) { Write-Warning "Invoke-ServiceScale: invalid container name rejected: '$svcName'"; $results += @{ service = $svcName; status = "invalid_name" }; continue }
        if (-not (Test-ServiceRestartAllowed -Name $svcName)) { Write-Warning "Invoke-ServiceScale: service '$svcName' is not in the restart whitelist"; $results += @{ service = $svcName; status = "not_allowed" }; continue }
        $fullName = if ($svcName -match "^${stackName}_") { $svcName } else { "${stackName}_${svcName}" }
        $r = Invoke-LocalCommand { docker service scale "${fullName}=$($entry.replicas)" 2>&1 }
        $results += @{ service = $svcName; replicas = $entry.replicas; exitCode = $r.ExitCode; output = "$($r.Output)" }
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
}

function Invoke-ServiceLogs {
    param($Request, $Response)
    $svcName = $Request.QueryString["service"]
    if (-not $svcName) { return @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "MISSING_PARAM"; message = "service query parameter is required" } } }
    $stackName = Resolve-StackName
    $fullName = if ($svcName -match "^${stackName}_") { $svcName } else { "${stackName}_${svcName}" }
    $tail = $Request.QueryString["tail"]; if (-not $tail) { $tail = "100" }
    $containerResult = Invoke-LocalCommand { docker ps --filter "name=${fullName}" --format "{{.ID}}" 2>&1 }
    $containerId = @($containerResult.Output)[0]
    if (-not $containerId) { return @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "SERVICE_NOT_FOUND"; message = "No running container for ${svcName}" } } }
    $logResult = Invoke-LocalCommand { docker logs --tail "$tail" "$containerId" 2>&1 }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ service = $svcName; container = $containerId; logs = Protect-Secrets "$($logResult.Output)"; truncated = $false }; ContentType = "application/json" }
}

function Invoke-ServiceStatus {
    param($Request, $Response)
    $svcName = $Request.QueryString["service"]
    if (-not $svcName) { return @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "MISSING_PARAM"; message = "service query parameter is required" } } }
    $stackName = Resolve-StackName
    $allServices = @()
    if ($svcName -eq "all") { $lsResult = Invoke-LocalCommand { docker service ls --filter "label=com.docker.stack.namespace=${stackName}" --format "{{.Name}}" 2>&1 }; $allServices = @($lsResult.Output) }
    else { $fullName = if ($svcName -match "^${stackName}_") { $svcName } else { "${stackName}_${svcName}" }; $allServices = @($fullName) }
    $services = @()
    foreach ($fullName in $allServices) {
        $inspectResult = Invoke-LocalCommand { docker service inspect "$fullName" --format '{{json .}}' 2>&1 }
        $svcInfo = if ($inspectResult.Success) { try { $inspectResult.Output | ConvertFrom-Json } catch { Write-Warning "Invoke-ServiceStatus: failed to parse service inspect output: $_"; $null } } else { $null }
        if (-not $svcInfo) { continue }
        $shortName = $fullName -replace "^${stackName}_", ""
        $ports = @(); if ($svcInfo.Endpoint -and $svcInfo.Endpoint.Ports) { $ports = @($svcInfo.Endpoint.Ports | ForEach-Object { "$($_.PublishedPort)" }) }
        $desired = $null; $running = 0
        if ($svcInfo.Spec.Mode.Replicated) { $desired = $svcInfo.Spec.Mode.Replicated.Replicas }
        $containersResult = Invoke-LocalCommand { docker service ps "$fullName" --format '{{json .}}' 2>&1 }
        $containers = @()
        if ($containersResult.Success) {
            foreach ($line in @($containersResult.Output)) { $c = try { $line | ConvertFrom-Json } catch { Write-Warning "Invoke-ServiceStatus: failed to parse container JSON: $_"; $null }; if ($c) { $containers += @{ id = $c.ID; status = $c.CurrentState; uptime = 0 }; if ($c.CurrentState -eq "running") { $running++ } } }
        }
        $services += @{ name = $shortName; image = if ($svcInfo.Spec.TaskTemplate.ContainerSpec.Image) { $svcInfo.Spec.TaskTemplate.ContainerSpec.Image } else { "" }; replicas = @{ desired = $desired; running = $running }; ports = $ports; update_status = if ($svcInfo.UpdateStatus) { @{ state = $svcInfo.UpdateStatus.State; started_at = $svcInfo.UpdateStatus.StartedAt } } else { $null }; health = @{ status = "unknown"; failing_streak = 0 }; containers = $containers }
    }
    return @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ services = $services }; ContentType = "application/json" }
}

function Invoke-HealthRouteDispatch {
    param($Path, $Method, $Request, $Response)
    switch ($Path) {
        "/health" { Invoke-Health $Request $Response }
        "/api/health" { Invoke-Health $Request $Response }
        "/ready" { Invoke-Ready $Request $Response }
        "/api/ready" { Invoke-Ready $Request $Response }
        "/api/credentials" { @{ StatusCode = 200; Buffer = Get-BodyBuffer @{}; ContentType = "application/json" } }
        "/api/routes" {
            $routes = @(
                @{ method = "GET"; path = "/api/health"; description = "Liveness check" }
                @{ method = "GET"; path = "/api/ready"; description = "Readiness probe" }
                @{ method = "GET"; path = "/api/credentials"; description = "Credential validity (none)" }
                @{ method = "GET"; path = "/api/routes"; description = "Route discovery" }
                @{ method = "GET"; path = "/api/version"; description = "Version info" }
                @{ method = "POST"; path = "/log"; description = "Log ingestion" }
                @{ method = "POST"; path = "/update-state"; description = "Update fleet state" }
                @{ method = "POST"; path = "/api/deploy/dry-run"; description = "Validate compose without deploying" }
                @{ method = "POST"; path = "/api/deploy/execute"; description = "Run deploy (fleet excluded)" }
                @{ method = "POST"; path = "/api/deploy/service-update"; description = "Force restart specific services" }
                @{ method = "POST"; path = "/api/deploy/service-redeploy"; description = "Redeploy service with new image" }
                @{ method = "POST"; path = "/api/deploy/scale"; description = "Scale services up or down" }
                @{ method = "POST"; path = "/api/deploy/redeploy-containers"; description = "Redeploy a set of containers by name" }
                @{ method = "POST"; path = "/api/deploy/check-staleness"; description = "Check code and secret staleness for specified containers" }
                @{ method = "POST"; path = "/api/deploy/fleet-self-update"; description = "Trigger fleet container self-restart" }
                @{ method = "POST"; path = "/api/secret/rotate"; description = "Rotate a secret key in a target container bundle" }
                @{ method = "POST"; path = "/api/secret/rotate-containers"; description = "Rotate secrets for a set of containers" }
                @{ method = "POST"; path = "/api/secret/refresh-self"; description = "Refresh fleet's own secrets bundle from AWS SM" }
                @{ method = "POST"; path = "/api/secret/check-freshness"; description = "Check secret bundle freshness against AWS SM" }
                @{ method = "POST"; path = "/api/secret/refresh-containers"; description = "Refresh secret bundle for specified containers from AWS SM" }
                @{ method = "GET"; path = "/api/fleet/logs"; description = "Fetch service logs" }
                @{ method = "GET"; path = "/api/fleet/service-status"; description = "Detailed service info" }
                @{ method = "GET"; path = "/api/audit/state"; description = "Current audit cycle state" }
                @{ method = "GET"; path = "/api/fleet/services"; description = "Fleet service status" }
                @{ method = "POST"; path = "/api/git/exec"; description = "Execute git commands (status/pull/commit-push) on managed repos" }
            )
            @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ routes = $routes }; ContentType = "application/json" }
        }
        "/tools/list" { @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ tools = Get-ToolSpecs }; ContentType = "application/json" } }
        "/api/version" { @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ name = "is-fleet"; version = "1.0.0"; built = "2026-06-10T06:00:00Z" }; ContentType = "application/json" } }
        "/update-state" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-UpdateState $Request $Response } }
        "/log" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-Log $Request $Response } }
        "/api/deploy/dry-run" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $runDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { "/workspace/repo" }; $deployScript = Join-Path $runDir "Skills" "Docker" "deploy.ps1"
                try { $prevPreserve = $env:INTERCLAW_PRESERVE_FLEET; $env:INTERCLAW_PRESERVE_FLEET = "true"; $result = Invoke-LocalCommand { & $deployScript -DroneMode -WhatIf -PreserveFleet 2>&1 }; @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ exitCode = $result.ExitCode; output = $result.Output }; ContentType = "application/json" } }
                catch { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "$($_.Exception.Message)" }; ContentType = "application/json" } }
                finally { $env:INTERCLAW_PRESERVE_FLEET = $prevPreserve }
            }
        }
        "/api/deploy/execute" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $runDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { "/workspace/repo" }; $deployScript = Join-Path $runDir "Skills" "Docker" "deploy.ps1"
                try { $prevPreserve = $env:INTERCLAW_PRESERVE_FLEET; $env:INTERCLAW_PRESERVE_FLEET = "true"; $result = Invoke-LocalCommand { & $deployScript -DroneMode -PreserveFleet 2>&1 }; @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ exitCode = $result.ExitCode; output = $result.Output }; ContentType = "application/json" } }
                catch { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "$($_.Exception.Message)" }; ContentType = "application/json" } }
                finally { $env:INTERCLAW_PRESERVE_FLEET = $prevPreserve }
            }
        }
        "/api/deploy/redeploy-containers" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyResult = Invoke-ReadBody $Request
                if (-not $bodyResult.Success) { return $bodyResult }
                $Payload = $bodyResult.Payload; $stackName = Resolve-StackName; $serviceList = @()
                if ($Payload.all -eq $true) { $result = Invoke-LocalCommand { docker service ls --filter "label=com.docker.stack.namespace=${stackName}" --format "{{.Name}}" 2>&1 }; $serviceList = @($result.Output) | Where-Object { $_ -ne "${stackName}_is-fleet" -and $restartAllowedServices -contains ($_ -replace "^${stackName}_", "") } }
                elseif ($Payload.containers -is [array]) { $serviceList = $Payload.containers | ForEach-Object { if ($_ -match "^${stackName}_") { $_ } else { "${stackName}_$_" } } }
                $results = @()
                foreach ($svc in $serviceList) {
                    $svcName = $svc -replace "^${stackName}_", ""
                    if (-not (Test-ContainerName -Name $svcName)) { Write-Warning "Invoke-RedeployContainers: invalid container name rejected: '$svcName'"; $results += @{ container = $svcName; status = "invalid_name" }; continue }
                    if (-not (Test-ServiceRestartAllowed -Name $svcName)) { Write-Warning "Invoke-RedeployContainers: service '$svcName' is not in the restart whitelist"; $results += @{ container = $svcName; status = "not_allowed" }; continue }
                    $r = Invoke-LocalCommand { docker service update --force "$svc" 2>&1 }; $results += @{ container = $svcName; exitCode = $r.ExitCode; output = "$($r.Output)" }
                }
                @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
            }
        }
        "/api/deploy/check-staleness" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-CheckStaleness $Request $Response } }
        "/api/deploy/fleet-self-update" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-FleetSelfUpdate $Request $Response } }
        "/api/secret/rotate" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyResult = Invoke-ReadBody $Request
                if (-not $bodyResult.Success) { return $bodyResult }
                $Payload = $bodyResult.Payload; $container = $Payload.container; $key = $Payload.key; $value = $Payload.value
                if (-not $container -or -not $key -or -not $value) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required fields: container, key, value" } } }
                elseif (-not (Test-ContainerName -Name $container)) { Write-Warning "Invoke-SecretRotate: invalid container name rejected: '$container'"; @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "invalid container name" } } }
                else {
                    try {
                        $stackName = Resolve-StackName; $serviceName = "${stackName}_${container}"
# Safe probe: docker service ps returns empty (exit 0) when no running task exists; absence is handled by the caller as a valid state.
                        $taskContainer = docker service ps $serviceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null | Select-Object -First 1
                        if (-not $taskContainer) { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "no running task for ${serviceName}" } } }
                        else {
                            $bundleJson = Invoke-FleetDockerExec -ContainerName $($taskContainer.Trim()) -Command "cat /run/secrets/secrets_bundle"
                            if ($LASTEXITCODE -ne 0 -or -not $bundleJson) { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "could not read secrets_bundle from ${taskContainer}" } } }
                            else {
                                $currentBundle = $bundleJson | ConvertFrom-Json -AsHashtable; $currentBundle[$key] = $value; $newJson = $currentBundle | ConvertTo-Json -Compress
                                $tempName = "${stackName}_secrets_bundle_rotating"
                                $null = $newJson | docker secret create "$tempName" - 2>$null
                                if ($LASTEXITCODE -eq 0) {
                                    $null = docker service update --detach=true --secret-rm="${stackName}_secrets_bundle" --secret-add="source=$tempName,target=secrets_bundle" $serviceName 2>$null
                                    if ($LASTEXITCODE -ne 0) { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to swap service to temp secret" }; ContentType = "application/json" } }
                                    else {
                                        # Safe discard: removing the previous bundle secret is best-effort; the re-create below is the gate.
                                        $null = docker secret rm "${stackName}_secrets_bundle" 2>$null
                                        $null = $newJson | docker secret create "${stackName}_secrets_bundle" - 2>$null
                                        if ($LASTEXITCODE -ne 0) { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to re-create bundle secret" }; ContentType = "application/json" } }
                                        else {
                                            $null = docker service update --detach=true --secret-rm="$tempName" --secret-add="source=${stackName}_secrets_bundle,target=secrets_bundle" $serviceName 2>$null
                                            # Safe discard: removing the temp secret after successful rotation is best-effort cleanup.
                                            $null = docker secret rm "$tempName" 2>$null
                                            @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ status = "rotated"; container = $container; key = $key }; ContentType = "application/json" }
                                        }
                                    }
                                } else { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "failed to create rotation secret" }; ContentType = "application/json" } }
                            }
                        }
                    } catch { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "rotation failed: $($_.Exception.Message)" }; ContentType = "application/json" } }
                }
            }
        }
        "/api/secret/rotate-containers" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyResult = Invoke-ReadBody $Request
                if (-not $bodyResult.Success) { return $bodyResult }
                $Payload = $bodyResult.Payload; $containers = $Payload.containers; $key = $Payload.key; $value = $Payload.value
                if (-not $containers -or -not $key -or -not $value) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "missing required fields: containers, key, value" } } }
                else {
                    $results = @(); $stackName = Resolve-StackName
                    foreach ($container in $containers) {
                        if (-not (Test-ContainerName -Name $container)) { Write-Warning "Invoke-SecretRotateContainers: invalid container name rejected: '$container'"; $results += @{ container = $container; status = "invalid_name" }; continue }
                        try {
                            $serviceName = "${stackName}_${container}"
# Safe probe: docker service ps returns empty (exit 0) when no running task exists; absence is handled by the caller as a valid state.
                            $taskContainer = docker service ps $serviceName --format "{{.Name}}.{{.ID}}" --filter "desired-state=running" 2>$null | Select-Object -First 1
                            if ($taskContainer) {
                                $bundleJson = Invoke-FleetDockerExec -ContainerName $($taskContainer.Trim()) -Command "cat /run/secrets/secrets_bundle"
                                if ($LASTEXITCODE -eq 0 -and $bundleJson) {
                                    $currentBundle = $bundleJson | ConvertFrom-Json -AsHashtable; $currentBundle[$key] = $value; $newJson = $currentBundle | ConvertTo-Json -Compress
                                    $tempName = "${stackName}_secrets_bundle_rotating"
                                    $null = $newJson | docker secret create "$tempName" - 2>$null
                                    if ($LASTEXITCODE -eq 0) {
                                        $null = docker service update --detach=true --secret-rm="${stackName}_secrets_bundle" --secret-add="source=$tempName,target=secrets_bundle" $serviceName 2>$null
                                        # Safe discard: removing the previous bundle secret is best-effort; the re-create below is the gate.
                                        $null = docker secret rm "${stackName}_secrets_bundle" 2>$null
                                        $null = $newJson | docker secret create "${stackName}_secrets_bundle" - 2>$null
                                        $null = docker service update --detach=true --secret-rm="$tempName" --secret-add="source=${stackName}_secrets_bundle,target=secrets_bundle" $serviceName 2>$null
                                        # Safe discard: removing the temp secret after successful rotation is best-effort cleanup.
                                        $null = docker secret rm "$tempName" 2>$null
                                        $results += @{ container = $container; status = "rotated" }
                                    } else { $results += @{ container = $container; status = "failed"; error = "could not create temp secret" } }
                                } else { $results += @{ container = $container; status = "failed"; error = "could not read bundle" } }
                            } else { $results += @{ container = $container; status = "failed"; error = "no running task" } }
                        } catch { $results += @{ container = $container; status = "failed"; error = $_.Exception.Message } }
                    }
                    @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ results = $results }; ContentType = "application/json" }
                }
            }
        }
        "/api/secret/refresh-self" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-SecretRefreshSelf $Request $Response } }
        "/api/secret/check-freshness" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-SecretCheckFreshness $Request $Response } }
        "/api/secret/refresh-containers" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-RefreshContainers $Request $Response } }
        "/api/audit/state" {
            $statePath = Join-Path (if ($env:REPO_DIR) { $env:REPO_DIR } else { "/workspace/repo" }) "Tasks" "Logs" "audit-cycle-state.json"
            $state = if (Test-Path $statePath) { try { Get-Content $statePath -Raw | ConvertFrom-Json } catch { Write-Warning "Invoke-HealthRouteDispatch: failed to parse audit state JSON: $_"; $null } } else { $null }
            @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ state = $state }; ContentType = "application/json" }
        }
        "/api/git/exec" {
            if ($Method -ne "POST") { Deny-Method "POST" }
            else {
                $bodyJson = Read-JsonBody $Request
                if (-not $bodyJson) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "BAD_REQUEST"; message = "Request body is required" } } }
                else {
                    $repo = $bodyJson.repo; $command = $bodyJson.command
                    if (-not $repo) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "BAD_REQUEST"; message = "repo is required" } } }
                    elseif (-not $command) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "BAD_REQUEST"; message = "command is required" } } }
                    else {
                        try { $repoPath = Resolve-GitRepoPath -RepoName $repo } catch { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "UNKNOWN_REPO"; message = "Unknown repo: $repo" } }; continue }
                        $commitMsg = if ($bodyJson.commit_message) { $bodyJson.commit_message } else { "Update from git-exec" }
                        $authorName = if ($bodyJson.author_name) { $bodyJson.author_name } else { "Fleet Git Exec" }
                        $authorEmail = if ($bodyJson.author_email) { $bodyJson.author_email } else { "fleet@intersite.io" }
                        $injectionPattern = '[\r\n;|&`$(){}[\]!#~<>]'
                        if ($commitMsg -match $injectionPattern) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "INVALID_PARAMETER"; message = "commit_message contains invalid characters" } } }
                        elseif ($authorName -match $injectionPattern) { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "INVALID_PARAMETER"; message = "author_name contains invalid characters" } } }
                        elseif ($authorEmail -match '[<>;|&`$(){}[\]!#~\s]') { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "INVALID_PARAMETER"; message = "author_email contains invalid characters" } } }
                        else {
                            try {
                                switch ($command) {
                                    'status' { $output = Invoke-GitStatus -RepoPath $repoPath; @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ output = $output; repo = $repoPath } } }
                                    'pull' { $output = Invoke-GitPull -RepoPath $repoPath; @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ output = $output; repo = $repoPath } } }
                                    'commit-push' { $files = if ($bodyJson.files -and $bodyJson.files.Count -gt 0) { $bodyJson.files } else { @() }; $result = Invoke-GitCommitPush -RepoPath $repoPath -CommitMessage $commitMsg -AuthorName $authorName -AuthorEmail $authorEmail -Files $files; @{ StatusCode = 200; Buffer = Get-BodyBuffer $result } }
                                    default { @{ StatusCode = 400; Buffer = Get-BodyBuffer @{ error = "UNKNOWN_COMMAND"; message = "Unknown command: $command. Supported: status, pull, commit-push" } } }
                                }
                            } catch { Write-Warning "Git exec failed ($repo / $command): $_"; @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "GIT_ERROR"; message = "Git operation failed: $_" } } }
                        }
                    }
                }
            }
        }
        "/api/fleet/services" {
            try { $stackName = if ($CurrentState.StackName) { $CurrentState.StackName } else { $env:INSTALL_PROJECT }; $result = Invoke-LocalCommand { docker stack ps "${stackName}" --format '{{json .}}' 2>&1 }; $services = if ($result.Success) { $result.Output | ConvertFrom-Json } else { @() }; @{ StatusCode = 200; Buffer = Get-BodyBuffer @{ services = $services }; ContentType = "application/json" } }
            catch { @{ StatusCode = 500; Buffer = Get-BodyBuffer @{ error = "$($_.Exception.Message)" }; ContentType = "application/json" } }
        }
        "/api/deploy/service-update" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-ServiceUpdate $Request $Response } }
        "/api/deploy/service-redeploy" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-ServiceRedeploy $Request $Response } }
        "/api/deploy/scale" { if ($Method -ne "POST") { Deny-Method "POST" } else { Invoke-ServiceScale $Request $Response } }
        "/api/fleet/logs" { Invoke-ServiceLogs $Request $Response }
        "/api/fleet/service-status" { Invoke-ServiceStatus $Request $Response }
        default { @{ StatusCode = 404; Buffer = Get-BodyBuffer @{ error = "NOT_FOUND"; message = "not found" } } }
    }
}

function Invoke-HealthListenerLoop {
    param([string]$Prefix)
    $fleetMonitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $fleetApiToken = Get-Content "/run/secrets/fleet_api_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if ([string]::IsNullOrWhiteSpace($fleetApiToken) -and [string]::IsNullOrWhiteSpace($fleetMonitorToken)) {
        $msg = "FATAL: Both fleet_monitor_token and fleet_api_token are empty or unreadable — listener would start with auth bypass. Exiting."
        Add-Content -Path (Join-Path "/workspace/logs" "$(Get-Date -Format 'yyyy-MM-dd').log") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [FATAL] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Error $msg; return @{ Error = $msg }
    }
    if ([string]::IsNullOrWhiteSpace($fleetApiToken)) { Write-Warning "fleet_api_token is empty — write endpoints will reject all requests" }
    if ([string]::IsNullOrWhiteSpace($fleetMonitorToken)) { Write-Warning "fleet_monitor_token is empty — read endpoints will reject all requests" }
    $Listener = [System.Net.HttpListener]::new()
    $Listener.Prefixes.Add($Prefix)
    try { $Listener.Start() } catch { return @{ Error = $_.Exception.Message } }
    $writeRoutes = @('/api/deploy/execute', '/api/deploy/service-update', '/api/deploy/service-redeploy', '/api/deploy/scale', '/api/deploy/redeploy-containers', '/api/deploy/fleet-self-update', '/api/secret/rotate', '/api/secret/rotate-containers', '/api/secret/refresh-self', '/api/secret/refresh-containers', '/api/git/exec')
    try {
        while ($Listener.IsListening) {
            $Context = $Listener.GetContext()
            $Request = $Context.Request; $Response = $Context.Response
            $RemoteIp = $Request.RemoteEndPoint.Address.ToString()
            $IsInternal = $RemoteIp -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|::1|fc00:)"
            $Request | Add-Member -NotePropertyName IsInternal -NotePropertyValue $IsInternal -Force
            $Path = $Request.Url.AbsolutePath; $Method = $Request.HttpMethod
            $isWriteRoute = $writeRoutes -contains $Path
            Add-CorsHeaders $Response
            if ($Method -eq 'OPTIONS') { $Response.StatusCode = 204; $Response.Close(); continue }
            $logStart = [DateTime]::UtcNow
            $clientKey = $Request.Headers['Authorization']
            if (-not $clientKey) { $clientKey = $RemoteIp }
            if (-not $script:RateLimiter.IsAllowed($clientKey)) {
                $Response.StatusCode = 429; $Response.ContentType = 'application/json'
                $retryAfter = $script:RateLimiter.CooldownSec
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error":"rate_limit_exceeded","retry_after":' + $retryAfter + '}'))
                $Response.Headers.Add('Retry-After', "$retryAfter")
                $Response.OutputStream.Write($bytes, 0, $bytes.Length); $Response.Close(); continue
            }
            if ($Path -ne '/health' -and $Path -ne '/api/health') {
                if (-not $fleetMonitorToken -and -not $fleetApiToken) {
                    $Response.StatusCode = 403; $Response.ContentType = 'application/json'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"forbidden - no token configured"}')
                    $Response.OutputStream.Write($bytes, 0, $bytes.Length); $Response.Close(); continue
                }
                $authHeader = $Request.Headers['Authorization']; $valid = $false; $isMonitor = $false
                if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') {
                    $token = $Matches[1]; $tokenBytes = [System.Text.Encoding]::UTF8.GetBytes($token)
                    if ($fleetApiToken) { $apiBytes = [System.Text.Encoding]::UTF8.GetBytes($fleetApiToken); if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($tokenBytes, $apiBytes)) { $valid = $true } }
                    if (-not $valid -and $fleetMonitorToken) { $monitorBytes = [System.Text.Encoding]::UTF8.GetBytes($fleetMonitorToken); if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($tokenBytes, $monitorBytes)) { $valid = $true; $isMonitor = $true } }
                }
                if (-not $valid) {
                    $Response.StatusCode = 403; $Response.ContentType = 'application/json'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"forbidden"}')
                    $Response.OutputStream.Write($bytes, 0, $bytes.Length); $Response.Close(); continue
                }
                if ($isMonitor -and $isWriteRoute) {
                    $logMsg = "[AUDIT] Monitor token rejected on write endpoint: $Method $Path from $RemoteIp"
                    Add-Content -Path (Join-Path "/workspace/logs" "$(Get-Date -Format 'yyyy-MM-dd').log") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $logMsg" -Encoding UTF8 -ErrorAction SilentlyContinue
                    $Response.StatusCode = 403; $Response.ContentType = 'application/json'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"forbidden - monitor token cannot perform write operations"}')
                    $Response.OutputStream.Write($bytes, 0, $bytes.Length); $Response.Close(); continue
                }
            }
            $Result = Invoke-HealthRouteDispatch -Path $Path -Method $Method -Request $Request -Response $Response
            $Buffer = if ($Result.Buffer) { $Result.Buffer } else { [System.Text.Encoding]::UTF8.GetBytes('{}') }
            $Response.StatusCode = if ($Result.StatusCode) { $Result.StatusCode } else { 200 }
            if ($Result.ContentType) { $Response.ContentType = $Result.ContentType }
            $Response.ContentLength64 = $Buffer.Length; $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            $finalStatusCode = $Response.StatusCode; $Response.Close()
            $logDuration = [math]::Round((([DateTime]::UtcNow) - $logStart).TotalMilliseconds, 0)
            Write-Verbose (ConvertTo-Json @{ event = "api_request"; method = $Method; path = $Path; status = $finalStatusCode; durationMs = $logDuration } -Compress)
            if ($finalStatusCode -ge 500) { $script:RateLimiter.RecordError($clientKey) }
        }
    } finally {
        try { $Listener.Stop() } catch { Write-Debug "FleetHealthListener: Listener.Stop() failed: $_" }
        $Listener.Close()
    }
}
