#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
param()

Describe "Repo Hygiene" -Tag "RepoHygiene", "Regression" {
    It "no zero-byte files exist at repo root" {
        $root = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
        $zeroByteRootFiles = Get-ChildItem $root -File | Where-Object { $_.Length -eq 0 -and $_.Name -notmatch '^\.' }
        $zeroByteRootFiles | Should -HaveCount 0
    }
}
