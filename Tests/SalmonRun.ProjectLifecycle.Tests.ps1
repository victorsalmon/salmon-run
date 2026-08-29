#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Project QA batching and completion' -Tag 'PondEngine','Regression-Only' {
    It 'groups QA by project and waits for the complete project batch' {
        $qa = Get-SalmonRunPonds | Where-Object Name -eq QA
        $qa.GroupBy | Should -Be 'ProjectId'
        $qa.Entry.EvidenceGate | Should -Be 'project-qa-ready'
        $qa.Operators.MaxFilesPerGroup | Should -BeGreaterOrEqual 100
    }

    It 'holds an incomplete project batch until every declared child reaches QA' {
        $taskRoot = Join-Path $TestDrive 'batch/Tasks'
        foreach ($dir in 'QA','ProjectReview') { New-Item -ItemType Directory -Path (Join-Path $taskRoot $dir) -Force | Out-Null }
        "# Project`n**ProjectId**: batch-one`n**DependsOn**: child-a, child-b" | Set-Content (Join-Path $taskRoot 'ProjectReview/parent.md') -NoNewline
        $ready = "# Child`n**Status**: ready`n**Scope**: test`n**ProjectId**: batch-one`n**Implementation**: completed`n**Reviewed**: passed`n**Audit**: passed"
        $ready | Set-Content (Join-Path $taskRoot 'QA/child-a.md') -NoNewline
        $qa = Get-SalmonRunPonds | Where-Object Name -eq QA
        $context = [PondContext]::new(); $context.TaskRoot=$taskRoot
        @(& (Get-Module SalmonRun.PondEngine) { param($p,$c) Get-PondCandidates -Pond $p -Context $c } $qa $context) | Should -HaveCount 0
        $ready | Set-Content (Join-Path $taskRoot 'QA/child-b.md') -NoNewline
        @(& (Get-Module SalmonRun.PondEngine) { param($p,$c) Get-PondCandidates -Pond $p -Context $c } $qa $context) | Should -HaveCount 2
    }

    It 'bundles final project evidence beneath Complete project id' {
        $taskRoot = Join-Path $TestDrive 'Tasks'
        foreach ($dir in 'Complete','ProjectReview','Feedback','QA') {
            New-Item -ItemType Directory -Path (Join-Path $taskRoot $dir) -Force | Out-Null
        }
        $parent = Join-Path $taskRoot 'ProjectReview/2026-08-28-invoice-importer.md'
        "# Project`n**ProjectId**: invoice-importer`n**Status**: ready`n**DependsOn**: child-a" | Set-Content $parent -NoNewline
        "# Child`n**ProjectId**: invoice-importer`n**Status**: complete" | Set-Content (Join-Path $taskRoot 'Complete/child-a.md') -NoNewline
        "review evidence" | Set-Content (Join-Path $taskRoot 'Feedback/child-a-review.md') -NoNewline
        '{"projectId":"invoice-importer","passed":true}' | Set-Content (Join-Path $taskRoot 'QA/invoice-importer-qa.json') -NoNewline

        $bundle = & (Get-Module SalmonRun.PondEngine) { param($r,$p) Complete-PondProjectBundle -TaskRoot $r -ProjectPlanPath $p } $taskRoot $parent
        $bundle | Should -Be (Join-Path $taskRoot 'Complete/invoice-importer')
        Join-Path $bundle 'project.md' | Should -Exist
        Join-Path $bundle 'plans/child-a.md' | Should -Exist
        Join-Path $bundle 'feedback/child-a-review.md' | Should -Exist
        Join-Path $bundle 'qa/invoice-importer-qa.json' | Should -Exist
        Join-Path $bundle 'manifest.json' | Should -Exist
    }
}
