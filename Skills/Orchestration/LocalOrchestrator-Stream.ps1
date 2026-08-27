<#
.SYNOPSIS
    Stream CRUD module for the reactive orchestrator dispatch model.
.DESCRIPTION
    Each stream is a Working/stream-<N>/ subdirectory with a stream.json
    metadata file. Plan file Lock Headers serve as the canonical per-file log.
    Streams are the core abstraction for managing concurrent coder/reviewer
    processes.
#>

function Get-NextStreamId {
    <#
    .SYNOPSIS
        Scans Working/stream-*/ directories for the next available integer ID.
    .PARAMETER WorkingDir
        Path to the Tasks/Working directory.
    #>
    param([string]$WorkingDir)
    $maxId = 0
    $dirs = Get-ChildItem "$WorkingDir/stream-*" -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if ($d.Name -match '^stream-(\d+)$') {
            $id = [int]$Matches[1]
            if ($id -gt $maxId) { $maxId = $id }
        }
    }
    return $maxId + 1
}

function New-Stream {
    <#
    .SYNOPSIS
        Creates a new stream directory with metadata file.
    .PARAMETER WorkingDir
        Path to the Tasks/Working directory.
    .PARAMETER Namespace
        Connascence namespace for this stream's files.
    .PARAMETER Role
        Agent role: "coder" or "reviewer".
    #>
    param([string]$WorkingDir, [string]$Namespace, [string]$Role)
    $streamId = Get-NextStreamId -WorkingDir $WorkingDir
    $streamDir = Join-Path $WorkingDir "stream-$streamId"
    $null = New-Item -ItemType Directory -Path $streamDir -Force

    $metadata = @{
        Id        = $streamId
        Namespace = $Namespace
        Role      = $Role
        Created   = [datetime]::UtcNow.ToString('o')
    }
    $metadata | ConvertTo-Json | Set-Content (Join-Path $streamDir "stream.json") -Encoding utf8

    return @{
        Id        = $streamId
        Path      = $streamDir
        Namespace = $Namespace
        Role      = $Role
        Pid       = $null
    }
}

function Remove-Stream {
    <#
    .SYNOPSIS
        Removes a stream directory and all contents, cleans up PID/heartbeat files.
    .PARAMETER StreamDir
        Path to the stream directory.
    .PARAMETER AgentId
        Agent ID associated with this stream (for PID/heartbeat cleanup).
    #>
    param([string]$StreamDir, [string]$AgentId)
    if (-not (Test-Path $StreamDir)) { return }
    Remove-Item $StreamDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($AgentId) {
        $agentDir = Join-Path (Split-Path (Split-Path $StreamDir)) "Logs/agents"
        Remove-Item (Join-Path $agentDir "$AgentId.pid") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $agentDir "$AgentId.heartbeat") -Force -ErrorAction SilentlyContinue
    }
}

function Get-StreamStatus {
    <#
    .SYNOPSIS
        Reads stream metadata and checks PID aliveness.
    .PARAMETER StreamDir
        Path to the stream directory.
    #>
    param([string]$StreamDir)
    if (-not (Test-Path $StreamDir)) { return $null }

    $metaPath = Join-Path $StreamDir "stream.json"
    $meta = if (Test-Path $metaPath) { Get-Content $metaPath -Raw | ConvertFrom-Json } else { $null }

    # Read last action from the newest plan file's Lock Header (canonical log)
    $lastAction = $null
    $planFiles = Get-ChildItem "$StreamDir\*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($planFiles) {
        $content = Get-Content $planFiles[0].FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match '- Status: (\S+)') {
            $status = $Matches[1]
            $agentMatch = [regex]::Match($content, '- Agent: (\S+)')
            $agent = if ($agentMatch.Success) { $agentMatch.Groups[1].Value } else { "unknown" }
            $lastAction = "[$agent] Status=$status"
        }
    }
    # Fallback: check legacy stream.log
    if (-not $lastAction) {
        $logPath = Join-Path $StreamDir "stream.log"
        if (Test-Path $logPath) {
            $lastAction = (Get-Content $logPath -TotalCount 1 -ErrorAction SilentlyContinue)
        }
    }

    $pidAlive = $false
    if ($meta -and $meta.Pid) {
        $pidAlive = (Get-Process -Id ([int]$meta.Pid) -ErrorAction SilentlyContinue) -ne $null
    }

    return @{
        Id         = if ($meta) { $meta.Id } else { $null }
        Namespace  = if ($meta) { $meta.Namespace } else { $null }
        Role       = if ($meta) { $meta.Role } else { $null }
        LastAction = $lastAction
        PidAlive   = $pidAlive
    }
}

function Add-FileToStream {
    <#
    .SYNOPSIS
        Moves a file from Tasks/Code/ or Tasks/Review/ into the stream's Working/ directory.
    .PARAMETER StreamDir
        Path to the stream directory.
    .PARAMETER SourcePath
        Full path to the source file.
    #>
    param([string]$StreamDir, [string]$SourcePath)
    if (-not (Test-Path $SourcePath)) { return }
    $dest = Join-Path $StreamDir (Split-Path $SourcePath -Leaf)
    Move-Item -LiteralPath $SourcePath -Destination $dest -Force
}
