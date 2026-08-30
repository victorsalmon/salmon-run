#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $modules = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $env:PSModulePath = "$modules$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modules 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Public MVP execution profiles' -Tag 'PondEngine', 'Regression-Only' {
    It 'gives every agentic pond an independently replaceable execution profile' {
        $agentic = Get-SalmonRunPonds | Where-Object { $_.Tasks.Name -contains 'ModelRoute' }
        $agentic.Count | Should -BeGreaterThan 0
        foreach ($pond in $agentic) {
            $pond.Execution | Should -Not -BeNullOrEmpty
            $pond.Execution.TimeoutMinutes | Should -BeGreaterThan 0
            $pond.Execution.CostCeiling | Should -BeGreaterOrEqual 0
        }
    }

    It 'resolves confirmed plan fields over pond and global defaults independently' {
        $pond = Get-SalmonRunPonds | Where-Object Name -eq 'QA'
        $runtime = @{
            execution = @{
                defaults = @{ harness='opencode'; provider='opencode-go'; effort='default'; timeoutMinutes=20; costCeiling=5.0 }
                ponds = @{ QA = @{ effort='max'; timeoutMinutes=45 } }
            }
        }
        $plan = @'
**Challenge**: Daily
**Overrides**: QA.Model=opencode-go/mimo-v2.5, QA.TimeoutMinutes=60
**Overrides confirmation**: confirmed by user
'@

        $resolved = & (Get-Module SalmonRun.PondEngine) {
            param($p,$content,$config) Resolve-PondExecutionProfileForPlan -Pond $p -Content $content -RuntimeConfig $config
        } $pond $plan $runtime

        $resolved.DecisionRequired | Should -BeFalse
        $resolved.Profile.Harness | Should -Be 'opencode'
        $resolved.Profile.Provider | Should -Be 'opencode-go'
        $resolved.Profile.Model | Should -Be 'opencode-go/mimo-v2.5'
        $resolved.Profile.Effort | Should -Be 'max'
        $resolved.Profile.TimeoutMinutes | Should -Be 60
        $resolved.Profile.CostCeiling | Should -Be 5.0
    }

    It 'fails closed when plan overrides are not confirmed' {
        $pond = Get-SalmonRunPonds | Where-Object Name -eq 'Code'
        $plan = "**Challenge**: Daily`n**Overrides**: Code.Provider=opencode-go"
        $resolved = & (Get-Module SalmonRun.PondEngine) {
            param($p,$content) Resolve-PondExecutionProfileForPlan -Pond $p -Content $content -RuntimeConfig @{}
        } $pond $plan

        $resolved.DecisionRequired | Should -BeTrue
        $resolved.Error | Should -Match 'confirmed'
    }

    It 'fails closed when the resolved model exceeds the configured cost ceiling' {
        $pond = Get-SalmonRunPonds | Where-Object Name -eq 'Code'
        $runtime = @{ execution=@{ defaults=@{ costCeiling=0.000001 } } }
        $resolved = & (Get-Module SalmonRun.PondEngine) {
            param($p,$config) Resolve-PondExecutionProfileForPlan -Pond $p -Content '**Challenge**: Daily' -RuntimeConfig $config
        } $pond $runtime

        $resolved.DecisionRequired | Should -BeTrue
        $resolved.Error | Should -Match 'cost ceiling'
    }
}

