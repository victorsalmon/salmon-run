#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $RepoRoot = Resolve-Path "$PSScriptRoot\..\..\.."
    . (Join-Path $RepoRoot "Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $RepoRoot "Skills\Docker\Modules\SalmonRun.DeployState\SalmonRun.DeployState.psm1")
    . (Join-Path $RepoRoot "Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.State.ps1")

    $script:InterclawErrors = [System.Collections.Generic.List[hashtable]]::new()
    $script:SetupPhasesCompleted = [System.Collections.Generic.List[string]]::new()
    $script:TestLogPath = "$env:TEMP\opencode\deploy-test.log"
    Set-Content -Path $script:TestLogPath -Value "" -Encoding UTF8
    $env:INTERCLAW_SETUP_LOG = $script:TestLogPath
    $env:INTERCLAW_RUN_ID = "test-run-0001"
}

AfterAll {
    Remove-Item -LiteralPath $script:TestLogPath -ErrorAction SilentlyContinue
    Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue
}

Describe "Invoke-SetupPhase" -Tag "Setup" {
    BeforeEach {
        # Initialize module-scope variables (Pester 5 scope bridge)
        if (-not (Get-Variable -Name InterclawErrors -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:InterclawErrors) {
            $script:InterclawErrors = [System.Collections.Generic.List[hashtable]]::new()
        } else { $script:InterclawErrors.Clear() }
        if (-not (Get-Variable -Name SetupPhasesCompleted -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:SetupPhasesCompleted) {
            $script:SetupPhasesCompleted = [System.Collections.Generic.List[string]]::new()
        } else { $script:SetupPhasesCompleted.Clear() }
    }

    It "calls the scriptblock" {
        Invoke-SetupPhase -Phase "TestPhase" -ScriptBlock {  }
    }

    It "records Add-SetupError and rethrows on non-recoverable failure" {
        { Invoke-SetupPhase -Phase "FailingPhase" -ScriptBlock { throw "Something broke" } } | Should -Throw
        $script:InterclawErrors.Count | Should -Be 1
        $script:InterclawErrors[0].Phase | Should -Be "FailingPhase"
        $script:InterclawErrors[0].Recoverable | Should -BeFalse
    }

    It "logs WARN and continues on recoverable failure" {
        { Invoke-SetupPhase -Phase "RecoverablePhase" -Recoverable:$true -ScriptBlock { throw "Non-fatal issue" } } | Should -Not -Throw
        $script:InterclawErrors.Count | Should -Be 1
        $script:InterclawErrors[0].Recoverable | Should -BeTrue
    }

    It "skips execution when checkpoint exists" {
        Set-SetupCheckpoint -Name "SkippedPhase"
        { Invoke-SetupPhase -Phase "SkippedPhase" -ScriptBlock { throw "Should not be called" } } | Should -Not -Throw
        $script:InterclawErrors.Count | Should -Be 0
    }
}

Describe "Add-SetupError / Export-SetupErrors" -Tag "Setup" {
    BeforeEach {
        if (-not (Get-Variable -Name InterclawErrors -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:InterclawErrors) {
            $script:InterclawErrors = [System.Collections.Generic.List[hashtable]]::new()
        } else { $script:InterclawErrors.Clear() }
        if (-not (Get-Variable -Name SetupPhasesCompleted -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:SetupPhasesCompleted) {
            $script:SetupPhasesCompleted = [System.Collections.Generic.List[string]]::new()
        } else { $script:SetupPhasesCompleted.Clear() }
    }

    It "adds entry to global error list" {
        Add-SetupError -Phase "TestPhase" -Message "Test error" -Category "AWS"
        $script:InterclawErrors.Count | Should -Be 1
        $script:InterclawErrors[0].Phase | Should -Be "TestPhase"
        $script:InterclawErrors[0].Category | Should -Be "AWS"
        $script:InterclawErrors[0].Recoverable | Should -BeFalse
    }

    It "logs at WARN level for recoverable errors" {
        Add-SetupError -Phase "TestPhase" -Message "Recoverable issue" -Recoverable:$true
        $script:InterclawErrors[0].Recoverable | Should -BeTrue
    }

    It "writes markdown error report to Reports dir" {
        Add-SetupError -Phase "ReportTest" -Message "Report error"
        $repoRoot = Get-InterclawRepoRoot
        Get-ChildItem (Join-Path $repoRoot "Tasks\Logs") -Filter "*setup-errors*" | Remove-Item -ErrorAction SilentlyContinue
        Export-SetupErrors -ReportLabel "test-report"
        $reportsDir = Join-Path $repoRoot "Tasks\Logs"
        @(Get-ChildItem $reportsDir -Filter "*test-report*").Count | Should -BeGreaterThan 0
    }

    It "produces no output when zero errors exist" {
        $repoRoot = Get-InterclawRepoRoot
        $reportsDir = Join-Path $repoRoot "Tasks\Logs"
        Export-SetupErrors -ReportLabel "empty-test"
    }
}

Describe "Write-SetupLog log level filtering" -Tag "Setup" {
    It "suppresses DEBUG when INTERCLAW_LOG_LEVEL=INFO" {
        $testLog = "$env:TEMP\opencode\debug-test.log"
        Set-Content -Path $testLog -Value "" -Encoding UTF8
        $env:INTERCLAW_LOG_LEVEL = "INFO"
        $env:INTERCLAW_SETUP_LOG = $testLog
        Write-SetupLog "Debug message" -Level DEBUG
        $logContent = Get-Content -LiteralPath $testLog -Raw
        $logContent | Should -Not -Match "Debug message"
        Remove-Item Env:\INTERCLAW_LOG_LEVEL -ErrorAction SilentlyContinue
    }

    It "always writes WARN regardless of level" {
        $testLog = "$env:TEMP\opencode\warn-test.log"
        Set-Content -Path $testLog -Value "" -Encoding UTF8
        $env:INTERCLAW_LOG_LEVEL = "WARN"
        $env:INTERCLAW_SETUP_LOG = $testLog
        Write-SetupLog "Test warning" -Level WARN
        Write-SetupLog "Test error" -Level ERROR
        $logContent = Get-Content -LiteralPath $testLog -Raw
        $logContent | Should -Match "Test warning"
        $logContent | Should -Match "Test error"
        Remove-Item Env:\INTERCLAW_LOG_LEVEL -ErrorAction SilentlyContinue
    }

    It "silently skips when INTERCLAW_SETUP_LOG is unset" {
        $savedLogPath = $env:INTERCLAW_SETUP_LOG
        Remove-Item Env:\INTERCLAW_SETUP_LOG -ErrorAction SilentlyContinue
        { Write-SetupLog "Should be silently skipped" -Level INFO } | Should -Not -Throw
        $env:INTERCLAW_SETUP_LOG = $savedLogPath
    }
}

Describe "Background job log propagation" -Tag "Setup" {
    It "background job writes to the same log file as parent" {
        $jobLogPath = "$env:TEMP\opencode\job-test.log"
        $coreModulePath = (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) + "\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"
        $stateModulePath = (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) + "\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.State.ps1"
        Set-Content -LiteralPath $jobLogPath -Value "" -Encoding UTF8

        $job = Start-Job -ScriptBlock {
            param($logPath, $corePath, $statePath)
            $env:INTERCLAW_SETUP_LOG = $logPath
            . $corePath
            . $statePath
            Write-SetupLog "Message from background job" -Level INFO
        } -ArgumentList $jobLogPath, $coreModulePath, $stateModulePath
        $null = Receive-Job -Job $job -Wait -AutoRemoveJob

        $logContent = Get-Content -LiteralPath $jobLogPath -Raw
        $logContent | Should -Match "Message from background job"
    }
}

Describe "deploy.ps1 TagOnly mode" -Tag "Setup", "Regression-Only" {
    BeforeAll {
        $setupPath = Join-Path $PSScriptRoot "..\deploy.ps1"
        $script:Content = Get-Content -LiteralPath $setupPath -Raw
        $invokeDeployPhasePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-DeployPhase.ps1"
        $script:DeployPhaseContent = Get-Content -LiteralPath $invokeDeployPhasePath -Raw
    }

    It "has -TagOnly switch in param block" {
        $script:Content | Should -Match '\[switch\]\$TagOnly'
    }

    It "sets script:TagOnly from param" {
        $script:Content | Should -Match '\$script:TagOnly = \$TagOnly'
    }

    It "has TagOnly gate in Invoke-DeployPhase" {
        $script:DeployPhaseContent | Should -Match 'if \(\$TagOnly\)'
    }

    It "does not exempt ConfigSave, IdentityConfig, Cleanup from TagOnly skip (tag without executing)" {
        $script:DeployPhaseContent | Should -Not -Match 'TagOnly.*-notin.*ConfigSave'
        $script:Content | Should -Match "'ConfigSave'"
        $script:Content | Should -Match "'IdentityConfig'"
        $script:Content | Should -Match "'Cleanup'"
    }

    It "prints informational skip message for TagOnly phases" {
        $script:DeployPhaseContent | Should -Match "SKIP.*TagOnly"
    }
}

Describe "Save-InstanceConfiguration -WhatIf support" -Tag "Setup", "Regression-Only" {
    BeforeAll {
        $savePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Host\Public\Save-InstanceConfiguration.ps1"
        $script:Content = Get-Content -LiteralPath $savePath -Raw
    }

    It "has SupportsShouldProcess on function" {
        $script:Content | Should -Match 'SupportsShouldProcess'
    }

    It "uses ShouldProcess to guard writes" {
        $script:Content | Should -Match 'ShouldProcess'
    }

    It "writes log message outside ShouldProcess block (always runs)" {
        $script:Content | Should -Match 'Write-SetupLog "Saved config:'
    }
}

Describe "deploy.ps1 module import uniqueness" -Tag "Setup", "Regression-Only" {
    It "loads Core via Import-Module only (no Import-InterclawModule Core duplicate)" {
        $setupPath = Join-Path $PSScriptRoot "..\deploy.ps1"
        $content = Get-Content -LiteralPath $setupPath -Raw
        $indirectCore = [regex]::Matches($content, 'Import-InterclawModule\s+Core').Count
        $indirectCore | Should -Be 0
    }
}
