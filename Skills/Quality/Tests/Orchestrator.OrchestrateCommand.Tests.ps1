#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $script:ScriptPath = Join-Path $RepoRoot "Orchestrator/Orchestration/Invoke-Orchestrate.ps1"
}

Describe "Invoke-Orchestrate.ps1" -Tag "OpenCode" {
    It "exists at expected path" {
        $script:ScriptPath | Should -Exist
    }

    It "parses without syntax errors" {
        { $null = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null) } | Should -Not -Throw
    }

    It "launches LocalOrchestrator.ps1 in detached mode" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match '-Detach -NoAuditPrompt'
    }

    It "defines a watchdog interval variable" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match '\$WatchIntervalSeconds'
    }

    It "checks all three queues via Get-TaskCounts" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match 'Get-TaskCounts'
    }

    It "reads orchestrator PID from lock file" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match '\.orchestrator-pid'
    }

    It "re-launches orchestrator on crash recovery" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match 'Rescue.*orphan|re-launche|Working.*rescue'
    }

    It "supports MaxWatchMinutes parameter" {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match '\$MaxWatchMinutes'
    }
}