Describe 'Public MVP QA evidence gate' -Tag 'PondEngine', 'Regression-Only' {
    BeforeEach {
        $script:QaRepo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "qa-repo-$(Get-Random)") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:QaRepo 'reports') -Force
        $script:Plan = Join-Path $TestDrive "qa-plan-$(Get-Random).md"
    }

    It 'accepts a bound evidence artifact with 95 percent mutation proof and no unresolved outcomes' {
        $evidence = @{
            schemaVersion=1; decision='pass'; repository='fixture'; commit='abc123'
            behaviorInventory=@{total=4;mapped=4;critical=1;unmapped=@()}
            commands=@(
                @{name='audit-checks';command='verify-audit';exitCode=0},
                @{name='full-regression';command='verify-tests';exitCode=0},
                @{name='mutation';command='verify-mutation';exitCode=0}
            )
            mutation=@{scope='changed production code';killed=19;survived=0;noCoverage=0;timeout=0;compileError=0;equivalent=1;score=95.0;equivalentDispositions=@(@{file='x.ps1';line=1;mutator='Boolean';replacement='false';equivalent=$true;proof='original true is equivalent under the documented invariant';resolution='redundant branch removed'})}
            waivers=@()
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline

        $result = & (Get-Module SalmonRun.PondEngine) {
            param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo
        } $script:Plan $script:QaRepo

        $result.Passed | Should -BeTrue
        $result.Sha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'returns a human decision when mutation tooling is unavailable' {
        "# QA`n**MutationTooling**: unavailable" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) {
            param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo
        } $script:Plan $script:QaRepo

        $result.Passed | Should -BeFalse
        $result.DecisionRequired | Should -BeTrue
        $result.Error | Should -Match 'mutation tooling'
    }

    It 'rejects scores below 95 and unresolved mutation outcomes' {
        $evidence = @{
            schemaVersion=1; decision='pass'; repository='fixture'; commit='abc123'
            behaviorInventory=@{total=1;mapped=1;critical=0;unmapped=@()}
            commands=@(@{name='audit-checks';exitCode=0},@{name='full-regression';exitCode=0},@{name='mutation';exitCode=0})
            mutation=@{scope='changed production code';killed=18;survived=1;noCoverage=0;timeout=0;compileError=0;equivalent=0;score=94.7;equivalentDispositions=@()}
            waivers=@()
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) {
            param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo
        } $script:Plan $script:QaRepo

        $result.Passed | Should -BeFalse
        $result.Error | Should -Match '95'
    }

    It 'rejects a 94.7 raw score even when every outcome is classified' {
        $evidence = @{
            schemaVersion=1; decision='pass'; repository='fixture'; commit='abc123'
            behaviorInventory=@{total=1;mapped=1;critical=0;unmapped=@()}
            commands=@(@{name='audit-checks';exitCode=0},@{name='full-regression';exitCode=0},@{name='mutation';exitCode=0})
            mutation=@{scope='changed production code';killed=18;survived=0;noCoverage=0;timeout=0;compileError=0;equivalent=1;score=94.74;equivalentDispositions=@(@{equivalent=$true;proof='same behavior';resolution='redundant branch removed'})}
            waivers=@()
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) { param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo } $script:Plan $script:QaRepo
        $result.Passed | Should -BeFalse
    }

    It 'rejects unresolved survivors even when the raw score is exactly 95' {
        $evidence = @{
            schemaVersion=1; decision='pass'; repository='fixture'; commit='abc123'
            behaviorInventory=@{total=1;mapped=1;critical=0;unmapped=@()}
            commands=@(@{name='audit-checks';exitCode=0},@{name='full-regression';exitCode=0},@{name='mutation';exitCode=0})
            mutation=@{scope='changed production code';killed=19;survived=1;noCoverage=0;timeout=0;compileError=0;equivalent=0;score=95.0;equivalentDispositions=@()}
            waivers=@()
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) { param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo } $script:Plan $script:QaRepo
        $result.Passed | Should -BeFalse
    }

    It 'rejects mutation waivers' {
        $evidence = @{
            schemaVersion=1; decision='pass'; repository='fixture'; commit='abc123'
            behaviorInventory=@{total=1;mapped=1;critical=0;unmapped=@()}
            commands=@(@{name='audit-checks';exitCode=0},@{name='full-regression';exitCode=0},@{name='mutation';exitCode=0})
            mutation=@{scope='changed production code';killed=1;survived=0;noCoverage=0;timeout=0;compileError=0;equivalent=0;score=100.0;equivalentDispositions=@()}
            waivers=@('skip difficult mutant')
        }
        $evidence | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) { param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo } $script:Plan $script:QaRepo
        $result.Passed | Should -BeFalse
    }

    It 'rejects evidence paths that escape the repository' {
        "# QA`n**QAEvidence**: ../outside.json" | Set-Content $script:Plan -NoNewline
        '{}' | Set-Content (Join-Path $script:QaRepo.Parent 'outside.json') -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) { param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo } $script:Plan $script:QaRepo
        $result.Passed | Should -BeFalse
        $result.Error | Should -Match 'escapes'
    }

    It 'rejects QA evidence bound to an older repository commit' {
        & git -C $script:QaRepo init -b main | Out-Null
        & git -C $script:QaRepo config user.email 'qa-test@example.invalid'
        & git -C $script:QaRepo config user.name 'QA Test'
        'one' | Set-Content (Join-Path $script:QaRepo 'source.txt') -NoNewline
        & git -C $script:QaRepo add source.txt
        & git -C $script:QaRepo commit -m 'first' | Out-Null
        $oldCommit = (& git -C $script:QaRepo rev-parse HEAD).Trim()
        'two' | Set-Content (Join-Path $script:QaRepo 'source.txt') -NoNewline
        & git -C $script:QaRepo add source.txt
        & git -C $script:QaRepo commit -m 'second' | Out-Null
        @{schemaVersion=1;decision='pass';repository='fixture';commit=$oldCommit;behaviorInventory=@{total=1;mapped=1;critical=0;unmapped=@()};commands=@(@{name='audit-checks';exitCode=0},@{name='full-regression';exitCode=0},@{name='mutation';exitCode=0});mutation=@{scope='changed production code';killed=1;survived=0;noCoverage=0;timeout=0;compileError=0;equivalent=0;score=100.0;equivalentDispositions=@()};waivers=@()} |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:QaRepo 'reports/qa.json') -NoNewline
        "# QA`n**QAEvidence**: reports/qa.json" | Set-Content $script:Plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) { param($plan,$repo) Test-PondQAEvidence -PlanPath $plan -RepoDir $repo } $script:Plan $script:QaRepo
        $result.Passed | Should -BeFalse
        $result.Error | Should -Match 'stale'
    }
}

