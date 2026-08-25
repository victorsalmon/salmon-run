<#
.DEPRECATED: This file is not loaded by the module loader and has zero callers in the codebase.
Kept for reference per Script Deprecation Protocol.
#>

$script:localPlatformBaseUrl = "http://127.0.0.1:21001"
$script:localPlatformAuthHeader = $null

function Get-LocalPlatformAuthHeaders {
    if (-not $script:localPlatformAuthHeader) {
        $serverPassword = $env:OPENCODE_SERVER_PASSWORD
        if ($serverPassword) {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("opencode:" + $serverPassword))
            $script:localPlatformAuthHeader = @{ Authorization = "Basic $b64" }
        } else {
            $script:localPlatformAuthHeader = @{}
        }
    }
    return $script:localPlatformAuthHeader
}
function Initialize-Executor {
    $serverPassword = $env:OPENCODE_SERVER_PASSWORD
    if ($serverPassword) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("opencode:" + $serverPassword))
        $script:localPlatformAuthHeader = @{ Authorization = "Basic $b64" }
    }

    # Port conflict detection — lightweight TCP probe
    try {
        $uri = [uri]$script:localPlatformBaseUrl
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.ConnectAsync($uri.Host, $uri.Port).Wait(2000) | Out-Null
        if ($tcp.Connected) {
            $tcp.Close()
            # Port is open — verify it's actually our server with a quick probe
            try {
                $null = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/api/health" -TimeoutSec 3 -ErrorAction Stop
                Write-OrchestratorLog "LOCAL_PLATFORM_PORT_OK url=$script:localPlatformBaseUrl"
            } catch {
                Write-Warning "Local-Platform executor: Port $($uri.Port) is occupied but does not appear to be opencode serve"
                Write-OrchestratorLog "LOCAL_PLATFORM_PORT_CONFLICT url=$script:localPlatformBaseUrl error='$($_.Exception.Message)'" -Level WARN
            }
        }
    } catch {
        Write-OrchestratorLog "LOCAL_PLATFORM_PORT_PROBE_FAILED url=$script:localPlatformBaseUrl error='$($_.Exception.Message)'" -Level WARN
    }

    # Retry loop — 3 attempts, 2s backoff
    $lastError = $null
    $errLocalPlatformConnect = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/api/health" -Headers (Get-LocalPlatformAuthHeaders) -TimeoutSec 5 -ErrorAction Stop -ErrorVariable +errLocalPlatformConnect
            Write-OrchestratorLog "LOCAL_PLATFORM_CONNECT url=$script:localPlatformBaseUrl health='$($health | ConvertTo-Json -Compress)'"

            $errLocalPlatformAuth = $null
            try {
                $null = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session" -Method Post -Body '{}' -ContentType "application/json" -Headers (Get-LocalPlatformAuthHeaders) -TimeoutSec 5 -ErrorAction Stop -ErrorVariable +errLocalPlatformAuth
                Write-OrchestratorLog "LOCAL_PLATFORM_AUTH_OK"
            } catch {
                $authStatus = if ($_.Exception.Response.StatusCode -eq 401) { "unauthorized" } else { "unexpected: $($_.Exception.Message)" }
                Write-Warning "Local-Platform executor: auth test returned $authStatus"
                Write-OrchestratorLog "LOCAL_PLATFORM_AUTH_STATUS status=$authStatus errorVar='$($errLocalPlatformAuth[-1].Exception.Message)'" -Level WARN
            }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) {
                $delay = Get-BackoffDelay -Attempt $attempt -Schedule @(2, 4, 8) -JitterFraction 0.25
                Write-OrchestratorLog "LOCAL_PLATFORM_RETRY attempt=$attempt delay=${delay}s error='$($_.Exception.Message)'" -Level WARN
                Start-Sleep -Seconds $delay
            }
        }
    }
    if ($errLocalPlatformConnect) { Write-OrchestratorLog "LOCAL_PLATFORM_CONNECT_ERRORS count=$($errLocalPlatformConnect.Count)" -Level WARN }

    Write-Warning "Local-Platform executor: opencode serve not detected at $script:localPlatformBaseUrl after 3 attempts"
    Write-Warning "Start it manually: opencode serve --port 21001 --hostname 127.0.0.1"
    Write-OrchestratorLog "LOCAL_PLATFORM_CONNECT_FAILED url=$script:localPlatformBaseUrl error='$($lastError.Exception.Message)'" -Level WARN
    throw "Cannot connect to local opencode serve at $script:localPlatformBaseUrl after 3 attempts. Start it manually first."
}

