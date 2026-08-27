#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $env:PSModulePath = "$RepoRoot\Orchestrator\Modules;${env:PSModulePath}"
    Import-Module SalmonRun.Orchestrate -Force -DisableNameChecking
}

Describe "Invoke-ReadFilesystemState" -Tag "Orchestration", "Regression" {
    It "populates StartTime as a DateTime for recovered streams" -ForEach @(
        @{ Role = 'coder' },
        @{ Role = 'reviewer' }
    ) {
        $tempDir = Join-Path $env:TEMP "OrchestrateStateTest_$(Get-Random)"
        $workingDir = Join-Path $tempDir "Tasks\Working\lane-test-1"
        $null = New-Item -ItemType Directory -Path $workingDir -Force

        @{
            Id        = "test-agent-1"
            Namespace = "test-namespace"
            Role      = $_.Role
            Module    = "main"
            Created   = (Get-Date -Format 'o')
        } | ConvertTo-Json | Set-Content -Path (Join-Path $workingDir "stream.json") -Encoding utf8

        # Required so the function thinks a plan is still in flight
        "# test plan" | Set-Content -Path (Join-Path $workingDir "test-plan.md") -Encoding utf8

        Mock Test-AgentAlive -ModuleName SalmonRun.Orchestrate {
            @{ ProcessAlive = $false; HasHeartbeat = $false; HeartbeatStale = $true }
        }

        $result = InModuleScope SalmonRun.Orchestrate -Parameters @{ InterclawDir = $tempDir } {
            param($InterclawDir)
            Invoke-ReadFilesystemState -InterclawDir $InterclawDir
        }

        $result.activeStreams.Count | Should -Be 1
        $stream = $result.activeStreams.Values | Select-Object -First 1
        $stream.StartTime | Should -BeOfType [datetime]
        $stream.Status | Should -Be 'recovered'

        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
