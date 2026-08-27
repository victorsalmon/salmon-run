#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# These tests intentionally inspect repository artifacts rather than invoking the
# lock-header writer. The existing StreamRace tests cover the writer's behavior.
BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:CanonicalPath = Join-Path $script:RepoRoot "Skills\Workflows\Cowork\Scripts\New-LockHeader.ps1"
    $script:LegacyPaths = @(
        (Join-Path $script:RepoRoot "Skills\Cowork\Scripts\New-LockHeader.ps1")
        (Join-Path $script:RepoRoot "Skills\OpenCode\Workflows\Cowork\Scripts\New-LockHeader.ps1")
    )
    $script:CanonicalContent = Get-Content -LiteralPath $script:CanonicalPath -Raw
    $script:WorkflowPrimitives = Get-Content -LiteralPath (Join-Path $script:RepoRoot "Skills\Workflows\Shared\workflow-primitives.md") -Raw
}

Describe "New-LockHeader canonicalization" -Tag "Orchestrator", "Regression" {
    It "keeps exactly one known lock-header script at the canonical path" {
        $existing = @((@($script:CanonicalPath) + $script:LegacyPaths) | Where-Object { Test-Path -LiteralPath $_ })

        $existing | Should -HaveCount 1
        $existing | Should -Contain $script:CanonicalPath
    }

    It "retains the history fallback and plan-body validator in the canonical script" {
        $script:CanonicalContent | Should -Match "function Test-PlanHeaderContent"
        $script:CanonicalContent | Should -Match "git -C \$repoRoot log --all"
    }

    It "puts the sanctioned script call before the deprecated inline splice" {
        $sanctionedIndex = $script:WorkflowPrimitives.IndexOf('Sanctioned path: call `New-LockHeader.ps1`')
        $firstAgentIndex = $script:WorkflowPrimitives.IndexOf('**First agent on a file**')

        $sanctionedIndex | Should -BeGreaterThan -1
        $sanctionedIndex | Should -BeLessThan $firstAgentIndex
        $script:WorkflowPrimitives | Should -Match 'Deprecated inline splice \(use `New-LockHeader\.ps1` instead\)'
    }
}
