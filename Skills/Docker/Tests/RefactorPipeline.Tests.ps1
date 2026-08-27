#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = Resolve-Path "$PSScriptRoot/../../.."
    $script:PipelineScript = Join-Path $RepoRoot "Skills/Refactor/Invoke-RefactorPipeline.ps1"

    $script:TestDir = Join-Path $env:TEMP "Interclaw-RefactorPipeline-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

AfterAll {
    Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "RefactorPipeline" -Tag "RefactorPipeline" {

    It "script file exists" {
        Test-Path $script:PipelineScript | Should -BeTrue
    }

    It "has valid PowerShell syntax" {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:PipelineScript, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It "DryRun exits 0 and logs prerequisites" {
        $outFile = Join-Path $script:TestDir "dryrun.log"
        $proc = Start-Process -NoNewWindow -FilePath "pwsh" `
            -ArgumentList @('-NoProfile', '-File', $script:PipelineScript, '-DryRun') `
            -Wait -PassThru -RedirectStandardOutput $outFile
        $proc.ExitCode | Should -Be 0
        $output = Get-Content $outFile -Raw
        $output | Should -Match "REFACTOR PIPELINE START"
        $output | Should -Match "DRY RUN"
    }

    It "prerequisites check detects missing opencode" {
        $savedPath = $env:PATH
        try {
            $env:PATH = $script:TestDir
            $outFile = Join-Path $script:TestDir "prereq-fail.log"
            $proc = Start-Process -NoNewWindow -FilePath "pwsh" `
                -ArgumentList @('-NoProfile', '-File', $script:PipelineScript, '-DryRun') `
                -Wait -PassThru -RedirectStandardOutput $outFile
            $proc.ExitCode | Should -Be 0
            $output = Get-Content $outFile -Raw
            $output | Should -Match "FAIL"
        } finally {
            $env:PATH = $savedPath
        }
    }

    It "command templates all exist in opencode.json" {
        $config = Get-Content (Join-Path $RepoRoot "opencode.json") -Raw | ConvertFrom-Json
        $config.command.'audit-complete' | Should -Not -BeNullOrEmpty
        $config.command.'runfix' | Should -Not -BeNullOrEmpty
        $config.command.'refactor-pipeline' | Should -Not -BeNullOrEmpty
        $config.command.'refactor' | Should -Not -BeNullOrEmpty
    }

    It "RunFix specialization file exists" {
        $spec = Join-Path $RepoRoot "Skills/Workflows/RunFix/runfix-refactor-pipeline.md"
        Test-Path $spec | Should -BeTrue
    }

    It "RunFix audit-complete goals file exists" {
        $spec = Join-Path $RepoRoot "Skills/Workflows/RunFix/runfix-audit-complete.md"
        Test-Path $spec | Should -BeTrue
    }

    It "Phase 1 uses runfix audit-complete, not direct audit command" {
        $content = Get-Content $script:PipelineScript -Raw
        $phase1Content = $content -split "(?=function Invoke-Phase1)" | Select-Object -Last 1
        $phase1Content = $phase1Content -split "(?=function Invoke-Phase2)" | Select-Object -First 1
        $phase1Content | Should -Match "runfix.*audit-complete"
        $phase1Content | Should -Not -Match "audit-arch"
    }

    It "Phase 2 uses runfix localorchestrator, not watchdog" {
        $content = Get-Content $script:PipelineScript -Raw
        $phase2Content = $content -split "(?=function Invoke-Phase2)" | Select-Object -Last 1
        $phase2Content = $phase2Content -split "(?=function Invoke-Phase3)" | Select-Object -First 1
        $phase2Content | Should -Match "runfix.*localorchestrator"
        $phase2Content | Should -Not -Match "Invoke-Orchestrate\.ps1.*-DetachWatchdog"
        $phase2Content | Should -Not -Match "WDog="
        $phase2Content | Should -Not -Match "\.orchestrate-watchdog-pid"
    }

    It "Phase 3 uses runfix deploy.ps1" {
        $content = Get-Content $script:PipelineScript -Raw
        $phase3Content = $content -split "(?=function Invoke-Phase3)" | Select-Object -Last 1
        $phase3Content = $phase3Content -split "(?=function Invoke-Phase4)" | Select-Object -First 1
        $phase3Content | Should -Match "runfix.*deploy.ps1"
    }

    It "Phase 4 catchall function exists with fix-and-re-run logic" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Match "function Invoke-Phase4"
        $content | Should -Match "CATCHALL: All checks passed"
        $content | Should -Match "RESCUE.*Tasks/Code"
    }

    It "Pipeline has catchall loop (max 5 iterations)" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Match "MaxCatchallIterations"
        $content | Should -Match "CATCHALL_ITERATIONS_EXCEEDED"
    }

    It "resume from Phase 2 skips Phase 1 output" {
        $outFile = Join-Path $script:TestDir "resume.log"
        $proc = Start-Process -NoNewWindow -FilePath "pwsh" `
            -ArgumentList @('-NoProfile', '-File', $script:PipelineScript, '-DryRun', '-ResumeFromPhase', '2') `
            -Wait -PassThru -RedirectStandardOutput $outFile
        $proc.ExitCode | Should -Be 0
        $output = Get-Content $outFile -Raw
        $output | Should -Match "Phase 2"
        $output | Should -Not -Match "Phase 1:"
    }

    It "RunFix refactor error table references audit-complete, not orchestrator-pid" {
        $spec = Join-Path $RepoRoot "Skills/Workflows/RunFix/runfix-refactor-pipeline.md"
        $content = Get-Content $spec -Raw
        $content | Should -Match "audit-complete"
        $content | Should -Match "localorchestrator"
        $content | Should -Match "CATCHALL_ITERATIONS_EXCEEDED"
    }

    It "no watchdog polling or detach-chain in pipeline" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Not -Match "Invoke-Orchestrate\.ps1.*-DetachWatchdog"
        $content | Should -Not -Match "LocalOrchestrator\.ps1.*-Detach"
        $content | Should -Not -Match "WDog="
        $content | Should -Not -Match "Orch="
        $content | Should -Not -Match "emptyConfirmations"
        $content | Should -Not -Match "wdAlive"
    }

    It "script has Invoke-OpencodeCommand with ExtraArgs" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Match "ExtraArgs"
    }

    It "no --port references in pipeline (temp server approach removed)" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Not -Match "--port"
    }

    It "no skip-no-server references in pipeline" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Not -Match "skip-no-server"
    }

    It "Phase 4 failure logic catches iteration exceeded" {
        $content = Get-Content $script:PipelineScript -Raw
        $content | Should -Match "CATCHALL_ITERATIONS_EXCEEDED"
    }
}
