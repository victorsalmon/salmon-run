#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

Describe 'PondEngine mutation harness contract' -Tag 'PondEngine','Mutation' {
    It 'defines curated mutants for every new decision boundary' {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $runner = Join-Path $repoRoot 'Tools/QA/powershell-property-testing/Invoke-PondEngineMutationAnalysis.ps1'
        $runner | Should -Exist
        $source = Get-Content -LiteralPath $runner -Raw
        foreach ($id in 'Planning-OverBudget','Review-FailedAccepted','QA-BatchBypass','QA-MembershipInverted','ParallelCount-Bypass','Bundle-ProjectName','Override-Confirmation-Bypass','Cost-Ceiling-Inverted','Mutation-Threshold-Lowered','Mutation-Survivor-Bypass','Mutation-Waiver-Bypass','Evidence-Path-Containment-Inverted','Commit-Binding-Bypass') {
            $source | Should -Match ([regex]::Escape($id))
        }
    }
}
