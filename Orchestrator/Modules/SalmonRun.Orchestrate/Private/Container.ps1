function Get-ContainerAgentPool {
    param([string]$ServiceFilter = "mcp_opencode")
    $containers = docker ps --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}" --filter "name=$ServiceFilter" 2>$null
    if (-not $containers) {
        Write-OrchestratorLog "CONTAINER_POOL_EMPTY filter='$ServiceFilter'" -Level WARN
        return @()
    }
    $pool = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $containers) {
        $parts = $line -split "`t"
        $containerId = $parts[0]
        $containerName = $parts[1]
        $status = $parts[2]
        $image = $parts[3]
        $serviceName = if ($containerName -match '^(\S+)\.\d+\.') { $Matches[1] } else { $containerName }
        $instanceIndex = if ($containerName -match '\.(\d+)\.') { [int]$Matches[1] } else { 0 }
        $pool.Add([PSCustomObject]@{ Id=$containerId; Name=$containerName; ServiceName=$serviceName; InstanceIndex=$instanceIndex; Status=$status; Image=$image; Available=$status -match 'Up' })
    }
    Write-OrchestratorLog "CONTAINER_POOL_DISCOVERED count=$($pool.Count) filter='$ServiceFilter'"
    return $pool
}

function Get-AvailableContainerAgent {
    $pool = Get-ContainerAgentPool
    if (-not $pool) { return $null }
    foreach ($c in $pool) {
        if ($c.Available) {
            Write-OrchestratorLog "CONTAINER_AGENT_SELECTED container=$($c.Name) id=$($c.Id)"
            return $c
        }
    }
    Write-OrchestratorLog "CONTAINER_AGENT_UNAVAILABLE pool_size=$($pool.Count)" -Level WARN
    return $null
}

function Get-ContainerCodingKey {
    param([string]$ContainerIdOrName)
    $result = docker exec $ContainerIdOrName sh -c 'grep "^OPENCODE_GO_KEY=" /tmp/coding.env | head -1' 2>$null
    if (-not $result) {
        Write-OrchestratorLog "CONTAINER_KEY_READ_FAILED container=$ContainerIdOrName" -Level WARN
        return $null
    }
    $key = $result -replace '^OPENCODE_GO_KEY=', ''
    if (-not $key) {
        Write-OrchestratorLog "CONTAINER_KEY_EMPTY container=$ContainerIdOrName" -Level WARN
        return $null
    }
    Write-OrchestratorLog "CONTAINER_KEY_READ container=$ContainerIdOrName key_present=$([bool]$key)"
    return $key
}

function Initialize-ContainerTaskDir {
    param([string]$ContainerIdOrName)
    docker exec $ContainerIdOrName sh -c 'mkdir -p /workspace/Tasks/Code /workspace/Tasks/Review /workspace/Tasks/Working' 2>$null | Out-Null
}

function Copy-TaskFileToContainer {
    param([string]$ContainerIdOrName, [string]$TaskFilePath, [string]$RepoDir)
    Initialize-ContainerTaskDir -ContainerIdOrName $ContainerIdOrName
    $taskFileName = Split-Path $TaskFilePath -Leaf
    $containerTaskDir = "/workspace/Tasks/Code/"
    $cpTask = docker cp $TaskFilePath "${ContainerIdOrName}:${containerTaskDir}${taskFileName}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-OrchestratorLog "CONTAINER_CP_TASK_FAILED file=$taskFileName error='$cpTask'" -Level ERROR
        return $false
    }
    $containerConfigPath = Join-Path $RepoDir "Infrastructure\opencode\config\container-run.json"
    if (Test-Path $containerConfigPath) {
        $cpConfig = docker cp $containerConfigPath "${ContainerIdOrName}:/workspace/coding-opencode.json" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OrchestratorLog "CONTAINER_CP_CONFIG config=coding-opencode.json"
        } else {
            Write-OrchestratorLog "CONTAINER_CP_CONFIG_FAILED error='$cpConfig'" -Level WARN
        }
    } else {
        Write-OrchestratorLog "CONTAINER_CP_CONFIG_MISSING config_path=$containerConfigPath" -Level WARN
    }
    Write-OrchestratorLog "CONTAINER_CP_TASK file=$taskFileName container=$ContainerIdOrName"
    return $true
}

function Copy-TaskFilesFromContainer {
    param([string]$ContainerIdOrName, [string]$RepoDir)
    $hostTaskDir = Join-Path $RepoDir "Tasks"
    foreach ($subdir in @("Code", "Review", "Working")) {
        $containerPath = "/workspace/Tasks/$subdir/"
        $hostPath = Join-Path $hostTaskDir $subdir
        $null = New-Item -ItemType Directory -Path $hostPath -Force
        $result = docker cp "${ContainerIdOrName}:${containerPath}." $hostPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-OrchestratorLog "CONTAINER_CP_BACK_FAILED dir=$subdir error='$result'" -Level WARN
        } else {
            Write-OrchestratorLog "CONTAINER_CP_BACK dir=$subdir"
        }
    }
}

