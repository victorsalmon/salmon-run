<#
.SYNOPSIS
    Container-based agent dispatch for LocalOrchestrator.ps1.
.DESCRIPTION
    Provides functions to discover running mcp_opencode containers, dispatch
    tasks to them via docker exec with explicit key injection, and monitor
    completion.  This is the local equivalent of Veri dispatching work to
    opencode containers in the Docker Swarm.

    Key isolation model:
    - The orchestrator never sets OPENCODE_GO_KEY in its own environment.
    - Keys are read from the container's secrets bundle (/run/secrets/secrets_bundle)
      or pre-set env file (/tmp/coding.env).
    - Each dispatch passes the key explicitly via `docker exec -e`, scoped to
      that child process only.

    Task file access:
    - The container's shared workspace (/workspace/) has Task/Review and Task/Working
      skeletons but not the intersite-orchestrator repo.
    - Before dispatch, the orchestrator copies the task plan file into the
      container's /workspace/Tasks/Code/ directory via `docker cp`.
    - After completion, the orchestrator copies results back.
#>

# ─── Container discovery ─────────────────────────────────────────────────

<#
.SYNOPSIS
    Discovers running opencode containers in the Docker Swarm.
.DESCRIPTION
    Queries `docker ps` for containers matching the mcp_opencode service name
    pattern.  Returns an array of container objects with Name, ID, Status,
    ServiceName, and InstanceIndex properties.
.PARAMETER ServiceFilter
    Docker service name pattern to filter on (default: "mcp_opencode").
#>
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

        $pool.Add([PSCustomObject]@{
            Id             = $containerId
            Name           = $containerName
            ServiceName    = $serviceName
            InstanceIndex  = $instanceIndex
            Status         = $status
            Image          = $image
            Available      = $status -match 'Up'
        })
    }

    Write-OrchestratorLog "CONTAINER_POOL_DISCOVERED count=$($pool.Count) filter='$ServiceFilter'"
    return $pool
}

<#
.SYNOPSIS
    Returns the first available (healthy, running) container from the pool.
.DESCRIPTION
    Calls Get-ContainerAgentPool and returns the first container whose
    Status indicates it's running and healthy.  Returns $null if none
    are available.
#>
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

# ─── Key extraction ──────────────────────────────────────────────────────

<#
.SYNOPSIS
    Extracts the active coding key from a container's secrets bundle.
.DESCRIPTION
    Reads /tmp/coding.env (persisted by the entrypoint) from the container
    and returns the value of OPENCODE_GO_KEY.  This avoids sourcing the
    file (which has shell quoting issues with special characters in GitHub
    tokens and passwords).
.PARAMETER ContainerIdOrName
    Docker container ID or name to read the key from.
#>
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

# ─── Task file management ────────────────────────────────────────────────

<#
.SYNOPSIS
    Ensures the container's /workspace/Tasks/Code/ directory exists.
.DESCRIPTION
    Creates the Code/ subdirectory inside the container's workspace if it
    doesn't already exist.  The container has Review/ and Working/ skeletons
    from volume initialization, but Code/ may not exist.
.PARAMETER ContainerIdOrName
    Docker container ID or name.
#>
function Initialize-ContainerTaskDir {
    param([string]$ContainerIdOrName)
    docker exec $ContainerIdOrName sh -c 'mkdir -p /workspace/Tasks/Code /workspace/Tasks/Review /workspace/Tasks/Working' 2>$null | Out-Null
}

<#
.SYNOPSIS
    Copies a task plan file from the host into the container's workspace.
.DESCRIPTION
    Uses `docker cp` to copy the task file into /workspace/Tasks/Code/
    inside the container.  Also copies the intersite-orchestrator repo's
    opencode.json (with command templates) so that `opencode run --command`
    works correctly.
.PARAMETER ContainerIdOrName
    Docker container ID or name.
