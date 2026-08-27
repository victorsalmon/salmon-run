<#
.SYNOPSIS
    Waits for Docker Swarm services to stabilize after deployment.
.DESCRIPTION
    Polls running services until all reach ready state or timeout.
    Optionally applies an initial startup delay before polling begins.
.PARAMETER StartupDelay
    Apply an initial delay before starting verification polls.
.OUTPUTS
    $true if all services stabilize, $false on timeout.
#>
function Invoke-FleetStartupVerification {
    [OutputType([bool])]
    param(
        [switch]$StartupDelay
    )
    <#
    .NOTES
        Timeout chain: Sequential Invoke-WebRequest calls (5s first attempt, 3s fallback).
        No outer timeout wrapper; executes within Invoke-FleetEntrypoint startup job.
    #>

    $script:Results = @()
    $script:FailCount = 0

    # --- Startup delay ---
    if ($StartupDelay) {
        Write-Verbose "`n[STARTUP CHECK] Waiting 5 minutes before running post-deploy checks..."
        Write-Verbose "  (This gives all containers time to initialize and the Orchestrator to complete its first boot.)"
        Start-Sleep -Seconds (Get-InterclawConstants).FleetMainLoopIntervalSec
    }

    Write-Verbose "`n========================================"
    Write-Verbose "  ORCHESTRATOR POST-DEPLOY UNIT TESTS"
    Write-Verbose "  $(Get-Date -Format 'o')"
    Write-Verbose "========================================`n"

    $StackName = Get-StackName

    if (-not $StackName) {
        Write-Warning "  [FAIL] No running stack found. Cannot run post-deploy checks."
        return 1
    }

    # Load install.json for identity
    $InstallJson = Read-InstallJson
    if ($InstallJson) { Export-InstallJsonToEnv -InstallJson $InstallJson -Force }

    # ==============================================================================
    # SECTION 1: Container Infrastructure
    # ==============================================================================
    Write-Verbose "[1] Container Infrastructure"

    $StackServices = docker stack services $StackName --format "{{.Name}}`t{{.Replicas}}`t{{.Image}}" 2>$null
    $ServiceCount = ($StackServices | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    Test-Step -Name "Stack services running" -Passed:($ServiceCount -ge 5) -Detail "$ServiceCount services" -Remediation "Re-run 0setup.ps1 or check Docker logs"

    foreach ($SvcLine in $StackServices) {
        if ([string]::IsNullOrWhiteSpace($SvcLine)) { continue }
        $Parts = $SvcLine -split "`t"
        $SvcName = $Parts[0]
        $Replicas = $Parts[1]
        $Current = if ($Replicas -match "^(\d+)/") { [int]$Matches[1] } else { 0 }
        $Desired = if ($Replicas -match "/(\d+)$") { [int]$Matches[1] } else { 0 }
        $Healthy = $Current -ge $Desired -and $Desired -gt 0
        Test-Step -Name "$SvcName running" -Passed $Healthy -Detail "$Replicas" -Remediation "docker service logs $SvcName --tail 20"
    }

    # ==============================================================================
    # SECTION 2: Agent Gateway Readiness
    # ==============================================================================
    Write-Verbose "`n[3] Agent Gateway Readiness"

    $FirstAgentSvc = $StackServices | Where-Object { $_ -match "oc-base" }
    if ($FirstAgentSvc) {
        $FirstAgentParts = $FirstAgentSvc -split "`t"
        $FirstAgentReplicas = $FirstAgentParts[1]
        $FirstAgentRunning = $FirstAgentReplicas -match "^[1-9]/"

        if ($FirstAgentRunning) {
            $GatewayPort = Get-AgentHostPort -Role BASE
            $TestPort = $GatewayPort

            try {
                $GatewayResp = Invoke-WebRequest -Uri "http://host.docker.internal:${TestPort}/health" -Method Get -TimeoutSec 5 -ErrorAction Stop
                Test-Step -Name "BASE gateway responding" -Passed:($GatewayResp.StatusCode -eq 200) -Detail "port $TestPort, status $($GatewayResp.StatusCode)" -Remediation "Check BASE container logs: docker logs <base-container> --tail 50"
            }
            catch {
                try {
                    $GatewayResp2 = Invoke-WebRequest -Uri "http://localhost:${TestPort}/health" -Method Get -TimeoutSec 3 -ErrorAction Stop
                    Test-Step -Name "BASE gateway responding" -Passed:($GatewayResp2.StatusCode -eq 200) -Detail "port $TestPort (localhost)" -Remediation "Check BASE container logs"
                }
                catch {
                    Test-Step -Name "BASE gateway responding" -Passed $false -Detail "no response on port $TestPort" -Remediation "Verify the BASE container is healthy and the gateway port is mapped: docker ps | grep oc-base"
                }
            }
        }
        else {
            Test-Step -Name "BASE gateway responding" -Passed $false -Detail "BASE service not running" -Remediation "Check BASE container: docker service logs ${StackName}_oc-base --tail 20"
        }
    }
    else {
        Test-Step -Name "BASE gateway responding" -Passed $false -Detail "no BASE service found in stack" -Remediation "Verify stack deployment"
    }

    # ==============================================================================
    # SECTION 4: Secret Hydration Validation
    # ==============================================================================
    Write-Verbose "`n[4] Secret Hydration Validation"

    $InstanceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($SvcLine in $StackServices) {
        if ($SvcLine -match "-(\d+)\s") { $InstanceIds.Add($Matches[1]) }
    }
    $InstanceIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$InstanceIds.ToArray())

    foreach ($Id in $InstanceIds) {
        $ContainerLine = docker ps --filter "name=oc-" --format "{{.ID}}|{{.Names}}" 2>$null |
            Where-Object { $_ -match "-$Id`\." }

        if ($ContainerLine) {
            $ContainerId = ($ContainerLine -split "\|")[0]
            $ContainerLogs = docker logs $ContainerId --tail 50 2>&1


            $SecretErrors = $ContainerLogs | Where-Object { $_ -match "missing env var|SecretRefResolutionError|required secrets are unavailable" }
            if ($SecretErrors) {
                $ErrorDetail = ($SecretErrors | Select-Object -First 1) -replace '.*missing env var "([^"]+)".*', '$1'
                Test-Step -Name "Agent $Id secret resolution" -Passed $false -Detail "Unresolved: $ErrorDetail" -Remediation "Re-run 0setup.ps1 to rehydrate secrets, or check the Docker secret: docker secret ls | grep $Id"
            }
            else {
                Test-Step -Name "Agent $Id secret resolution" -Passed $true -Detail "all secrets resolved"
            }

            $ConfigErrors = $ContainerLogs | Where-Object { $_ -match "Config invalid|Config.*invalid|schema.*error" }
            if ($ConfigErrors) {
                Test-Step -Name "Agent $Id config validation" -Passed $false -Detail "config schema error in logs" -Remediation "Check ORCHESTRATOR.json in the agent's persist volume"
            }
            else {
                Test-Step -Name "Agent $Id config validation" -Passed $true -Detail "config valid"
            }
        }
        else {
            Test-Step -Name "Agent $Id secret resolution" -Passed $false -Detail "container not running" -Remediation "Start the agent container first"
        }
    }

    # ==============================================================================
    # SECTION 5: Fleet Elevated Credentials
    # ==============================================================================
    Write-Verbose "`n[5] Fleet Elevated Credentials"

    $FleetKeyId = Read-FleetSecret -SecretName "fleet_aws_id"
    $FleetSecretKey = Read-FleetSecret -SecretName "fleet_aws_secret"
    $FleetHasCredentials = (-not [string]::IsNullOrWhiteSpace($FleetKeyId)) -and (-not [string]::IsNullOrWhiteSpace($FleetSecretKey))

    $origAccessKey = $env:AWS_ACCESS_KEY_ID
    $origSecretKey = $env:AWS_SECRET_ACCESS_KEY
    $origSessionToken = $env:AWS_SESSION_TOKEN

    try {
        if ($FleetHasCredentials) {
            $FleetKeyValid = $false
            try {
                $env:AWS_ACCESS_KEY_ID = $FleetKeyId
                $env:AWS_SECRET_ACCESS_KEY = $FleetSecretKey
                $CallerResult = Invoke-AwsCommand { aws sts get-caller-identity --output json 2>$null }
                if ($CallerResult.Success -and -not [string]::IsNullOrWhiteSpace($CallerResult.Output)) {
                    $FleetKeyValid = $true
                    $IdentityObj = $CallerResult.Output | ConvertFrom-Json
                    Test-Step -Name "Fleet AWS credentials valid" -Passed $true -Detail "user: $($IdentityObj.Arn)" -Remediation ""
                }
            }
            catch { Write-SetupLog "ERROR: FleetStartupVerification STS check failed: $_" -Level ERROR }

            if (-not $FleetKeyValid) {
                Test-Step -Name "Fleet AWS credentials valid" -Passed $false -Detail "credentials present but STS call failed" -Remediation "Re-run 0setup.ps1 to regenerate the fleet IAM access key"
            }

            if ($FleetKeyValid) {
                $FleetCanReadSecrets = $false
                $FleetSecretId = Get-AwsSecretId
                try {
                    $SecretResult = Invoke-AwsCommand { aws secretsmanager get-secret-value --secret-id $FleetSecretId --region $($env:AWS_SECRETS_REGION ?? "ca-central-1") --query "Name" --output text 2>$null }
                    if ($SecretResult.Success) { $FleetCanReadSecrets = $true }
                }
                catch { Write-SetupLog "ERROR: FleetStartupVerification secrets-manager check failed: $_" -Level ERROR }
                Test-Step -Name "Fleet can read AWS Secrets Manager" -Passed:([bool]$FleetCanReadSecrets) -Detail $(if ($FleetCanReadSecrets) { "$FleetSecretId accessible" } else { "access denied to $FleetSecretId" })         -Remediation "Check the fleet IAM policy includes secretsmanager:GetSecretValue for Interclaw/FRAD/*"
            }
        }
        else {
            Test-Step -Name "Fleet AWS credentials present" -Passed $false -Detail "fleet_aws_id / fleet_aws_secret secrets not mounted" -Remediation "Re-run 0setup.ps1 so the fleet IAM user is created during AWS provisioning"
        }
    }
    finally {
        $env:AWS_ACCESS_KEY_ID = $origAccessKey
        $env:AWS_SECRET_ACCESS_KEY = $origSecretKey
        $env:AWS_SESSION_TOKEN = $origSessionToken
    }

    # ==============================================================================
    # SECTION 6: Tailscale Connectivity (Native Windows)
    # ==============================================================================
    Write-Verbose "`n[6] Tailscale Connectivity"

    $TailscaleCmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($TailscaleCmd) {
        $TailscaleResult = Invoke-NativeCommand { & tailscale status --json 2>$null }
        if ($TailscaleResult.Success -and -not [string]::IsNullOrWhiteSpace($TailscaleResult.Output)) {
            try {
                $TsStatusObj = $TailscaleResult.Output | ConvertFrom-Json
                $TsOnline = $TsStatusObj.BackendState -eq "Running"
                Test-Step -Name "Tailscale daemon connected" -Passed:([bool]$TsOnline) -Detail "state: $($TsStatusObj.BackendState)" -Remediation "Run 'tailscale login' or check Tailscale auth key"
            }
            catch {
                Test-Step -Name "Tailscale daemon connected" -Passed $false -Detail "could not parse tailscale status" -Remediation "Run: tailscale status"
            }
        }
        else {
            Test-Step -Name "Tailscale daemon connected" -Passed $false -Detail "tailscale status command failed" -Remediation "Check Tailscale is installed and authenticated"
        }

        $SubnetResult = Invoke-NativeCommand { & tailscale status --self 2>$null }
        if ($SubnetResult.Success -and -not [string]::IsNullOrWhiteSpace($SubnetResult.Output)) {
            $HasSubnetRoutes = $SubnetResult.Output -match "10\.0\."
            Test-Step -Name "Subnet routes advertised" -Passed:([bool]$HasSubnetRoutes) -Detail $(if ($HasSubnetRoutes) { "10.0.0.0/16 advertised" } else { "no subnet routes found" }) -Remediation "Approve subnet routes in Tailscale admin console and run 'tailscale up --advertise-routes=10.0.0.0/16'"
        }
        else {
            Test-Step -Name "Subnet routes advertised" -Passed $false -Detail "could not check subnet routes" -Remediation "Verify Tailscale is running and subnet routes are configured"
        }
    }
    else {
        Write-Verbose "  [SKIP] Tailscale CLI not found on host PATH."
    }

    # ==============================================================================
    # SECTION 7: BitLocker Verification (Windows only)
    # ==============================================================================
    Write-Verbose "`n[7] BitLocker Drive Encryption"

    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        try {
            $Drive = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
            if ($Drive) {
                $Encrypted = $Drive.VolumeStatus -eq "FullyEncrypted" -or $Drive.VolumeStatus -eq "EncryptionInProgress"
                Test-Step -Name "BitLocker encryption active" -Passed:([bool]$Encrypted) -Detail $Drive.VolumeStatus -Remediation "Enable BitLocker: Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes256 -UsedSpaceOnly -RecoveryPasswordProtector"
            }
            else {
                Test-Step -Name "BitLocker encryption active" -Passed $false -Detail "could not query BitLocker status" -Remediation "Run Get-BitLockerVolume -MountPoint C: manually"
            }
        }
        catch {
            Test-Step -Name "BitLocker encryption active" -Passed $false -Detail "BitLocker query failed: $($_.Exception.Message)" -Remediation "Ensure you're running on Windows with BitLocker support"
        }
    }
    else {
        Write-Verbose "  [SKIP] Not a Windows host."
    }

    # ==============================================================================
    # SUMMARY & REPORT
    # ==============================================================================
    Write-Verbose "`n========================================"
    Write-Verbose "  POST-DEPLOY CHECK SUMMARY"
    Write-Verbose "========================================`n"

    $PassCount = ($script:Results | Where-Object { $_.Passed }).Count
    $TotalCount = $script:Results.Count
    Write-Verbose "  Passed: $PassCount / $TotalCount"
    Write-Verbose "  Failed: $script:FailCount"

    if ($script:FailCount -gt 0) {
        Write-Warning "`n  Failed tests - remediation required:"
        foreach ($R in $script:Results | Where-Object { -not $_.Passed }) {
            Write-Warning "    - $($R.Name)"
            if ($R.Detail) { Write-Verbose "      Detail: $($R.Detail)" }
            if ($R.Remediation) { Write-Warning "      Fix:    $($R.Remediation)" }
        }
    }

    $ReportsDir = Get-ReportsDir
    if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null }
    $ReportPath = Join-Path $ReportsDir "startup-check-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    $ReportLines = [System.Collections.Generic.List[string]]::new()
    $ReportLines.AddRange(@(
        "# Interclaw Post-Deploy Check '$(Get-Date -Format 'o')'",
        "",
        "Stack: $StackName",
        "Total: $PassCount / $TotalCount passed",
        "Failed: $script:FailCount",
        "",
        "| Test | Result | Detail | Remediation |",
        "|------|--------|--------|-------------|"
    ))
    foreach ($R in $script:Results) {
        $Icon = if ($R.Passed) { "PASS" } else { "FAIL" }
        $ReportLines.Add("| $($R.Name) | $Icon | $($R.Detail) | $($R.Remediation) |")
    }
    $ReportLines.Add("")
    ($ReportLines -join "`n") | Write-AtomicFile -Path $ReportPath -Encoding UTF8
    Write-Verbose "`n  Report saved: $ReportPath"

    return $script:FailCount
}
