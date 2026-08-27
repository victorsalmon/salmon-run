#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    function ConvertFrom-GitDiffToPesterTags {
        param([string[]]$ChangedFiles)
        $result = @()
        $ChangedFiles | ForEach-Object {
            if ($_ -match 'Modules[/\\]Interclaw\.(\w+)') { $result += $matches[1] }
            elseif ($_ -match 'Scripts[/\\]config\.ps1') { $result += 'Config' }
            elseif ($_ -match 'Docker[/\\]1Install\.ps1') { $result += 'Host' }
        }
        $result = $result | Select-Object -Unique
        Write-Output -NoEnumerate $result
    }
}

Describe "Review mode Pester tag derivation" -Tag "ReviewMode", "Regression-Only" {

    It "derives Core tag from SalmonRun.Core module change" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Orchestrator/Modules/SalmonRun.Core/Public/Write-SetupLog.ps1"
        )
        $tags | Should -HaveCount 1
        $tags | Should -Contain "Core"
    }

    It "derives Secrets tag from SalmonRun.Secrets module change" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1"
        )
        $tags | Should -HaveCount 1
        $tags[0] | Should -BeExactly "Secrets"
    }

    It "derives Config tag from config.ps1 change" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Skills/Scripts/config.ps1"
        )
        $tags | Should -HaveCount 1
        $tags[0] | Should -BeExactly "Config"
    }

    It "derives Host tag from 1Install.ps1 change" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Skills/Docker/1Install.ps1"
        )
        $tags | Should -HaveCount 1
        $tags[0] | Should -BeExactly "Host"
    }

    It "returns unique tags for multiple changes in same module" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Orchestrator/Modules/SalmonRun.Core/Public/Write-SetupLog.ps1",
            "Orchestrator/Modules/SalmonRun.Core/Private/Logging.ps1"
        )
        $tags | Should -HaveCount 1
        $tags[0] | Should -BeExactly "Core"
    }

    It "returns multiple tags for cross-module changes" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Orchestrator/Modules/SalmonRun.Core/Public/Logging.ps1",
            "Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1",
            "Skills/Scripts/config.ps1"
        )
        $tags | Should -HaveCount 3
        $tags | Should -Contain "Core"
        $tags | Should -Contain "Secrets"
        $tags | Should -Contain "Config"
    }

    It "returns empty array for non-module non-script changes" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "README.md",
            "docs/Reference/Diagrams.md"
        )
        $tags | Should -BeNullOrEmpty
    }

    It "handles empty file list" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @()
        $tags | Should -BeNullOrEmpty
    }

    It "handles Windows backslash paths" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Skills\Docker\Modules\SalmonRun.Identity\Public\Get-AgentIdentity.ps1"
        )
        $tags | Should -HaveCount 1
        $tags[0] | Should -BeExactly "Identity"
    }

    It "handles mixed forward and backslash paths" {
        $tags = ConvertFrom-GitDiffToPesterTags -ChangedFiles @(
            "Orchestrator/Modules/SalmonRun.Core/Public/Emit.ps1",
            "Orchestrator\Modules\SalmonRun.Host\Public\Get-DockerStatus.ps1"
        )
        $tags | Should -HaveCount 2
        $tags | Should -Contain "Core"
        $tags | Should -Contain "Host"
    }
}

Describe "Review finale guard (Invoke-ReviewFinaleGuard.ps1)" -Tag "ReviewMode", "Regression" {

    BeforeAll {
        $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $script:GuardPath = Join-Path $RepoRoot "Skills\\Orchestration\Workflows\Review\Scripts\Invoke-ReviewFinaleGuard.ps1"
        . $script:GuardPath
    }

    It "detects an intact plan body" {
        $plan = Join-Path $env:TEMP "guard-intact-$PID.md"
        "# Session Plan: test" + ("`n" + ("body" * 200)) | Set-Content $plan -Encoding utf8 -NoNewline
        Test-ReviewPlanBodyIntact -Path $plan | Should -Be $true
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }

    It "rejects a header-only stub (body lost)" {
        $plan = Join-Path $env:TEMP "guard-stub-$PID.md"
        "**Lock**`n- Agent: x`n- Status: locked" | Set-Content $plan -Encoding utf8 -NoNewline
        Test-ReviewPlanBodyIntact -Path $plan | Should -Be $false
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }

    It "rejects a file whose body is shorter than 200 chars even with the marker" {
        $plan = Join-Path $env:TEMP "guard-short-$PID.md"
        "# Session Plan: test" | Set-Content $plan -Encoding utf8 -NoNewline
        Test-ReviewPlanBodyIntact -Path $plan | Should -Be $false
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }

    It "flags an instant review (Released - Locked < 10s)" {
        $plan = Join-Path $env:TEMP "guard-instant-$PID.md"
        @"
- Locked: 2026-08-02T10:00:00.0000000Z
- Released: 2026-08-02T10:00:05.0000000Z
"@ | Set-Content $plan -Encoding utf8 -NoNewline
        $delta = Test-InstantReviewDelta -Path $plan
        $delta | Should -Not -Be $null
        $delta | Should -BeLessThan 10
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }

    It "accepts a real review duration (delta >= 10s)" {
        $plan = Join-Path $env:TEMP "guard-real-$PID.md"
        @"
- Locked: 2026-08-02T10:00:00.0000000Z
- Released: 2026-08-02T10:15:00.0000000Z
"@ | Set-Content $plan -Encoding utf8 -NoNewline
        $delta = Test-InstantReviewDelta -Path $plan
        $delta | Should -BeGreaterThan 10
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }

    It "returns null when stamps are missing" {
        $plan = Join-Path $env:TEMP "guard-nostamp-$PID.md"
        "# Session Plan: test" | Set-Content $plan -Encoding utf8 -NoNewline
        Test-InstantReviewDelta -Path $plan | Should -Be $null
        Remove-Item $plan -Force -ErrorAction SilentlyContinue
    }
}
