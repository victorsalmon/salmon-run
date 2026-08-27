# ==============================================================================
# Interclaw — RuntimeSmokeTest.ps1
# Source: runtime smoke test (not a Pester test — invoked manually)
# ==============================================================================
# LIVE runtime smoke test: deploys a single-agent test stack, waits for startup,
# and asserts the container stays healthy without bonjour / unhandled rejection
# crashes.  Destroys the stack after the test.
#
# Requires: INTERCLAW_RUN_INTEGRATION_TESTS=true
#           Docker Swarm active, ORCHESTRATOR:local image present.
#
# Run manually:  $env:INTERCLAW_RUN_INTEGRATION_TESTS="true"; Invoke-Pester Skills/Docker/Tests/RuntimeSmokeTest.ps1
# ==============================================================================

$HelpersPath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"

Describe "Interclaw Runtime Smoke Tests" -Tag "Integration" {

    BeforeAll {
        $script:SkipIntegration = ($env:INTERCLAW_RUN_INTEGRATION_TESTS -ne "true")

        if ($script:SkipIntegration) {
            Write-Host "Skipping runtime smoke tests. Set INTERCLAW_RUN_INTEGRATION_TESTS=true to enable."
            return
        }

        if (-not (Test-Path $HelpersPath)) {
            throw "Helpers script not found at: $HelpersPath"
        }
        . $HelpersPath

        $script:SmokeStackName = "TEST-SMOKE-$(Get-Random)"
        $script:SmokeAgent = @{
            Role        = "BASE"
            Index       = 0
            InstanceId  = "9999"
            AgentName   = "Smoke-Agent-BASE-9999"
            GatewayPort = (Get-AgentHostPort -Role BASE)
        }
        $script:SmokeProject = "SMOKE"
        $script:SmokeComposePath = Join-Path $env:TEMP "docker-compose.smoke-$($script:SmokeStackName).yml"
        $script:SmokeWaitSec = 90
    }

    AfterAll {
        if ($script:SkipIntegration) { return }

        # Tear down test stack
        if ($script:SmokeStackName) {
            Write-Host "`n[SMOKE CLEANUP] Removing test stack $($script:SmokeStackName)..." -ForegroundColor Yellow
            docker stack rm $script:SmokeStackName 2>&1 | Out-Null
            Start-Sleep -Seconds 5
        }
        if ($script:SmokeComposePath -and (Test-Path $script:SmokeComposePath)) {
            Remove-Item $script:SmokeComposePath -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Bonjour crash-loop prevention" {
        It "Deploys a single agent and stays healthy for $SmokeWaitSec seconds" {
            if ($script:SkipIntegration) { Set-ItResult -Skipped -Because "INTERCLAW_RUN_INTEGRATION_TESTS is not 'true'"; return }

            # 1. Verify image exists
            $ImageCheck = docker image inspect ORCHESTRATOR:local 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "ORCHESTRATOR:local image not found. Build it before running smoke tests."
            }

            # 2. Generate minimal compose
            Write-Host "`n[SMOKE] Generating compose for stack $($script:SmokeStackName)..." -ForegroundColor Cyan
            New-FleetCompose `
                -Agents @($script:SmokeAgent) `
                -ProjectCode $script:SmokeProject `
                -InstallTailscale 'false' -InstallDrone 'false' -InstallCodeContainers '0' `
                -OutputPath $script:SmokeComposePath -SovereigntyTier 'global'

            # 3. Create required secrets (dummy values are fine for crash-test)
            $DummySecrets = @(
                "SMOKE_VERI_aws_id",
                "SMOKE_VERI_aws_secret",
                "SMOKE_VERI_gateway_token"
            )
            foreach ($SecName in $DummySecrets) {
                $Exists = docker secret ls --filter "name=$SecName" --format "{{.Name}}" 2>$null
                if (-not $Exists) {
                    $TempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -Path $TempFile -Value "dummy" -NoNewline -Encoding UTF8
                    docker secret create $SecName $TempFile 2>&1 | Out-Null
                    Remove-Item $TempFile -Force -ErrorAction SilentlyContinue
                }
            }

            # 4. Deploy
            Write-Host "[SMOKE] Deploying stack $($script:SmokeStackName)..." -ForegroundColor Cyan
            docker stack deploy -c $script:SmokeComposePath $script:SmokeStackName 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "docker stack deploy failed for smoke test stack."
            }

            # 5. Wait for startup
            Write-Host "[SMOKE] Waiting $($script:SmokeWaitSec)s for container to start..." -ForegroundColor Cyan
            Start-Sleep -Seconds $script:SmokeWaitSec

            # 6. Find container
            $ContainerName = docker ps --filter "name=${script:SmokeStackName}_oc-base" --format "{{.Names}}" 2>$null | Select-Object -First 1
            if (-not $ContainerName) {
                # Container may have exited already — check exited containers
                $ExitedContainer = docker ps -a --filter "name=${script:SmokeStackName}_oc-base" --format "{{.Names}}" 2>$null | Select-Object -First 1
                if ($ExitedContainer) {
                    $ExitLogs = docker logs $ExitedContainer --tail 30 2>&1
                    throw "Smoke-test container exited prematurely.`nLast 30 log lines:`n$ExitLogs"
                }
                throw "Smoke-test container not found after $($script:SmokeWaitSec)s."
            }

            # 7. Assert logs do NOT contain fatal crash signatures
            $RecentLogs = docker logs $ContainerName --since 90s 2>&1
            $FatalPatterns = @(
                'Unhandled promise rejection',
                'CIAO PROBING CANCELLED',
                'FATAL',
                'process exited',
                'crash'
            )
            $FoundFatals = @()
            foreach ($Pat in $FatalPatterns) {
                if ($RecentLogs -match $Pat) {
                    $FoundFatals += $Pat
                }
            }

            if ($FoundFatals.Count -gt 0) {
                throw "Smoke-test container logs contain fatal signatures: $($FoundFatals -join ', ').`nRecent logs:`n$RecentLogs"
            }

            Write-Host "[SMOKE] Container stable — no fatal signatures detected." -ForegroundColor Green
        }

        It "Generated compose contains INTERCLAW_DISABLE_BONJOUR" {
            if ($script:SkipIntegration) { Set-ItResult -Skipped -Because "INTERCLAW_RUN_INTEGRATION_TESTS is not 'true'"; return }
            if (-not (Test-Path $script:SmokeComposePath)) {
                throw "Smoke compose not found at $script:SmokeComposePath."
            }
            $yaml = Get-Content $script:SmokeComposePath -Raw
            $yaml | Should -Match 'INTERCLAW_DISABLE_BONJOUR'
        }
    }
}