Describe 'Public MVP role contracts' -Tag 'Contract', 'PondEngine', 'Regression-Only' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Modules/SalmonRun.PondEngine/Executors/RolePrompts.ps1')
    }

    It 'orders deterministic Audit gates before AQE and limits 4C to discovered defects' {
        $prompt = Get-RolePrompt -Role auditor -RepoDir 'C:\fixture' -Provider opencode-go -Model opencode-go/hy3
        $prompt | Should -Match 'secret.*documentation.*lint.*static.*build.*regression.*AQE'
        $prompt | Should -Match '4C.*actual defect'
    }

    It 'requires QA to write versioned evidence and rerun audit checks before mutation' {
        $prompt = Get-RolePrompt -Role qa -RepoDir 'C:\fixture' -Provider opencode-go -Model opencode-go/hy3
        $prompt | Should -Match 'QAEvidence'
        $prompt | Should -Match '95%'
        $prompt | Should -Match 'Audit checks'
        $prompt | Should -Match 'full regression'
    }
}

Describe 'Public MVP typed completion sidecars' -Tag 'PondEngine', 'Regression-Only' {
    BeforeEach {
        $script:TypedRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive "typed-$(Get-Random)") -Force
        $script:TaskRoot = New-Item -ItemType Directory -Path (Join-Path $script:TypedRoot 'Tasks') -Force
        $script:TypedRepo = New-Item -ItemType Directory -Path (Join-Path $script:TypedRoot 'repo') -Force
    }

    It 'rejects a forged QA pass that has no typed proof artifact' {
        $plan = Join-Path $script:TaskRoot 'qa.md'
        "# QA`n**QA**: passed by forged-agent" | Set-Content $plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) {
            param($p,$t,$r) Initialize-PondGateAttempt $p QA $t | Out-Null; Write-PondGateResult -PlanPath $p -Gate QA -TaskRoot $t -ProviderSucceeded $true -RepoDir $r
        } $plan $script:TaskRoot $script:TypedRepo
        $result.verdict | Should -Be 'fail'
        $result.failureKind | Should -Be 'semantic-failure'
        $result.evidenceSummary | Should -Match 'QAEvidence'
    }

    It 'routes missing mutation tooling as a typed human decision' {
        $plan = Join-Path $script:TaskRoot 'qa-decision.md'
        "# QA`n**QADecision**: decision-required`n**MutationTooling**: unavailable`n**QA**: failed by agent - mutator missing" | Set-Content $plan -NoNewline
        $result = & (Get-Module SalmonRun.PondEngine) {
            param($p,$t,$r) Initialize-PondGateAttempt $p QA $t | Out-Null; Write-PondGateResult -PlanPath $p -Gate QA -TaskRoot $t -ProviderSucceeded $false -RepoDir $r
        } $plan $script:TaskRoot $script:TypedRepo
        $result.failureKind | Should -Be 'decision-required'
        (Get-Content $plan -Raw) | Should -Match '(?im)^\*\*DecisionRequired\*\*:\s*yes'
    }

    It 'does not accept a sidecar from a stale attempt' {
        $plan = Join-Path $script:TaskRoot 'code.md'
        "# Code`n**Implementation**: completed by agent" | Set-Content $plan -NoNewline
        $old = & (Get-Module SalmonRun.PondEngine) {
            param($p,$t,$r) Initialize-PondGateAttempt $p Code $t | Out-Null; Write-PondGateResult -PlanPath $p -Gate Code -TaskRoot $t -ProviderSucceeded $true -RepoDir $r
        } $plan $script:TaskRoot $script:TypedRepo
        & (Get-Module SalmonRun.PondEngine) { param($p,$t) Initialize-PondGateAttempt $p Code $t | Out-Null } $plan $script:TaskRoot
        $current = & (Get-Module SalmonRun.PondEngine) { param($p,$t) Get-PondValidatedGateResult -PlanPath $p -Gate Code -TaskRoot $t } $plan $script:TaskRoot
        $old.verdict | Should -Be 'pass'
        $current | Should -BeNullOrEmpty
    }
}
