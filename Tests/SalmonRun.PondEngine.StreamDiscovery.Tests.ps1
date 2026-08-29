#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

# Red/green 4C reproduction for the orchestrator stream-discovery bug that
# prevented Intake, ProjectReview, and standalone QA plans from being dispatched.

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Modules'

    $env:PSModulePath = "$__ModulesDir$([System.IO.Path]::PathSeparator)$env:PSModulePath"

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    Remove-Module 'SalmonRun.PondEngine', 'SalmonRun.Paths', 'SalmonRun.Constants', 'SalmonRun.Core', 'SalmonRun.AgentLifecycle' -Force -ErrorAction SilentlyContinue

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop

    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = Join-Path $TestDrive 'salmon-home'
    $null = New-Item -ItemType Directory -Path $env:SALMON_RUN_HOME -Force

    # Build two temp git "target" repos so worktree stream discovery has something
    # to map to.  The salmon repo stands in for the salmon-run package; the
    # upscale repo stands in for the external uh/currents target.
    $script:FakeSalmonRepo = Join-Path $TestDrive 'fake-salmon'
    $script:FakeUpscaleRepo = Join-Path $TestDrive 'fake-upscale'
    foreach ($r in @($script:FakeSalmonRepo, $script:FakeUpscaleRepo)) {
        $null = New-Item -ItemType Directory -Path $r -Force
        $null = & git -C $r init -q 2>&1
    }

    $script:TestTaskRoot = Join-Path $env:SALMON_RUN_HOME 'Tasks'
    foreach ($q in @('Intake','ProjectReview','QA','Code','Review','Audit','Complete')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:TestTaskRoot $q) -Force
    }

    $script:ConfigPath = Join-Path $env:SALMON_RUN_HOME 'orchestrator.config.json'
    @{
        namespaceRepoMap = @{
            'smoke-test'      = $script:FakeSalmonRepo
            'salmon'          = $script:FakeSalmonRepo
            'upscale-havens'  = $script:FakeUpscaleRepo
            'uh'              = $script:FakeUpscaleRepo
        }
    } | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8

    # Place realistic plan files in the queues that currently cause POND_NO_STREAM.
    $planHeader = @{
        'Intake'        = @'
# Smoke test plan

**Status**: ready
**Scope**: Verify that the stream discovery path finds Intake plans.

## Overview
This is a minimal intake plan that should get a dedicated salmon-run worktree stream.
'@
        'ProjectReview' = @'
# Project review plan

**Status**: ready
**Scope**: Review child completions for the upscale-havens project.

## Overview
ProjectReview plans must be able to resolve a target-repo stream from their queue.
'@
        'QA'            = @'
# QA plan

**Status**: ready
**Scope**: Run property and mutation tests for the uh-signing plan.

## Overview
Standalone QA plans have no **ProjectId** header.  They must still group by their
connascence namespace (uh-signing) so a matching worktree stream is found.
'@
        'Code'          = @'
# Coder dependency sibling

**Status**: blocked
**Scope**: A sibling plan that keeps the uh-signing worktree stream discoverable.

## Overview
This file is only present so Get-PondWorktreeStreams sees the uh-signing namespace.
'@
    }

    Set-Content -LiteralPath (Join-Path $script:TestTaskRoot 'Intake'        '2026-08-26-smoke-test-1.md')                    -Value $planHeader['Intake']        -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:TestTaskRoot 'ProjectReview' '2026-08-26-upscale-havens-100.md')                -Value $planHeader['ProjectReview'] -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:TestTaskRoot 'QA'            '2026.08.26-uh-signing-1-pkcs7-tamper-evidence.md') -Value $planHeader['QA']            -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:TestTaskRoot 'Code'          '2026.08.26-uh-signing-2-retry-repair-flow.md')      -Value $planHeader['Code']          -Encoding utf8
}

AfterAll {
    $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome
}

Describe 'PondEngine stream discovery and ProjectId fallback' -Tag 'PondEngine', 'StreamDiscovery' {
    It 'discovers worktree streams for Intake and ProjectReview queues' {
        InModuleScope -ModuleName 'SalmonRun.PondEngine' -ScriptBlock {
            param($TaskRoot, $RepoDir, $ConfigPath)
            $streams = @(Get-PondWorktreeStreams -TaskRoot $TaskRoot -RepoDir $RepoDir -ConfigPath $ConfigPath)
            $ids = $streams | Select-Object -ExpandProperty Id
            $ids | Should -Contain 'smoke-test' -Because 'Intake plans need a stream to spawn'
            $ids | Should -Contain 'upscale-havens' -Because 'ProjectReview plans need a stream to spawn'
            $ids | Should -Contain 'uh-signing' -Because 'QA and Code plans sharing a namespace produce one stream'
        } -ArgumentList $script:TestTaskRoot, $script:FakeSalmonRepo, $script:ConfigPath
    }

    It 'falls back to the connascence namespace when a QA plan has no ProjectId' {
        InModuleScope -ModuleName 'SalmonRun.PondEngine' -ScriptBlock {
            param($TaskRoot, $ConfigPath)

            $ponds = Get-SalmonRunPonds
            $qaPond = $ponds | Where-Object { $_.Name -eq 'QA' } | Select-Object -First 1

            $qaFile = Get-Item (Join-Path $TaskRoot 'QA' '2026.08.26-uh-signing-1-pkcs7-tamper-evidence.md')
            $context = [PondContext]::new()
            $context.TaskRoot = $TaskRoot
            $context.Config = [PSCustomObject]@{ NamespaceRepoMap = @{} }

            $groups = @(Group-PondFiles -Pond $qaPond -Files @($qaFile) -Context $context)
            $groups.Count | Should -Be 1
            $groups[0].Namespace | Should -Be 'uh-signing' -Because 'the standalone QA plan should group by connascence namespace, not its full filename'
        } -ArgumentList $script:TestTaskRoot, $script:ConfigPath
    }

    It 'canonicalizes an existing relative TargetRepo before constructing a stream' {
        $relativeRepo = Join-Path $TestDrive 'relative-target'
        $null = New-Item -ItemType Directory -Path $relativeRepo -Force
        $null = & git -C $relativeRepo init -q 2>&1
        $plan = Join-Path $TestDrive 'relative-plan.md'
        "# Plan`n**TargetRepo**: relative-target`n**Status**: ready`n**Scope**: test" | Set-Content -LiteralPath $plan -Encoding utf8

        Push-Location $TestDrive
        try {
            InModuleScope -ModuleName 'SalmonRun.PondEngine' -ScriptBlock {
                param($Plan, $FallbackRepo, $ExpectedRepo)
                $group = [PondGroup]::new()
                $group.Namespace = 'currents-ui'
                $group.Files = @(Get-Item -LiteralPath $Plan)
                $context = [PondContext]::new()
                $context.RepoDir = $FallbackRepo
                $context.Config = [pscustomobject]@{ NamespaceRepoMap = @{ currents = $ExpectedRepo } }
                Resolve-PondGroupRepo -Group $group -Context $context
                [IO.Path]::IsPathRooted($group.RepoPath) | Should -BeTrue
                $group.RepoPath | Should -Be ([IO.Path]::GetFullPath($ExpectedRepo))
            } -ArgumentList $plan, $script:FakeSalmonRepo, $relativeRepo
        } finally { Pop-Location }
    }
}