function Invoke-ExecutorTask {
    param(
        [string]$StreamId,
        [string]$StreamDir,
        [string]$RepoDir,
        [string]$OpencodePath,
        [int]$InstanceId,
        [ValidateSet("coder", "reviewer")]
        [string]$Role = "coder",
        [switch]$UseWorktrees,
        [string]$Namespace = ""
    )
    $headers = Get-LocalPlatformAuthHeaders

    $session = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session" `
        -Method Post -Body '{}' -ContentType "application/json" `
        -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $sessionId = $session.id

    $env:OC_STREAM_ID = $StreamId
    $env:OC_STREAM_DIR = $StreamDir
    $env:OC_STREAM_ROLE = $Role
    $env:OC_PROJECT_ROOT = $RepoDir

    $command = if ($Role -eq "reviewer") { "work-review" } else { "work-stream" }
    $promptBody = @{
        parts = @(@{ type = "text"; text = "Run --command $command" })
    } | ConvertTo-Json -Compress -Depth 5
    try {
        $null = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session/$sessionId/prompt_async" `
            -Method Post -Body $promptBody -ContentType "application/json" `
            -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    } catch [System.InvalidOperationException] {
        Write-OrchestratorLog "LOCAL_PLATFORM_PROMPT_ACCEPTED_204 session=$sessionId" -Level INFO
    }

    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value "session:$sessionId" -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline

    return New-ExecutorTask -Handle @{ SessionId = $sessionId } -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task.Handle -or -not $Task.Handle.SessionId) { return }
    $headers = Get-LocalPlatformAuthHeaders

    try {
        $statusMap = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session/status" `
            -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        $props = $statusMap.PSObject.Properties
        $sessionProp = $props | Where-Object { $_.Name -eq $Task.Handle.SessionId }
        if (-not $sessionProp) {
            $Task.HasExited = $true
            $Task.ExitCode = 0
            $Task.Output = "Session not found in status map — completed and cleaned up"
        } else {
            $statusType = $sessionProp.Value.type
            $Task.HasExited = ($statusType -eq "idle")
            if ($Task.HasExited) {
                $Task.ExitCode = 0
                $Task.Output = "Session completed"
            }
        }
    } catch {
        Write-OrchestratorLog "LOCAL_PLATFORM_TASK_STATUS_FAILED error='$($_.Exception.Message)'" -Level WARN
    }
}

function Stop-ExecutorTask {
    param($Task)
    if (-not $Task.Handle -or -not $Task.Handle.SessionId) { return }
    $headers = Get-LocalPlatformAuthHeaders
    try {
        $null = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session/$($Task.Handle.SessionId)" `
            -Method Delete -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue
    } catch { Write-OrchestratorLog "LOCAL_PLATFORM_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN }
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $headers = Get-LocalPlatformAuthHeaders

    $session = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session" `
        -Method Post -Body '{}' -ContentType "application/json" `
        -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $sessionId = $session.id

    $env:OC_WORKTREE_PATH = $WorktreePath
    $env:OC_BRANCH_NAME = $BranchName
    $env:OC_MERGE_PLAN = $MergePlan
    $env:OC_PROJECT_ROOT = $RepoDir

    $promptBody = @{
        parts = @(@{ type = "text"; text = "Run --command merge" })
    } | ConvertTo-Json -Compress -Depth 5
    try {
        $null = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session/$sessionId/prompt_async" `
            -Method Post -Body $promptBody -ContentType "application/json" `
            -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    } catch [System.InvalidOperationException] {
        Write-OrchestratorLog "LOCAL_PLATFORM_MERGE_ACCEPTED_204 session=$sessionId" -Level INFO
    }

    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Seconds 3
        try {
            $statusMap = Invoke-RestMethod -Uri "$script:localPlatformBaseUrl/session/status" `
                -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            $props = $statusMap.PSObject.Properties
            $sessionProp = $props | Where-Object { $_.Name -eq $sessionId }
            if (-not $sessionProp -or $sessionProp.Value.type -eq "idle") {
                Write-OrchestratorLog "LOCAL_PLATFORM_MERGE_COMPLETED session=$sessionId" -Level INFO
                return @{ ExitCode = 0; Output = "Merge completed" }
            }
        } catch {
            Write-OrchestratorLog "LOCAL_PLATFORM_MERGE_POLL_FAILED error='$($_.Exception.Message)'" -Level WARN
        }
    }
    Write-OrchestratorLog "LOCAL_PLATFORM_MERGE_TIMEOUT session=$sessionId" -Level WARN
    return @{ ExitCode = 1; Output = "Merge timed out after 10 minutes" }
}

function Disconnect-Executor {
}

function Start-StreamCoder {
    param(
        [string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$OpencodePath,
        [int]$InstanceId, [ValidateSet("coder", "reviewer")][string]$Role = "coder",
        [switch]$UseWorktrees, [string]$Namespace = ""
    )
    return Invoke-ExecutorTask -StreamId $StreamId -StreamDir $StreamDir -RepoDir $RepoDir -OpencodePath $OpencodePath -InstanceId $InstanceId -Role $Role -UseWorktrees:$UseWorktrees -Namespace $Namespace
}