function Invoke-ContainerAgent {
    param([object]$Container, [string]$TaskFilePath, [string]$Role, [string]$RepoDir, [int]$SubprocessTimeoutMinutes = 30)
    $taskFileName = Split-Path $TaskFilePath -Leaf
    $agentId = "container-$Role-$(Get-Random -Minimum 1 -Maximum 1000001)-$([Math]::Floor((Get-Date).ToFileTime() / 1000))"
    $copyOk = Copy-TaskFileToContainer -ContainerIdOrName $Container.Name -TaskFilePath $TaskFilePath -RepoDir $RepoDir
    if (-not $copyOk) {
        return [PSCustomObject]@{ AgentId=$agentId; ContainerName=$Container.Name; Success=$false; Error="Failed to copy task file to container" }
    }
    $codingKey = Get-ContainerCodingKey -ContainerIdOrName $Container.Name
    if (-not $codingKey) {
        Write-OrchestratorLog "CONTAINER_DISPATCH_NO_KEY agent=$agentId container=$($Container.Name)" -Level ERROR
        return [PSCustomObject]@{ AgentId=$agentId; ContainerName=$Container.Name; Success=$false; Error="No coding key available in container" }
    }
    $subCommand = if ($Role -eq "coder") { "work-code" } else { "work-review" }
    $agentLogDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentLogDir -Force
    $agentLog = Join-Path $agentLogDir "$agentId.log"
    $outFile = Join-Path $agentLogDir "$agentId.stdout"
    $errFile = Join-Path $agentLogDir "$agentId.stderr"
    $envVars = @("-e", "OPENCODE_GO_KEY=$codingKey", "-e", "OC_RESERVATION_FILE=$taskFileName", "-e", "OC_RESERVATION_ROLE=$Role", "-e", "OC_RESERVATION_AGENT_ID=$agentId", "-e", "OC_PROJECT_ROOT=/workspace", "-w", "/workspace")
    $innerCommand = ". /tmp/coding.env 2>/dev/null; cp /workspace/coding-opencode.json /workspace/opencode.json 2>/dev/null; cd /workspace && opencode run --command $subCommand 2>&1"
    Write-OrchestratorLog "CONTAINER_DISPATCH agent=$agentId role=$Role container=$($Container.Name) file=$taskFileName command=$subCommand"
    $agentId | Out-File -FilePath (Join-Path $agentLogDir "$agentId.pid") -Encoding utf8 -NoNewline
    $role | Out-File -FilePath (Join-Path $agentLogDir "$agentId.role") -Encoding utf8 -NoNewline
    $Container.Name | Out-File -FilePath (Join-Path $agentLogDir "$agentId.container") -Encoding utf8 -NoNewline
    [datetime]::UtcNow.ToString('o') | Out-File -FilePath (Join-Path $agentLogDir "$agentId.heartbeat") -Encoding utf8 -NoNewline
    $startTime = Get-Date
    $dockerArgs = $envVars + @($Container.Name, "sh", "-c", $innerCommand)
    $proc = Start-Process -FilePath "docker" -ArgumentList "exec", $dockerArgs -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Write-OrchestratorLog "CONTAINER_AGENT_STARTED agent=$agentId pid=$($proc.Id) container=$($Container.Name)"
    return [PSCustomObject]@{ AgentId=$agentId; ContainerName=$Container.Name; Process=$proc; StartTime=$startTime; Success=$true; Error=$null; Role=$Role; FileName=$taskFileName }
}

function Test-WorkspaceIsShared {
    $markerPath = Join-Path $RepoDir "Tasks/Logs/.workspace-shared"
    if (Test-Path $markerPath) { return $true }
    try {
        $mounts = docker inspect mcp_opencode --format '{{json .Mounts}}' 2>$null | ConvertFrom-Json
        $hasShared = $mounts | Where-Object { $_.Type -eq "volume" -and $_.Destination -eq "/workspace" }
        if ($hasShared) {
            "true" | Set-Content $markerPath -Encoding utf8 -NoNewline
            return $true
        }
    } catch {
        Write-OrchestratorLog "WORKSPACE_SHARED_CHECK_FAILED error='$($_.Exception.Message)'" -Level WARN
    }
    return $false
}

function Test-ContainerAgentAlive {
    param([string]$AgentId, [string]$RepoDir)
    $agentLogDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $containerFile = Join-Path $agentLogDir "$AgentId.container"
    if (-not (Test-Path $containerFile)) { return $false }
    $containerName = Get-Content $containerFile -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if (-not $containerName) { return $false }
    $containerRunning = docker ps --format "{{.Names}}" --filter "name=$containerName" 2>$null
    if (-not $containerRunning) { return $false }
    return $true
}