.PARAMETER TaskFilePath
    Absolute path to the task file on the host (e.g. C:\...\Tasks\Code\plan.md).
.PARAMETER InterclawDir
    Root of the intersite-orchestrator repository.
#>
function Copy-TaskFileToContainer {
    param(
        [string]$ContainerIdOrName,
        [string]$TaskFilePath,
        [string]$InterclawDir
    )

    Initialize-ContainerTaskDir -ContainerIdOrName $ContainerIdOrName

    $taskFileName = Split-Path $TaskFilePath -Leaf
    $containerTaskDir = "/workspace/Tasks/Code/"

    # Copy task file
    $cpTask = docker cp $TaskFilePath "${ContainerIdOrName}:${containerTaskDir}${taskFileName}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-OrchestratorLog "CONTAINER_CP_TASK_FAILED file=$taskFileName error='$cpTask'" -Level ERROR
        return $false
    }

    # Copy container-compatible opencode config with command templates
    $containerConfigPath = Join-Path $InterclawDir "Infrastructure\opencode\config\container-run.json"
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

<#
.SYNOPSIS
    Copies completed task files back from the container to the host.
.DESCRIPTION
    After an agent completes its work inside the container, copies
    the result files back to the host-side Tasks/ directories.
.PARAMETER ContainerIdOrName
    Docker container ID or name.
.PARAMETER InterclawDir
    Root of the intersite-orchestrator repository.
