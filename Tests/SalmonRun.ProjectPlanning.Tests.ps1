#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Project planning workload contract' -Tag 'PondEngine','Regression-Only' {
    It 'exports a concept-to-project-plan command' {
        $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
        $manifest = Import-PowerShellDataFile (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1')
        $manifest.FunctionsToExport | Should -Contain 'New-SalmonProjectPlan'
    }

    It 'prints a structured project plan from a concept' {
        $runtimeRoot = Join-Path $TestDrive 'concept-home'
        $result = New-SalmonProjectPlan -Concept 'Build a reliable invoice importer with validation and operator reporting.' -ProjectId 'invoice-importer' -TaskRoot (Join-Path $runtimeRoot 'Tasks')
        $result | Should -Exist
        $result | Should -BeLike "*Tasks*Project*"
        $content = Get-Content -LiteralPath $result -Raw
        $content | Should -Match '(?im)^\*\*ProjectId\*\*: invoice-importer$'
        $content | Should -Match '(?im)^## Session Plans$'
        $content | Should -Match '(?im)^\*\*EstimatedImplementationTokens\*\*: \d+$'
    }

    It 'decomposes plans into substantive children below the hard token ceiling' {
        $taskRoot = Join-Path $TestDrive 'Tasks'
        $lane = Join-Path $taskRoot 'Working/lane-project'
        New-Item -ItemType Directory -Path $lane -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force | Out-Null
        @'
# Project Plan: importer
**Status**: ready
**Scope**: invoice importer
**ProjectId**: invoice-importer
**Children**: ingest, validate
**SessionTargetTokens**: 200000
## Concept
Build a reliable invoice importer with validation and operator reporting.
'@ | Set-Content -LiteralPath (Join-Path $lane '2026-08-28-invoice-importer.md') -NoNewline

        $pond = Get-SalmonRunPonds | Where-Object Name -eq Project
        $group = [PondGroup]::new()
        $group.Namespace = 'invoice-importer'
        $group.StreamPath = $lane
        $context = [PondContext]::new()
        $context.TaskRoot = $taskRoot
        $context.CurrentGroup = $group
        $task = $pond.Tasks | Where-Object Name -eq PlanProject

        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskPlanProject -Pond $p -Task $t -Context $c } $pond $task $context | Out-Null
        $children = @(Get-ChildItem (Join-Path $taskRoot 'Code') -Filter '*.md')
        $children | Should -HaveCount 2
        foreach ($child in $children) {
            $content = Get-Content -LiteralPath $child.FullName -Raw
            $content | Should -Match '(?im)^## Outcome$'
            $content | Should -Match '(?im)^## Acceptance Criteria$'
            $content | Should -Match '(?im)^## Verification$'
            $estimate = [int]([regex]::Match($content, '(?im)^\*\*EstimatedImplementationTokens\*\*:\s*(\d+)').Groups[1].Value)
            $estimate | Should -BeGreaterThan 0
            $estimate | Should -BeLessOrEqual 100000
        }
    }
}
