#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Resolve-Path "$PSScriptRoot/../../.."
    $script:FixPath = Join-Path $script:RepoRoot "Orchestrator/Orchestration/Invoke-FixOrchestrator.ps1"
}

Describe "Invoke-FixOrchestrator resilience" -Tag "Orchestration", "Regression" {
    It "handles an empty watchdog PID file during a forced recovery cycle" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "fix-orchestrator-null-pid-$([guid]::NewGuid().ToString('N'))"
        $logs = Join-Path $tempRoot 'Tasks\Logs'
        $null = New-Item -ItemType Directory -Path $logs -Force
        [System.IO.File]::WriteAllText((Join-Path $logs '.orchestrate-watchdog-pid'), '')

        try {
            . $script:FixPath
            $health = Get-WatchdogRuntimeHealth -Root $tempRoot

            $health.ProcessAlive | Should -BeFalse
            $health.Pid | Should -BeNullOrEmpty
            $health.Reason | Should -Be 'missing-or-invalid-pid'
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "classifies every non-positive or malformed watchdog PID as invalid" {
        . $script:FixPath
        $cases = @('', '   ', 'not-a-pid', '0', '-4')

        foreach ($content in $cases) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "fix-orchestrator-invalid-pid-$([guid]::NewGuid().ToString('N'))"
            $logs = Join-Path $tempRoot 'Tasks\Logs'
            $null = New-Item -ItemType Directory -Path $logs -Force
            [System.IO.File]::WriteAllText((Join-Path $logs '.orchestrate-watchdog-pid'), $content)

            try {
                $health = Get-WatchdogRuntimeHealth -Root $tempRoot
                $health.ProcessAlive | Should -BeFalse
                $health.Pid | Should -BeNullOrEmpty
                $health.Reason | Should -Be 'missing-or-invalid-pid'
            }
            finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