#>
function Copy-TaskFilesFromContainer {
    param(
        [string]$ContainerIdOrName,
        [string]$InterclawDir
    )

    $hostTaskDir = Join-Path $InterclawDir "Tasks"

    # Copy back from every task subdirectory
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

# ─── Agent dispatch ──────────────────────────────────────────────────────

<#
.SYNOPSIS
    Dispatches a task to a container agent via docker exec.
.DESCRIPTION
    The primary dispatch function.  Copies the task file into the container,
    reads the coding key, and runs `opencode run --command <command>` via
    docker exec with the key injected as an environment variable.

    The orchestrator does NOT set the key in its own environment — it passes
    it explicitly to the child process via `docker exec -e`.

    Returns a PSCustomObject with AgentId, ContainerName, Pid (docker exec
    process PID), and StartTime.
.PARAMETER Container
    Container object from Get-ContainerAgentPool (must have .Name property).
.PARAMETER TaskFilePath
    Absolute path to the task .md file on the host.
.PARAMETER Role
    "coder" or "reviewer" — determines which opencode command to run.
.PARAMETER InterclawDir
    Root of the intersite-orchestrator repository.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes before the docker exec is considered timed out.
#>
function Invoke-ContainerAgent {
    param(
        [object]$Container,
        [string]$TaskFilePath,
        [string]$Role,
        [string]$InterclawDir,
        [int]$SubprocessTimeoutMinutes = 30
    )

    $taskFileName = Split-Path $TaskFilePath -Leaf
    $agentId = "container-$Role-$(Get-Random -Minimum 1 -Maximum 1000001)-$([Math]::Floor((Get-Date).ToFileTime() / 1000))"

    # Ensure task dir and copy files
    $copyOk = Copy-TaskFileToContainer -ContainerIdOrName $Container.Name -TaskFilePath $TaskFilePath -InterclawDir $InterclawDir
    if (-not $copyOk) {
        return [PSCustomObject]@{
            AgentId       = $agentId
            ContainerName = $Container.Name
            Success       = $false
            Error         = "Failed to copy task file to container"
        }
    }

    # Read coding key from container
    $codingKey = Get-ContainerCodingKey -ContainerIdOrName $Container.Name
    if (-not $codingKey) {
        Write-OrchestratorLog "CONTAINER_DISPATCH_NO_KEY agent=$agentId container=$($Container.Name)" -Level ERROR
        return [PSCustomObject]@{
            AgentId       = $agentId
            ContainerName = $Container.Name
            Success       = $false
            Error         = "No coding key available in container"
        }
    }

    # Build the docker exec command
    $subCommand = if ($Role -eq "coder") { "work-code" } else { "work-review" }

    $agentLogDir = Join-Path $InterclawDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentLogDir -Force
    $agentLog = Join-Path $agentLogDir "$agentId.log"
    $outFile = Join-Path $agentLogDir "$agentId.stdout"
    $errFile = Join-Path $agentLogDir "$agentId.stderr"

    # Environment for the agent inside the container
    # OPENCODE_GO_KEY is injected explicitly — orchestrator does NOT have it
    $envVars = @(
        "-e", "OPENCODE_GO_KEY=$codingKey"
        "-e", "OC_RESERVATION_FILE=$taskFileName"
        "-e", "OC_RESERVATION_ROLE=$Role"
        "-e", "OC_RESERVATION_AGENT_ID=$agentId"
        "-e", "OC_PROJECT_ROOT=/workspace"
        "-w", "/workspace"
    )

    # The command to run inside the container:
    # 1. Source coding.env for all secret vars (so GitHub tokens etc. are available)
    # 2. Use the coding-opencode.json config that has command templates
    # 3. Run opencode with the task
    $innerCommand = ". /tmp/coding.env 2>/dev/null; " +
        "cp /workspace/coding-opencode.json /workspace/opencode.json 2>/dev/null; " +
        "cd /workspace && opencode run --command $subCommand 2>&1"

    Write-OrchestratorLog "CONTAINER_DISPATCH agent=$agentId role=$Role container=$($Container.Name) file=$taskFileName command=$subCommand"

    # Write PID file first, then start
    $agentId | Out-File -FilePath (Join-Path $agentLogDir "$agentId.pid") -Encoding utf8 -NoNewline
    $role | Out-File -FilePath (Join-Path $agentLogDir "$agentId.role") -Encoding utf8 -NoNewline
    $Container.Name | Out-File -FilePath (Join-Path $agentLogDir "$agentId.container") -Encoding utf8 -NoNewline
    [datetime]::UtcNow.ToString('o') | Out-File -FilePath (Join-Path $agentLogDir "$agentId.heartbeat") -Encoding utf8 -NoNewline

    $startTime = Get-Date

    # Execute via docker exec
    $dockerArgs = $envVars + @($Container.Name, "sh", "-c", $innerCommand)
    $proc = Start-Process -FilePath "docker" -ArgumentList "exec", $dockerArgs `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    Write-OrchestratorLog "CONTAINER_AGENT_STARTED agent=$agentId pid=$($proc.Id) container=$($Container.Name)"

    return [PSCustomObject]@{
        AgentId       = $agentId
        ContainerName = $Container.Name
        Process       = $proc
        StartTime     = $startTime
        Success       = $true
        Error         = $null
        Role          = $Role
        FileName      = $taskFileName
    }
}

<#
.SYNOPSIS
    Tests whether a container agent is still alive.
.DESCRIPTION
    Checks the container's running status via `docker ps` and the agent's
    heartbeat file.  Returns $true if both indicate the agent is alive.
.PARAMETER AgentId
    Agent identifier returned by Invoke-ContainerAgent.
.PARAMETER InterclawDir
    Root of the intersite-orchestrator repository.
#>
function Test-ContainerAgentAlive {
    param([string]$AgentId, [string]$InterclawDir)

    $agentLogDir = Join-Path $InterclawDir "Tasks/Logs/agents"
    $containerFile = Join-Path $agentLogDir "$AgentId.container"

    if (-not (Test-Path $containerFile)) {
        return $false
    }

    $containerName = Get-Content $containerFile -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if (-not $containerName) { return $false }

    $containerRunning = docker ps --format "{{.Names}}" --filter "name=$containerName" 2>$null
    if (-not $containerRunning) { return $false }

    return $true
}
