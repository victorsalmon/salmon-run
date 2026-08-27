#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ValidatorPath = Join-Path $script:RepoRoot 'Skills' 'Plugins' 'battle-tested-qa' 'skills' 'battle-tested-qa' 'scripts' 'validate-evidence.mjs'
    $script:ExamplePath = Join-Path $script:RepoRoot 'Skills' 'Plugins' 'battle-tested-qa' 'skills' 'battle-tested-qa' 'references' 'qa-evidence.example.json'
}

Describe 'Battle-Tested QA evidence validator' -Tag 'QA', 'Unit' {
    It 'validates the canonical example evidence' {
        $output = & node $script:ValidatorPath $script:ExamplePath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "canonical example should be valid; output: $output"
    }

    It 'rejects a non-positive line in equivalentDispositions' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'invalid-line.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $evidence['mutation']['equivalentDispositions'][0]['line'] = 0
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 1 -Because "line 0 should fail; output: $output"
            ($output -join "`n") | Should -Match 'line must be a positive integer'
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a missing proof in equivalentDispositions' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'missing-proof.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $entry = $evidence['mutation']['equivalentDispositions'][0]
        if ($entry.Contains('proof')) { $entry.Remove('proof') }
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 1 -Because "missing proof should fail; output: $output"
            ($output -join "`n") | Should -Match 'proof is required'
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a non-boolean equivalent value' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'invalid-equivalent.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $evidence['mutation']['equivalentDispositions'][0]['equivalent'] = 'yes'
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 1 -Because "non-boolean equivalent should fail; output: $output"
            ($output -join "`n") | Should -Match 'equivalent must be a boolean'
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'validates equivalentDispositions at the top level' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'toplevel.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $evidence['equivalentDispositions'] = @(
            [ordered]@{
                file = 'src/ledger/round.ts'
                line = 55
                mutator = 'ArithmeticOperator'
                replacement = '-'
                equivalent = $false
                proof = 'Counterexample in negative decimals breaks conservation.'
                resolution = 'Added conservation property test.'
            }
        )
        if ($evidence['mutation'].Contains('equivalentDispositions')) {
            $evidence['mutation'].Remove('equivalentDispositions')
        }
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "top-level equivalentDispositions should be valid; output: $output"
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'passes when surviving mutants are documented as equivalent' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'equivalent-survivor.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $evidence['mutation']['killed'] = 97
        $evidence['mutation']['survived'] = 1
        $evidence['mutation']['equivalent'] = 1
        $evidence['mutation']['equivalentDispositions'] = @(
            [ordered]@{
                file = 'src/ledger/balance.ts'
                line = 42
                mutator = 'ConditionalBoundary'
                replacement = '<= MAX'
                equivalent = $true
                proof = 'Loop invariant guarantees amount < MAX, so the boundary change is equivalent.'
                resolution = 'Documented equivalent; simplified in a follow-up refactor.'
            }
        )
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "a documented equivalent survivor should not block pass; output: $output"
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a pass with surviving mutants that are not documented as equivalent' {
        $tmp = Join-Path (Get-PSDrive TestDrive).Root 'undispositioned-survivor.json'
        $evidence = Get-Content -Raw -LiteralPath $script:ExamplePath | ConvertFrom-Json -AsHashtable
        $evidence['mutation']['killed'] = 97
        $evidence['mutation']['survived'] = 1
        $evidence['mutation']['equivalent'] = 0
        $evidence['mutation']['equivalentDispositions'] = @()
        $evidence | ConvertTo-Json -Depth 8 | Out-File -FilePath $tmp -Encoding utf8

        try {
            $output = & node $script:ValidatorPath $tmp 2>&1
            $LASTEXITCODE | Should -Be 1 -Because "a surviving mutant without an equivalent disposition should fail; output: $output"
            ($output -join "`n") | Should -Match 'every surviving mutant to be documented as equivalent'
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }
}
