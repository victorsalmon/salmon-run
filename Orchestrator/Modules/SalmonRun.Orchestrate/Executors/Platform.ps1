<#
.DEPRECATED: This file is not loaded by the module loader and has zero callers in the codebase.
Kept for reference per Script Deprecation Protocol.
#>

$script:platformBaseUrl = "http://mcp_opencode:21001"
$script:platformAuthHeader = $null

function Get-PlatformAuthHeaders {
    if (-not $script:platformAuthHeader) {
        $pwd = $env:OPENCODE_SERVER_PASSWORD
        if ($pwd) {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("opencode:" + $pwd))
            $script:platformAuthHeader = @{ Authorization = "Basic $b64" }
        } else {
            $script:platformAuthHeader = @{}
        }
    }
    return $script:platformAuthHeader
}

function Initialize-Executor {
    Get-PlatformAuthHeaders

    $lastError = $null
    $errPlatformConnect = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri "$script:platformBaseUrl/api/health" -Headers (Get-PlatformAuthHeaders) -TimeoutSec 10 -ErrorAction Stop -ErrorVariable +errPlatformConnect
            Write-OrchestratorLog "PLATFORM_CONNECT url=$script:platformBaseUrl health='$($health | ConvertTo-Json -Compress)'"

            $errPlatformAuth = $null
            try {
                $authTest = Invoke-RestMethod -Uri "$script:platformBaseUrl/session" -Method Post -Body '{}' -ContentType "application/json" -Headers (Get-PlatformAuthHeaders) -TimeoutSec 10 -ErrorAction Stop -ErrorVariable +errPlatformAuth
                Write-OrchestratorLog "PLATFORM_AUTH_OK"
            } catch {
                $authStatus = if ($_.Exception.Response.StatusCode -eq 401) { "unauthorized" } else { "unexpected: $($_.Exception.Message)" }
                Write-Warning "Platform executor: auth test returned $authStatus"
                Write-OrchestratorLog "PLATFORM_AUTH_STATUS status=$authStatus errorVar='$($errPlatformAuth[-1].Exception.Message)'" -Level WARN
            }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) {
                $delay = Get-BackoffDelay -Attempt $attempt -Schedule @(2, 4, 8) -JitterFraction 0.25
                Write-OrchestratorLog "PLATFORM_RETRY attempt=$attempt delay=${delay}s error='$($_.Exception.Message)'" -Level WARN
                Start-Sleep -Seconds $delay
            }
        }
    }
    if ($errPlatformConnect) { Write-OrchestratorLog "PLATFORM_CONNECT_ERRORS count=$($errPlatformConnect.Count)" -Level WARN }

    Write-OrchestratorLog "PLATFORM_CONNECT_FAILED url=$script:platformBaseUrl error='$($lastError.Exception.Message)'" -Level WARN
    throw "Cannot connect to platform server at $script:platformBaseUrl after 3 attempts."
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
    $headers = Get-PlatformAuthHeaders

    $session = Invoke-RestMethod -Uri "$script:platformBaseUrl/session" `
        -Method Post -Body '{}' -ContentType "application/json" `
        -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $sessionId = $session.id

    if (-not (Test-WorkspaceIsShared)) {
        Copy-TaskFileToContainer -ContainerIdOrName "mcp_opencode" `
            -TaskFilePath (Join-Path $RepoDir $StreamDir) `
            -RepoDir $RepoDir
    }

    $command = if ($Role -eq "reviewer") { "work-review" } else { "work-stream" }
    $promptBody = @{
        prompt   = "Run --command $command"
        async    = $true
    } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod -Uri "$script:platformBaseUrl/session/$sessionId/prompt_async" `
        -Method Post -Body $promptBody -ContentType "application/json" `
        -Headers $headers -TimeoutSec 30 -ErrorAction Stop

    $agentDir = Join-Path $RepoDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    Set-Content -Path (Join-Path $agentDir "$StreamId.pid") -Value "session:$sessionId" -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $agentDir "$StreamId.heartbeat") -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8 -NoNewline

    return New-ExecutorTask -Handle @{ SessionId = $sessionId } -StreamId $StreamId -StartTime (Get-Date) -Role $Role -Namespace $Namespace
}

function Get-ExecutorTaskStatus {
    param($Task)
    if (-not $Task.Handle -or -not $Task.Handle.SessionId) { return }
    $headers = Get-PlatformAuthHeaders

    try {
        $status = Invoke-RestMethod -Uri "$script:platformBaseUrl/session/$($Task.Handle.SessionId)" `
            -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue
        $Task.HasExited = $status.status -in @("completed", "failed", "stopped")
        if ($Task.HasExited) {
            $Task.ExitCode = if ($status.status -eq "completed") { 0 } else { 1 }
            $Task.Output = $status.output
        }
    } catch {
        Write-OrchestratorLog "PLATFORM_TASK_STATUS_FAILED error='$($_.Exception.Message)'" -Level WARN
    }
}

function Stop-ExecutorTask {
    param($Task)
    if (-not $Task.Handle -or -not $Task.Handle.SessionId) { return }
    $headers = Get-PlatformAuthHeaders
    try {
        $null = Invoke-RestMethod -Uri "$script:platformBaseUrl/session/$($Task.Handle.SessionId)" `
            -Method Delete -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue
    } catch { Write-OrchestratorLog "PLATFORM_TASK_STOP_FAILED error='$($_.Exception.Message)'" -Level WARN }
}

function Invoke-ExecutorMerge {
    param($MergePlan, $WorktreePath, $BranchName, $RepoDir)
    $headers = Get-PlatformAuthHeaders

    $session = Invoke-RestMethod -Uri "$script:platformBaseUrl/session" `
        -Method Post -Body '{}' -ContentType "application/json" `
        -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $sessionId = $session.id

    $promptBody = @{
        prompt   = "Run --command merge"
        async    = $false
    } | ConvertTo-Json -Compress
    $result = Invoke-RestMethod -Uri "$script:platformBaseUrl/session/$sessionId/prompt" `
        -Method Post -Body $promptBody -ContentType "application/json" `
        -Headers $headers -TimeoutSec 600 -ErrorAction Stop
    return @{ ExitCode = $result.exit_code; Output = $result.output }
}

function Disconnect-Executor {
}
