#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Modules'
    $__DockerModulesDir = Join-Path $__RepoRoot 'Modules'

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    $sep = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }
    $env:PSModulePath = ($__ModulesDir, $__DockerModulesDir, $env:PSModulePath) -join $sep

    # Direct all runtime state created by PlanLog to the Pester TestDrive.
    $env:SALMON_RUN_HOME = $TestDrive

    Remove-Module 'SalmonRun.PondEngine', 'SalmonRun.Paths', 'SalmonRun.Constants' -Force -ErrorAction SilentlyContinue

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop
}

Describe 'Get-PlanPondLog' -Tag 'PlanLog' {
    BeforeEach {
        $script:TestPlan = Join-Path $TestDrive 'test-plan.md'
        Copy-Item -Path (Join-Path $__RepoRoot 'dot-salmon.example' 'plan-template.md') -Destination $script:TestPlan
    }

    It 'returns an empty list when no PondLog section exists' {
        $plan = Join-Path $TestDrive 'empty-plan.md'
        '# Empty plan' | Set-Content -Path $plan
        $result = Get-PlanPondLog -PlanPath $plan
        $result | Should -BeNullOrEmpty
    }

    It 'returns an empty list when the PondLog section is empty' {
        $result = Get-PlanPondLog -PlanPath $script:TestPlan
        $result | Should -BeNullOrEmpty
    }

    It 'parses PondLog entries from a plan' {
        @'
**PondLog**
```json
[
  {
    "ts": "2026-08-27T12:00:00Z",
    "pond": "Code",
    "role": "coder",
    "action": "implement",
    "detail": "completed",
    "agent": "local-001"
  }
]
```
'@ | Set-Content -Path $script:TestPlan

        $result = Get-PlanPondLog -PlanPath $script:TestPlan
        $result | Should -HaveCount 1
        $result[0].ts | Should -BeOfType [datetime]
        $result[0].ts.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-08-27T12:00:00Z'
        $result[0].pond | Should -Be 'Code'
        $result[0].action | Should -Be 'implement'
    }
}

Describe 'Add-PlanPondLog' -Tag 'PlanLog' {
    BeforeEach {
        $script:TestPlan = Join-Path $TestDrive 'test-plan.md'
        Copy-Item -Path (Join-Path $__RepoRoot 'dot-salmon.example' 'plan-template.md') -Destination $script:TestPlan
    }

    It 'appends a PondLog entry to a plan' {
        Add-PlanPondLog -PlanPath $script:TestPlan -Entry @{
            pond = 'Code'
            role = 'coder'
            action = 'implement'
            detail = 'completed by public local executor'
            agent = 'local-001'
        }

        $result = Get-PlanPondLog -PlanPath $script:TestPlan
        $result | Should -HaveCount 1
        $result[0].action | Should -Be 'implement'
        $result[0].pond | Should -Be 'Code'
        $result[0].agent | Should -Be 'local-001'
        $result[0].ts | Should -Not -BeNullOrEmpty
    }

    It 'appends a default timestamp if none is provided' {
        $before = [datetime]::UtcNow
        Add-PlanPondLog -PlanPath $script:TestPlan -Entry @{
            pond = 'Code'
            role = 'coder'
            action = 'lock'
        }
        $after = [datetime]::UtcNow

        $result = Get-PlanPondLog -PlanPath $script:TestPlan
        $result[0].ts | Should -BeOfType [datetime]
        $result[0].ts.ToUniversalTime() | Should -BeGreaterOrEqual $before
        $result[0].ts.ToUniversalTime() | Should -BeLessOrEqual $after
    }

    It 'rejects an unknown action' {
        { Add-PlanPondLog -PlanPath $script:TestPlan -Entry @{
            pond = 'Code'
            role = 'coder'
            action = 'dance'
        } } | Should -Throw
    }

    It 'preserves the plan body and existing PondLog entries' {
        Add-PlanPondLog -PlanPath $script:TestPlan -Entry @{ pond = 'Code'; role = 'coder'; action = 'implement' }
        Add-PlanPondLog -PlanPath $script:TestPlan -Entry @{ pond = 'Review'; role = 'reviewer'; action = 'review' }

        $content = Get-Content -Path $script:TestPlan -Raw
        $content | Should -Match '## Overview'
        $content | Should -Match '## Task 1'

        $result = Get-PlanPondLog -PlanPath $script:TestPlan
        $result | Should -HaveCount 2
        $result[0].action | Should -Be 'implement'
        $result[1].action | Should -Be 'review'
    }

    It 'does not lose entries under concurrent append' -Tag 'Concurrency' {
        $plan = Join-Path $TestDrive 'concurrent-plan.md'
        Copy-Item -Path (Join-Path $__RepoRoot 'dot-salmon.example' 'plan-template.md') -Destination $plan

        $count = 20
        $jobs = 1..2 | ForEach-Object {
            $i = $_
            Start-Job -ScriptBlock {
                param($p, $c, $i)
                1..$c | ForEach-Object {
                    Add-PlanPondLog -PlanPath $p -Entry @{
                        pond = 'Code'
                        role = 'coder'
                        action = 'implement'
                        agent = "agent-$i-$_"
                    } -ErrorAction Stop
                }
            } -ArgumentList $plan, $count, $i
        }

        $null = Receive-Job -Job $jobs -Wait -AutoRemoveJob

        $result = Get-PlanPondLog -PlanPath $plan
        $result | Should -HaveCount ($count * 2)

        $agents = $result | ForEach-Object { $_.agent }
        ($agents | Select-Object -Unique).Count | Should -Be ($count * 2)
    }
}

Describe 'Plan metadata schema' -Tag 'PlanLog' {
    It 'loads the schema and contains expected routing headers and actions' {
        $schema = Get-SalmonRunPlanSchema
        $schema.routingHeaders.Status | Should -Not -BeNullOrEmpty
        $schema.pondLogActions.implement | Should -Not -BeNullOrEmpty
        $schema.pondLogActions.review | Should -Not -BeNullOrEmpty
        $schema.pondLogActions.audit | Should -Not -BeNullOrEmpty
        $schema.pondLogActions.qa | Should -Not -BeNullOrEmpty
    }
}
